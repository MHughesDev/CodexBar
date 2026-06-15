#if os(Windows)
import Foundation
import WinSDK

// MARK: - Windows Cookie Backend

/// Windows backend for browser cookie extraction.
///
/// Supports:
/// - Chromium-family browsers (Chrome, Edge, Brave, Vivaldi, Opera) using the
///   DPAPI-protected AES-GCM key stored in `Local State` and a read-only copy
///   of the `Cookies` SQLite database.
/// - Firefox plaintext cookies from `cookies.sqlite`.
///
/// - Note: Chrome v127+ introduces App-Bound Encryption (ABE) for `v20`-prefixed
///   cookie values. These cannot be decrypted headlessly.
///
/// - TODO: App-Bound Encryption (ABE) — Chrome v127+ `v20` cookie values require
///   an elevated COM service call that ties decryption to the running browser
///   process. Detect `v20` prefix and surface a user-visible warning. Prefer
///   Edge/Brave (ABE opt-in pending) or manual cookie entry as fallback.
///   Track as risk OD-3 in the refactor plans.
public struct WindowsCookieBackend: CookieBackend {
    private static let log = CodexBarLog.logger("cookie-backend-windows")

    public init() {}

    // MARK: - CookieBackend

    public func cookieHeader(for url: URL, browserHint: String?) async -> String? {
        guard let host = url.host else { return nil }

        let browsers = WindowsBrowserDetection.availableBrowsers()
        let candidates: [WindowsBrowserDetection.BrowserProfile] = if let hint = browserHint {
            browsers.filter { $0.name.lowercased().contains(hint.lowercased()) }
        } else {
            browsers
        }

        for profile in candidates {
            if let header = await self.extractCookies(from: profile, host: host) {
                return header
            }
        }
        return nil
    }

    public func availableBrowsers() -> [String] {
        WindowsBrowserDetection.availableBrowsers().map(\.name)
    }

    // MARK: - Per-profile extraction

    private func extractCookies(from profile: WindowsBrowserDetection.BrowserProfile, host: String) async -> String? {
        switch profile.engine {
        case .chromium:
            await self.extractChromiumCookies(profile: profile, host: host)
        case .gecko:
            self.extractFirefoxCookies(profile: profile, host: host)
        }
    }

    // MARK: - Chromium (Chrome / Edge / Brave / Vivaldi / Opera)

