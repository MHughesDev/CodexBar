import Foundation

/// Cross-platform backend for encrypted key-value credential storage.
/// macOS: Keychain. Windows: Credential Manager + DPAPI overflow. Linux: no-op.
protocol SecretStore {
    func load<T: Codable>(key: KeychainCacheStore.Key, as type: T.Type) -> KeychainCacheStore.LoadResult<T>
    func store(key: KeychainCacheStore.Key, entry: some Codable) -> Bool
    func clear(key: KeychainCacheStore.Key) -> KeychainCacheStore.ClearResult
    func keys(category: String) -> KeychainCacheStore.KeysResult
}

/// Factory that returns the platform-appropriate SecretStore.
enum SecretStoreFactory {
    static func make() -> any SecretStore {
        #if os(macOS)
        return MacOSKeychainSecretStore()
        #elseif os(Windows)
        return WindowsCredentialSecretStore()
        #else
        return NoopSecretStore()
        #endif
    }
}

// MARK: - macOS backend

#if os(macOS)
struct MacOSKeychainSecretStore: SecretStore {
    func load<T: Codable>(key: KeychainCacheStore.Key, as type: T.Type) -> KeychainCacheStore.LoadResult<T> {
        KeychainCacheStore.load(key: key, as: type)
    }

    func store(key: KeychainCacheStore.Key, entry: some Codable) -> Bool {
        KeychainCacheStore.storeResult(key: key, entry: entry)
    }

    func clear(key: KeychainCacheStore.Key) -> KeychainCacheStore.ClearResult {
        KeychainCacheStore.clearResult(key: key)
    }

    func keys(category: String) -> KeychainCacheStore.KeysResult {
        KeychainCacheStore.keysResult(category: category)
    }
}
#endif

// MARK: - Linux no-op backend

#if !os(macOS) && !os(Windows)
struct NoopSecretStore: SecretStore {
    func load<T: Codable>(key: KeychainCacheStore.Key, as type: T.Type) -> KeychainCacheStore.LoadResult<T> {
        .missing
    }

    func store(key: KeychainCacheStore.Key, entry: some Codable) -> Bool {
        false
    }

    func clear(key: KeychainCacheStore.Key) -> KeychainCacheStore.ClearResult {
        .missing
    }

    func keys(category: String) -> KeychainCacheStore.KeysResult {
        .found([])
    }
}
#endif

// MARK: - Windows Credential Manager backend

#if os(Windows)
import WinSDK

/// Windows Credential Manager backend for the SecretStore protocol.
/// Uses CredWriteW/CredReadW/CredDeleteW/CredEnumerateW (CRED_TYPE_GENERIC).
/// Blob size limit: 2,560 bytes per credential. Entries exceeding this are
/// stored as DPAPI-encrypted files under %LOCALAPPDATA%\CodexBar\creds\.
/// TODO: verify exact WinSDK API names on Windows CI
struct WindowsCredentialSecretStore: SecretStore {
    private static let targetPrefix = "CodexBar:"
    private static let log = CodexBarLog.logger(LogCategories.keychainCache)

    /// Maximum payload size for Credential Manager (per-credential blob limit).
    private static let maxCredentialBlobSize = 2048

    func load<T: Codable>(key: KeychainCacheStore.Key, as type: T.Type) -> KeychainCacheStore.LoadResult<T> {
        let target = Self.targetName(for: key)
        // Try large-blob DPAPI file first (written when payload exceeds maxCredentialBlobSize)
        if let data = Self.loadFromDPAPIFile(key: key) {
            return Self.decode(data, as: type, key: key)
        }
        // Try Credential Manager
        var pCred: UnsafeMutablePointer<WinSDK.CREDENTIALW>?
        let ok = target.withCString(encodedAs: UTF16.self) { targetPtr in
            WinSDK.CredReadW(targetPtr, WinSDK.CRED_TYPE_GENERIC, 0, &pCred)
        }
        guard ok else {
            let err = WinSDK.GetLastError()
            if err == WinSDK.ERROR_NOT_FOUND { return .missing }
            Self.log.error("CredReadW failed (\(key.category).\(key.identifier)): \(err)")
            return .invalid
        }
        defer { WinSDK.CredFree(pCred) }
        guard let cred = pCred?.pointee,
              let blobPtr = cred.CredentialBlob,
              cred.CredentialBlobSize > 0
        else {
            return .missing
        }
        let data = Data(bytes: blobPtr, count: Int(cred.CredentialBlobSize))
        return Self.decode(data, as: type, key: key)
    }

