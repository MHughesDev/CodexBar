import Foundation

// MARK: - CookieBackend Protocol

/// A platform-agnostic abstraction over browser cookie extraction.
///
/// On macOS the implementation delegates to SweetCookieKit.
/// On Windows a native Chromium/Firefox decryptor is provided.
/// On Linux/other platforms a no-op backend is used.
public protocol CookieBackend: Sendable {
    /// Returns a `Cookie: name=value; …` HTTP header string for cookies matching
    /// the given URL, optionally restricted to a named browser.
    ///
    /// Returns `nil` when no matching cookies are found or the backend is unavailable.
    func cookieHeader(for url: URL, browserHint: String?) async -> String?

    /// Returns the list of browser names available on this platform.
    func availableBrowsers() -> [String]
}

// MARK: - Factory

public enum CookieBackendFactory {
    /// Returns the appropriate `CookieBackend` for the current platform.
    public static func make() -> any CookieBackend {
        #if canImport(SweetCookieKit) && os(macOS)
        return SweetCookieKitCookieBackend()
        #elseif os(Windows)
        return WindowsCookieBackend()
        #else
        return NoopCookieBackend()
        #endif
    }
}

// MARK: - macOS backend (SweetCookieKit)

#if canImport(SweetCookieKit) && os(macOS)
import SweetCookieKit

/// macOS backend — delegates to SweetCookieKit for Chromium Safe Storage decryption
/// and Safari/Firefox plaintext extraction. Existing behaviour is unchanged.
public struct SweetCookieKitCookieBackend: CookieBackend {
    private static let log = CodexBarLog.logger("cookie-backend-macos")
    private let client = BrowserCookieClient()

    public init() {}

    public func cookieHeader(for url: URL, browserHint: String?) async -> String? {
        guard let host = url.host else { return nil }
        // Build a domain list: exact host + parent domain.
        var domains: [String] = [host]
        let parts = host.split(separator: ".")
        if parts.count >= 2 {
            domains.append(parts.suffix(2).joined(separator: "."))
        }
        let query = BrowserCookieQuery(domains: domains)
        // Attempt each available browser in default import order.
        let detection = BrowserDetection()
        let browsers = Browser.defaultImportOrder.cookieImportCandidates(using: detection)
        for browserSource in browsers {
            if let hint = browserHint,
               !browserSource.displayName.lowercased().contains(hint.lowercased())
            {
                continue
            }
            do {
                let sources = try self.client.codexBarRecords(matching: query, in: browserSource)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if !cookies.isEmpty {
                        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    }
                }
            } catch {
                Self.log.debug("Cookie fetch failed for \(browserSource.displayName): \(error.localizedDescription)")
            }
        }
        return nil
    }

    public func availableBrowsers() -> [String] {
        let detection = BrowserDetection()
        return Browser.defaultImportOrder
            .filter { detection.isAppInstalled($0) }
            .map(\.displayName)
    }
}
#endif

// MARK: - Linux / fallback no-op backend

#if !os(macOS) && !os(Windows)
/// No-op backend for platforms without a native cookie store (Linux, etc.).
public struct NoopCookieBackend: CookieBackend {
    public init() {}

    public func cookieHeader(for _: URL, browserHint _: String?) async -> String? {
        nil
    }

    public func availableBrowsers() -> [String] {
        []
    }
}
#endif

// Windows backend lives in WindowsCookieBackend.swift (guarded by #if os(Windows)).