    private func extractChromiumCookies(
        profile: WindowsBrowserDetection.BrowserProfile,
        host: String
    ) async -> String? {
        // Resolve AES-GCM key from Local State (DPAPI-protected).
        guard let aesKey = self.chromiumAESKey(localStatePath: profile.localStatePath) else {
            Self.log.debug("[\(profile.name)] Could not derive AES-GCM key from Local State")
            return nil
        }

        // Copy Cookies DB to a temp file to avoid SQLite lock held by running browser.
        let cookiesDB = profile.cookiesDBPath
        guard FileManager.default.fileExists(atPath: cookiesDB) else {
            Self.log.debug("[\(profile.name)] Cookies DB not found at \(cookiesDB)")
            return nil
        }
        let tempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("codexbar_cookies_\(UUID().uuidString).sqlite")
        do {
            try FileManager.default.copyItem(atPath: cookiesDB, toPath: tempPath)
        } catch {
            Self.log.debug("[\(profile.name)] Failed to copy Cookies DB: \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        return self.readChromiumCookies(dbPath: tempPath, host: host, aesKey: aesKey, browserName: profile.name)
    }

    /// Reads `os_crypt.encrypted_key` from `Local State`, strips the `DPAPI` prefix,
    /// calls `CryptUnprotectData`, and returns the raw 32-byte AES-256 key.
    private func chromiumAESKey(localStatePath: String) -> Data? {
        guard
            let data = FileManager.default.contents(atPath: localStatePath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let osCrypt = json["os_crypt"] as? [String: Any],
            let encryptedKeyB64 = osCrypt["encrypted_key"] as? String,
            let encryptedKeyWithPrefix = Data(base64Encoded: encryptedKeyB64)
        else {
            return nil
        }

        // The key starts with the literal ASCII "DPAPI" (5 bytes).
        let dpapiPrefix = Data("DPAPI".utf8)
        guard encryptedKeyWithPrefix.count > dpapiPrefix.count,
              encryptedKeyWithPrefix.prefix(dpapiPrefix.count) == dpapiPrefix
        else {
            Self.log.debug("Local State encrypted_key missing DPAPI prefix")
            return nil
        }
        let encryptedKey = encryptedKeyWithPrefix.dropFirst(dpapiPrefix.count)
        return dpapi_decrypt(encryptedKey)
    }

    /// Queries the Cookies SQLite table and decrypts values using the AES-GCM key.
    private func readChromiumCookies(dbPath: String, host: String, aesKey: Data, browserName: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            Self.log.debug("[\(browserName)] sqlite3_open failed for \(dbPath)")
            return nil
        }
        defer { sqlite3_close(db) }

        // Match host_key exactly or as a suffix domain (e.g. ".example.com").
        let sql = """
            SELECT name, encrypted_value FROM cookies
            WHERE host_key = ? OR host_key = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (host as NSString).utf8String, -1, nil)
        // Also try the dot-prefixed domain form used by cookies that apply to subdomains.
        let dotHost = "." + host
        sqlite3_bind_text(stmt, 2, (dotHost as NSString).utf8String, -1, nil)

        var pairs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let namePtr = sqlite3_column_text(stmt, 0),
                let name = String(validatingUTF8: namePtr)
            else { continue }

            let blobLen = sqlite3_column_bytes(stmt, 1)
            guard blobLen > 0, let blobPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let encryptedValue = Data(bytes: blobPtr, count: Int(blobLen))

            if let plaintext = self.decryptChromiumValue(encryptedValue, aesKey: aesKey) {
                pairs.append("\(name)=\(plaintext)")
            }
        }

        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Decrypts a Chromium cookie encrypted_value.
    ///
    /// Format:
    /// - `v10` / `v11` prefix (3 bytes) + 12-byte nonce + ciphertext + 16-byte GCM tag.
    /// - `v20` / higher = App-Bound Encryption — cannot decrypt headlessly.
    /// - Legacy (no prefix): DPAPI-encrypted directly.
    private func decryptChromiumValue(_ data: Data, aesKey: Data) -> String? {
        guard data.count > 3 else { return nil }

        let prefix = data.prefix(3)
        let prefixStr = String(bytes: prefix, encoding: .utf8) ?? ""

        if prefixStr == "v10" || prefixStr == "v11" {
            // AES-256-GCM: 3-byte prefix | 12-byte nonce | ciphertext+tag
            guard data.count > 3 + 12 else { return nil }
            let nonce = data[3..<(3 + 12)]
            let ciphertextWithTag = data[(3 + 12)...]
            return aesGCMDecrypt(key: aesKey, nonce: nonce, ciphertextWithTag: ciphertextWithTag)
        }

        if prefixStr.hasPrefix("v2") {
            // TODO: App-Bound Encryption (ABE) — Chrome v127+ v20 values cannot be
            // decrypted without an elevated COM service call. Return nil and rely on
            // manual cookie fallback (OD-3).
            Self.log.debug("Skipping ABE-encrypted cookie (prefix: \(prefixStr)) — manual cookie entry required")
            return nil
        }

        // Legacy: the entire blob is DPAPI-encrypted.
        return dpapi_decrypt(data).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Firefox plaintext

    /// Firefox stores cookies in an unencrypted SQLite database — straightforward to read.
    private func extractFirefoxCookies(profile: WindowsBrowserDetection.BrowserProfile, host: String) -> String? {
        let dbPath = profile.cookiesDBPath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            Self.log.debug("[\(profile.name)] cookies.sqlite not found at \(dbPath)")
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT name, value FROM moz_cookies
            WHERE host = ? OR host = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (host as NSString).utf8String, -1, nil)
        let dotHost = "." + host
        sqlite3_bind_text(stmt, 2, (dotHost as NSString).utf8String, -1, nil)

        var pairs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let namePtr = sqlite3_column_text(stmt, 0),
                let name = String(validatingUTF8: namePtr),
                let valuePtr = sqlite3_column_text(stmt, 1),
                let value = String(validatingUTF8: valuePtr)
            else { continue }
            pairs.append("\(name)=\(value)")
        }

        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}

// MARK: - DPAPI helper

/// Decrypts `data` using `CryptUnprotectData` (user-scope, no UI).
/// Returns the plaintext `Data` on success, or `nil` on failure.
private func dpapi_decrypt(_ data: Data) -> Data? {
    var inputBlob = CRYPTOAPI_BLOB()
    return data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Data? in
        inputBlob.cbData = DWORD(data.count)
        inputBlob.pbData = UnsafeMutablePointer<BYTE>(
            mutating: rawBuf.baseAddress!.assumingMemoryBound(to: BYTE.self))
        var outputBlob = CRYPTOAPI_BLOB()
        let flags: DWORD = CRYPTPROTECT_UI_FORBIDDEN
        guard CryptUnprotectData(&inputBlob, nil, nil, nil, nil, flags, &outputBlob) else {
            return nil
        }
        defer { LocalFree(outputBlob.pbData) }
        return Data(bytes: outputBlob.pbData!, count: Int(outputBlob.cbData))
    }
}

// MARK: - AES-GCM decryption (CommonCrypto / CryptoKit)

/// Decrypts AES-256-GCM ciphertext.
///
/// `ciphertextWithTag` is the concatenation of the ciphertext and the 16-byte GCM authentication tag.
private func aesGCMDecrypt(key: Data, nonce: Data, ciphertextWithTag: Data) -> String? {
    // On Windows, CryptoKit is not available. Use CommonCrypto CCCrypt (CBC) — but GCM is
    // not in CommonCrypto. We implement AES-GCM via the WinSDK BCrypt API (CNG).
    guard ciphertextWithTag.count >= 16 else { return nil }
    let tagLen = 16
    let ciphertext = ciphertextWithTag.dropLast(tagLen)
    let tag = ciphertextWithTag.suffix(tagLen)

    return key.withUnsafeBytes { keyBytes in
        nonce.withUnsafeBytes { nonceBytes in
            ciphertext.withUnsafeBytes { ctBytes in
                tag.withUnsafeBytes { tagBytes in
                    bcryptAESGCMDecrypt(
                        key: keyBytes,
                        nonce: nonceBytes,
                        ciphertext: ctBytes,
                        tag: tagBytes,
                    )
                }
            }
        }
    }
}

/// CNG (BCrypt) AES-256-GCM decryption.
private func bcryptAESGCMDecrypt(
    key: UnsafeRawBufferPointer,
    nonce: UnsafeRawBufferPointer,
    ciphertext: UnsafeRawBufferPointer,
    tag: UnsafeRawBufferPointer,
) -> String? {
    var hAlg: BCRYPT_ALG_HANDLE?
    guard BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_AES_ALGORITHM, nil, 0) == 0, let hAlg else {
        return nil
    }
    defer { BCryptCloseAlgorithmProvider(hAlg, 0) }

    // Set GCM chaining mode.
    let chainingMode = BCRYPT_CHAIN_MODE_GCM
    let chainingModeWide = chainingMode.withCString { ptr -> [WCHAR] in
        var wchars = [WCHAR](repeating: 0, count: wcslen(ptr) + 1)
        mbstowcs(&wchars, ptr, wchars.count)
        return wchars
    }
    guard chainingModeWide.withUnsafeBufferPointer({ buf in
        BCryptSetProperty(
            hAlg,
            BCRYPT_CHAINING_MODE,
            UnsafeMutablePointer(mutating: buf.baseAddress!),
            ULONG(buf.count * MemoryLayout<WCHAR>.size),
            0,
        )
    }) == 0 else { return nil }

    // Import the symmetric key.
    var hKey: BCRYPT_KEY_HANDLE?
    guard key.withUnsafeBytes({ _ in true }) else { return nil } // type-checker helper

    let keyBytes = Array(key.bindMemory(to: UInt8.self))
    var keyResult: NTSTATUS = 0
    keyResult = keyBytes.withUnsafeBufferPointer { keyBuf in
        BCryptGenerateSymmetricKey(
            hAlg,
            &hKey,
            nil,
            0,
            UnsafeMutablePointer(mutating: keyBuf.baseAddress!),
            ULONG(keyBuf.count),
            0,
        )
    }
    guard keyResult == 0, let hKey else { return nil }
    defer { BCryptDestroyKey(hKey) }

    // Set up authenticated cipher mode info.
    let nonceBytes = Array(nonce.bindMemory(to: UInt8.self))
    let tagBytes = Array(tag.bindMemory(to: UInt8.self))

    var authInfo = BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO()
    BCryptInitAuthenticatedCipherModeInfo(&authInfo)
    authInfo.cbSize = ULONG(MemoryLayout<BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO>.size)

    return nonceBytes.withUnsafeBufferPointer { nonceBuf in
        tagBytes.withUnsafeBufferPointer { tagBuf in
            authInfo.pbNonce = UnsafeMutablePointer(mutating: nonceBuf.baseAddress!)
            authInfo.cbNonce = ULONG(nonceBuf.count)
            authInfo.pbTag = UnsafeMutablePointer(mutating: tagBuf.baseAddress!)
            authInfo.cbTag = ULONG(tagBuf.count)

            let ctBytes = Array(ciphertext.bindMemory(to: UInt8.self))
            var plaintext = [UInt8](repeating: 0, count: ctBytes.count)
            var bytesWritten: ULONG = 0

            let status = ctBytes.withUnsafeBufferPointer { ctBuf in
                plaintext.withUnsafeMutableBufferPointer { ptBuf in
                    BCryptDecrypt(
                        hKey,
                        UnsafeMutablePointer(mutating: ctBuf.baseAddress!),
                        ULONG(ctBuf.count),
                        &authInfo,
                        nil,
                        0,
                        ptBuf.baseAddress!,
                        ULONG(ptBuf.count),
                        &bytesWritten,
                        0,
                    )
                }
            }

            guard status == 0 else { return nil }
            return String(bytes: plaintext.prefix(Int(bytesWritten)), encoding: .utf8)
        }
    }
}

// MARK: - Browser Detection (Windows)

/// Enumerates installed Chromium and Firefox browser profiles on Windows
/// by probing well-known paths under `%LOCALAPPDATA%` and `%APPDATA%`.
public enum WindowsBrowserDetection {
    public enum Engine { case chromium, gecko }

    public struct BrowserProfile: Sendable {
        /// Human-readable browser name (e.g. "Chrome", "Edge").
        public let name: String
        /// Engine type — determines decryption strategy.
        public let engine: Engine
        /// Path to `Local State` JSON (Chromium only, empty for Firefox).
        public let localStatePath: String
        /// Path to the Cookies SQLite DB (`Cookies` for Chromium, `cookies.sqlite` for Firefox).
        public let cookiesDBPath: String
    }

    /// Returns profiles for every installed browser found on this machine.
    /// Chromium browsers are listed first (Chrome, Edge, Brave, Vivaldi, Opera), then Firefox.
    public static func availableBrowsers() -> [BrowserProfile] {
        var profiles: [BrowserProfile] = []

        if let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
            profiles += self.chromiumProfiles(under: localAppData)
        }
        if let appData = ProcessInfo.processInfo.environment["APPDATA"] {
            profiles += self.firefoxProfiles(under: appData)
            // Opera uses %APPDATA%.
            profiles += self.operaProfiles(under: appData)
        }

        return profiles
    }

    // MARK: Private helpers

    /// Known Chromium `User Data` paths relative to `%LOCALAPPDATA%`.
    private static let chromiumEntries: [(name: String, relativePath: String)] = [
        ("Chrome", "Google/Chrome/User Data"),
        ("Edge", "Microsoft/Edge/User Data"),
        ("Brave", "BraveSoftware/Brave-Browser/User Data"),
        ("Vivaldi", "Vivaldi/User Data"),
    ]

    private static func chromiumProfiles(under localAppData: String) -> [BrowserProfile] {
        var result: [BrowserProfile] = []
        let fm = FileManager.default

        for entry in self.chromiumEntries {
            let userDataPath = "\(localAppData)/\(entry.relativePath)"
            let localStatePath = "\(userDataPath)/Local State"
            guard fm.fileExists(atPath: localStatePath) else { continue }

            // Enumerate Default + numbered profiles.
            let profileDirs = (try? fm.contentsOfDirectory(atPath: userDataPath)) ?? []
            for dir in profileDirs where dir == "Default" || dir.hasPrefix("Profile ") {
                let cookiesPath = "\(userDataPath)/\(dir)/Network/Cookies"
                let cookiesPathLegacy = "\(userDataPath)/\(dir)/Cookies"
                let resolvedCookies: String
                if fm.fileExists(atPath: cookiesPath) {
                    resolvedCookies = cookiesPath
                } else if fm.fileExists(atPath: cookiesPathLegacy) {
                    resolvedCookies = cookiesPathLegacy
                } else {
                    continue
                }
                let label = profileDirs.count > 1 ? "\(entry.name) (\(dir))" : entry.name
                result.append(BrowserProfile(
                    name: label,
                    engine: .chromium,
                    localStatePath: localStatePath,
                    cookiesDBPath: resolvedCookies,
                ))
            }
        }
        return result
    }

    private static func operaProfiles(under appData: String) -> [BrowserProfile] {
        let fm = FileManager.default
        let userDataPath = "\(appData)/Opera Software/Opera Stable"
        let localStatePath = "\(userDataPath)/Local State"
        guard fm.fileExists(atPath: localStatePath) else { return [] }

        let cookiesPath = "\(userDataPath)/Network/Cookies"
        let cookiesPathLegacy = "\(userDataPath)/Cookies"
        let resolvedCookies: String
        if fm.fileExists(atPath: cookiesPath) {
            resolvedCookies = cookiesPath
        } else if fm.fileExists(atPath: cookiesPathLegacy) {
            resolvedCookies = cookiesPathLegacy
        } else {
            return []
        }
        return [BrowserProfile(
            name: "Opera",
            engine: .chromium,
            localStatePath: localStatePath,
            cookiesDBPath: resolvedCookies,
        )]
    }

    private static func firefoxProfiles(under appData: String) -> [BrowserProfile] {
        let fm = FileManager.default
        let profilesDir = "\(appData)/Mozilla/Firefox/Profiles"
        guard let entries = try? fm.contentsOfDirectory(atPath: profilesDir) else { return [] }

        return entries.compactMap { dir -> BrowserProfile? in
            guard dir.lowercased().contains(".default") else { return nil }
            let dbPath = "\(profilesDir)/\(dir)/cookies.sqlite"
            guard fm.fileExists(atPath: dbPath) else { return nil }
            return BrowserProfile(
                name: "Firefox",
                engine: .gecko,
                localStatePath: "",
                cookiesDBPath: dbPath,
            )
        }
    }
}

#endif // os(Windows)