    func store(key: KeychainCacheStore.Key, entry: some Codable) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return false }

        // Large payloads go to DPAPI-encrypted file; small ones to Credential Manager
        if data.count > Self.maxCredentialBlobSize {
            return Self.storeToDPAPIFile(key: key, data: data)
        }

        let target = Self.targetName(for: key)
        return data.withUnsafeBytes { blobPtr in
            var cred = WinSDK.CREDENTIALW()
            cred.Type = WinSDK.CRED_TYPE_GENERIC
            cred.Persist = WinSDK.CRED_PERSIST_LOCAL_MACHINE
            cred.CredentialBlobSize = WinSDK.DWORD(data.count)
            cred.CredentialBlob = UnsafeMutablePointer(mutating: blobPtr.bindMemory(to: WinSDK.BYTE.self).baseAddress)
            return target.withCString(encodedAs: UTF16.self) { targetPtr in
                cred.TargetName = UnsafeMutablePointer(mutating: targetPtr)
                let label = "CodexBar"
                return label.withCString(encodedAs: UTF16.self) { labelPtr in
                    cred.Comment = UnsafeMutablePointer(mutating: labelPtr)
                    let result = WinSDK.CredWriteW(&cred, 0)
                    if !result {
                        Self.log.error(
                            "CredWriteW failed (\(key.category).\(key.identifier)): \(WinSDK.GetLastError())")
                    }
                    return result
                }
            }
        }
    }

    func clear(key: KeychainCacheStore.Key) -> KeychainCacheStore.ClearResult {
        // Clear both storage locations
        _ = Self.removeDPAPIFile(key: key)
        let target = Self.targetName(for: key)
        let ok = target.withCString(encodedAs: UTF16.self) { targetPtr in
            WinSDK.CredDeleteW(targetPtr, WinSDK.CRED_TYPE_GENERIC, 0)
        }
        if ok { return .removed }
        let err = WinSDK.GetLastError()
        if err == WinSDK.ERROR_NOT_FOUND { return .missing }
        Self.log.error("CredDeleteW failed (\(key.category).\(key.identifier)): \(err)")
        return .failed
    }

    func keys(category: String) -> KeychainCacheStore.KeysResult {
        let filter = "\(Self.targetPrefix)\(category).*"
        var count: WinSDK.DWORD = 0
        var pCreds: UnsafeMutablePointer<UnsafeMutablePointer<WinSDK.CREDENTIALW>?>?
        let ok = filter.withCString(encodedAs: UTF16.self) { filterPtr in
            WinSDK.CredEnumerateW(filterPtr, 0, &count, &pCreds)
        }
        guard ok, let creds = pCreds else {
            let err = WinSDK.GetLastError()
            if err == WinSDK.ERROR_NOT_FOUND { return .found([]) }
            return .failed
        }
        defer { WinSDK.CredFree(pCreds) }
        var keys: [KeychainCacheStore.Key] = []
        for i in 0..<Int(count) {
            guard let cred = creds[i]?.pointee,
                  let namePtr = cred.TargetName
            else { continue }
            let target = String(decodingCString: namePtr, as: UTF16.self)
            guard target.hasPrefix(Self.targetPrefix) else { continue }
            let rest = String(target.dropFirst(Self.targetPrefix.count))
            let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            keys.append(KeychainCacheStore.Key(category: parts[0], identifier: parts[1]))
        }
        return .found(keys)
    }

    // MARK: - Helpers

    private static func targetName(for key: KeychainCacheStore.Key) -> String {
        "\(self.targetPrefix)\(key.category).\(key.identifier)"
    }

    private static func decode<T: Codable>(
        _ data: Data,
        as type: T.Type,
        key: KeychainCacheStore.Key) -> KeychainCacheStore.LoadResult<T>
    {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(type, from: data) else {
            Self.log.error("Failed to decode credential (\(key.category).\(key.identifier))")
            return .invalid
        }
        return .found(decoded)
    }

    // MARK: - DPAPI large-blob overflow

    private static var dpapiBlobDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CodexBar/creds", isDirectory: true)
    }

    private static func dpapiBlobURL(for key: KeychainCacheStore.Key) -> URL {
        self.dpapiBlobDirectory.appendingPathComponent("\(key.category).\(key.identifier).bin")
    }

    private static func loadFromDPAPIFile(key: KeychainCacheStore.Key) -> Data? {
        let url = Self.dpapiBlobURL(for: key)
        guard let encrypted = try? Data(contentsOf: url) else { return nil }
        return Self.dpapiDecrypt(encrypted)
    }

    private static func storeToDPAPIFile(key: KeychainCacheStore.Key, data: Data) -> Bool {
        guard let encrypted = self.dpapiEncrypt(data) else { return false }
        let url = Self.dpapiBlobURL(for: key)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try encrypted.write(to: url, options: [.atomic])
            return true
        } catch {
            Self.log.error("DPAPI file write failed (\(key.category).\(key.identifier)): \(error)")
            return false
        }
    }

    private static func removeDPAPIFile(key: KeychainCacheStore.Key) -> Bool {
        let url = Self.dpapiBlobURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func dpapiEncrypt(_ data: Data) -> Data? {
        data.withUnsafeBytes { rawBuf in
            var input = WinSDK.DATA_BLOB(
                cbData: WinSDK.DWORD(data.count),
                pbData: UnsafeMutablePointer(mutating: rawBuf.bindMemory(to: WinSDK.BYTE.self).baseAddress))
            var output = WinSDK.DATA_BLOB()
            guard WinSDK.CryptProtectData(&input, nil, nil, nil, nil, 0, &output) else { return nil }
            defer { WinSDK.LocalFree(output.pbData) }
            return Data(bytes: output.pbData!, count: Int(output.cbData))
        }
    }

    private static func dpapiDecrypt(_ data: Data) -> Data? {
        data.withUnsafeBytes { rawBuf in
            var input = WinSDK.DATA_BLOB(
                cbData: WinSDK.DWORD(data.count),
                pbData: UnsafeMutablePointer(mutating: rawBuf.bindMemory(to: WinSDK.BYTE.self).baseAddress))
            var output = WinSDK.DATA_BLOB()
            guard WinSDK.CryptUnprotectData(&input, nil, nil, nil, nil, 0, &output) else { return nil }
            defer { WinSDK.LocalFree(output.pbData) }
            return Data(bytes: output.pbData!, count: Int(output.cbData))
        }
    }
}
#endif
