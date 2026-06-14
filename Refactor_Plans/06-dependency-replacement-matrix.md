# 06 — Dependency & Framework Replacement Matrix

Every external dependency and Apple framework, with a **keep / replace / drop**
verdict and the Windows equivalent. "Sites" = number of source files referencing
it (from the audit in `01`).

## 1. SwiftPM package dependencies

| Dependency | Sites | Used by | Verdict | Windows plan |
|---|---:|---|---|---|
| `swift-crypto` | 3 | Core | **Keep** | Builds on Windows (BoringSSL). Make it the default crypto on non‑Apple; route `CommonCrypto`/`CryptoKit` sites through it. |
| `swift-log` | 5 | Core/CLI | **Keep** | Cross‑platform. Make the swift‑log backend active on Windows (no `os.Logger`). |
| `swift-syntax` | (build) | macros | **Keep** | Builds on Windows; powers `CodexBarMacros`. Validate plugin execution early (`03 §2.3`). |
| `Commander` | 12 | CLI | **Keep (verify)** | Pure‑Swift arg parser; expected to build on Windows. Add to Windows CI immediately to confirm. |
| `Sparkle` | 1 (3 sites) | app | **Replace** | macOS auto‑update. Windows: **WinSparkle**, **MSIX app‑installer auto‑update**, or **winget**. See `08`. |
| `KeyboardShortcuts` | 3 | app | **Replace** | Windows global hotkeys via **`RegisterHotKey`** (Win32) from the shell. |
| `Vortex` | 1 | app | **Replace/Drop** | SwiftUI particle confetti (weekly‑reset celebration). Cosmetic — drop for v1, or reimplement with a WinUI animation/Composition particles later. |
| `SweetCookieKit` | 37 | **Core** | **Replace** | Browser cookies. Biggest dependency concern (it's in Core). `CookieBackend` abstraction + Windows Chromium decryptor — see `05 §3`. |

## 2. Apple frameworks (system)

| Framework | Sites | Verdict | Windows equivalent |
|---|---:|---|---|
| `Foundation` | 572 | **Keep** | swift‑foundation; verify thinner APIs (`04 §3`). |
| `FoundationNetworking` | 68 | **Keep** | URLSession on Windows — already gated. |
| `FoundationXML` | 1 | **Keep** | XML parsing on non‑Apple — gate `#if canImport(FoundationXML)`. |
| `AppKit` | 107 | **Replace (UI)** | All UI → WinUI 3 shell. 4 Core files must be gated/moved (`04 §7`). |
| `SwiftUI` | 80 | **Replace (UI)** | WinUI 3 / XAML (Option B) or swift‑winrt (Option A). |
| `WidgetKit` | 4 | **Drop (v1)** | No equivalent. Optional: Windows 11 widgets later (`10`). |
| `WebKit` | 7 | **Replace** | **WebView2** (Edge/Chromium). Engine `OpenAIWeb/` → shell WebView2 or defer (`04 §8`). |
| `Security` | 18 | **Replace** | Credential Manager + DPAPI (`05 §1`). |
| `CryptoKit` | 6 | **Replace** | `swift-crypto` on Windows. |
| `CommonCrypto` | 1 | **Replace** | `swift-crypto`. |
| `QuartzCore` | 9 | **Replace (UI)** | WinUI Composition / Direct2D timing (shell). |
| `CoreGraphics` | 2 | **Replace (UI)** | Direct2D / `System.Drawing` / Win2D for icon rendering. |
| `CoreVideo` | 1 | **Replace (UI)** | Display‑link → WinUI `CompositionTarget`/timer. |
| `ServiceManagement` | 3 | **Replace** | Login‑item → Windows autostart (Startup registry / Startup Task in MSIX). See `08`. |
| `LocalAuthentication` | 3 | **Replace/Optional** | Windows Hello (`Windows.Security.Credentials.UI`) — optional; likely not required for v1. |
| `UserNotifications` | 1 | **Replace** | Windows toast notifications (`Windows.UI.Notifications` / `CommunityToolkit.Notifications`). |
| `os` (Logger) | 5 | **Replace** | swift‑log on Windows. |
| `Darwin` | 24 | **Replace** | `WinSDK` / ucrt arms (`04 §1`). |
| `SQLite3` | 6 | **Keep (relink)** | `winsqlite3.dll` (`04 §5`). |
| `Network` | 1 | **Verify/Replace** | If `NWConnection` is used, swap for `URLSession`/sockets on Windows. |
| `UniformTypeIdentifiers` | 1 | **Replace** | Trivial — content‑type via extension/MIME map. |

## 3. The macOS‑only executables

| Target | Verdict | Windows plan |
|---|---|---|
| `CodexBar` (app) | **Reimplement** | New WinUI 3 shell (`07`). |
| `CodexBarWidget` | **Drop (v1)** | WidgetKit has no Windows analogue. |
| `CodexBarClaudeWatchdog` | **Defer** | Tied to PTY; revisit after ConPTY (`04 §2.5`). |
| `CodexBarClaudeWebProbe` | **Defer/Replace** | Diagnostic; reimplement with WebView2 if needed. |

## 4. Net dependency picture on Windows

**Engine (Swift) keeps:** swift‑crypto, swift‑log, swift‑syntax, Commander, SQLite
(relinked). **Drops from engine graph:** SweetCookieKit (replaced by in‑repo
`CookieBackend`), all Apple UI frameworks.

**Shell (C#/.NET, new):** Windows App SDK / WinUI 3, WebView2, a charting library,
toast‑notification package, MSIX tooling.

This means the **only third‑party Swift dependency we must actively replace inside
the portable engine is SweetCookieKit** — everything else either already builds on
Windows or lives in the (replaced) UI layer. That is a strong portability signal.

## 5. Per‑dependency effort

| Replacement | Effort | Risk |
|---|---|---|
| swift‑crypto routing (CryptoKit/CommonCrypto) | S | low |
| swift‑log on Windows | S | low |
| Commander verify | S | low |
| Sparkle → Windows updater | M | medium (see `08`) |
| KeyboardShortcuts → RegisterHotKey | S | low |
| Vortex → drop/reimpl | S | low |
| **SweetCookieKit → CookieBackend** | **L** | **high** (`05`) |
| WidgetKit → drop | S | low |
| WebKit → WebView2/defer | M | medium |
| Security → Credential Manager/DPAPI | L | high (`05`) |
| Autostart, notifications, hotkeys (shell) | M | low‑med |
