# 01 — Current Architecture Audit

This is the factual baseline for the port. All numbers were measured from the
repository (`Sources/`) at planning time. Re‑run the commands at the end of this
doc to refresh before starting work.

## 1. Size & module map

**~158,900 lines of Swift across 685 files** in 8 SwiftPM targets.

| Target | Files | Role | Platform today |
|---|---:|---|---|
| `CodexBarCore` | 364 | **Engine**: providers, fetch/parse, OAuth, cookies, status polling, cost scans | macOS + **Linux** (cross‑platform) |
| `CodexBar` | 294 | **macOS UI**: `UsageStore`, `StatusItemController`, menus, icon rendering, SwiftUI settings | macOS only |
| `CodexBarCLI` | 20 | `codexbar` CLI incl. `serve` local HTTP server | macOS + **Linux** |
| `CodexBarWidget` | 3 | WidgetKit extension | macOS only |
| `CodexBarMacros` | 1 | SwiftSyntax macro plugin (provider registration) | build‑time, all platforms |
| `CodexBarMacroSupport` | 1 | Shared macro support | all platforms |
| `CodexBarClaudeWatchdog` | 1 | Helper process for stable Claude PTY sessions | macOS only |
| `CodexBarClaudeWebProbe` | 1 | CLI helper to diagnose Claude web fetches | macOS only |

`Sources/CodexBarCore/Providers/` contains **49 provider subdirectories** — the
bulk of the value and the part we most want to reuse verbatim.

### Products declared in `Package.swift`
- Always: `CodexBarCore` (library), `CodexBarCLI` (executable).
- `#if os(macOS)` only: `CodexBar`, `CodexBarClaudeWatchdog`, `CodexBarWidget`,
  `CodexBarClaudeWebProbe`.

**This is the most important structural fact:** the package *already* conditions
the macOS‑only executables behind `#if os(macOS)` and ships Core+CLI everywhere.
Windows slots into the existing non‑macOS path.

## 2. Platform‑coupling inventory (imports)

Import frequency across `Sources/` (top entries):

| Import | Files | Portability note |
|---|---:|---|
| `Foundation` | 572 | Cross‑platform (swift‑foundation). Some APIs thinner on Windows — see `04`. |
| `CodexBarCore` | 259 | Internal. |
| `AppKit` | 107 | **macOS‑only.** 103 in the app, **4 in Core** (must be checked). |
| `CodexBarMacroSupport` | 98 | Internal. |
| `SwiftUI` | 80 | **macOS‑only here.** 77 app + 3 widget; **0 in Core.** |
| `FoundationNetworking` | 68 | Already gated `#if canImport(FoundationNetworking)` for non‑Darwin URLSession — **works on Windows.** |
| `SweetCookieKit` | 37 | **macOS‑only dependency** (browser cookies). See `05`. |
| `Darwin` | 24 | **macOS‑only.** Paired with `Glibc` via `#if canImport(Darwin)`; needs a Windows arm. |
| `Security` | 18 | **macOS‑only** (Keychain). 8 in Core, 10 in app. See `05`. |
| `Glibc` | 16 | Linux syscalls; Windows needs `WinSDK`/ucrt arm. |
| `Observation` | 12 | Cross‑platform (Swift). |
| `Commander` | 12 | CLI arg parser dependency — pure Swift, expected to build on Windows. |
| `QuartzCore` | 9 | macOS‑only (animation/timing). App layer. |
| `WebKit` | 7 | **macOS‑only.** 6 in Core (`OpenAIWeb/`), 1 app. See `06`. |
| `SQLite` / `SQLite3` | 6 | System SQLite. Windows: bundle `sqlite3` or use `winsqlite3.dll`. |
| `CryptoKit` | 6 | macOS crypto; `swift-crypto` is the cross‑platform fallback already in use. |
| `WidgetKit` | 4 | **macOS‑only.** Out of scope v1. |
| `ServiceManagement` | 3 | macOS login‑items; replace with Windows autostart. |
| `LocalAuthentication` | 3 | macOS biometrics; Windows Hello optional. |
| `KeyboardShortcuts` | 3 | **macOS‑only dependency**; replace with `RegisterHotKey`. |
| `Crypto` (swift‑crypto) | 3 | **Cross‑platform** (BoringSSL) — already a dependency. |
| `Sparkle` | 1 | **macOS‑only dependency**; replace with Windows updater. |
| `Vortex` | 1 | **macOS‑only dependency** (SwiftUI confetti); replace/drop. |

### Conditional‑compilation already present

| Directive | Count | Meaning |
|---|---:|---|
| `#if os(macOS)` | 152 | macOS‑gated code (mostly app; some Core). The Windows arm goes here. |
| `#if canImport(FoundationNetworking)` | 68 | Non‑Darwin URLSession — already Windows‑friendly. |
| `#if canImport(Darwin)` | 30 | Darwin vs. else (Glibc) — needs Windows handling. |
| `#if canImport(SQLite3)` | 6 | SQLite availability gate. |
| `#if !os(macOS)` / `#if os(Linux)` | 8 | Existing non‑macOS arms — templates for Windows. |
| `#if canImport(CryptoKit)` | 4 | CryptoKit vs swift‑crypto. |
| `#if canImport(WidgetKit)` | 2 | Widget gate. |

**Takeaway:** the codebase is already a *3‑platform shape* (macOS / Linux / "else").
Windows is the third concrete platform. Most work is filling in `#else`/Windows
arms that currently no‑op, plus building a new shell.

## 3. The engine is (almost) clean

`CodexBarCore` (364 files) platform imports:

- `AppKit`: **4 files** — must be audited and gated/relocated (likely
  icon/`NSImage` helpers or pasteboard; should move to the shell or behind
  `#if os(macOS)`).
- `SwiftUI`: **0 files** ✅
- `Security`: **8 files** — Keychain (cache store, OAuth credential stores,
  no‑UI query, access gates). Already `#if os(macOS) … #else return .missing`
  shaped in `KeychainCacheStore.swift`. See `05`.
- `WebKit`: **6 files**, all under `OpenAIWeb/` — the offscreen WKWebView used to
  scrape the OpenAI dashboard for one provider's *optional* extras. Isolated. See `06`.
- POSIX syscalls (`Darwin`/`Glibc`): subprocess + PTY runners under `Host/`,
  plus assorted `usleep`/`kill`/`setpgid`. See `04`.

Everything else in Core is Foundation‑level networking, JSON/text parsing,
config files, and cookie/SQLite reads — portable in principle.

## 4. Platform‑abstraction seams that already exist

These are the hook points the port plugs into:

| Seam | File(s) | Current behavior off‑macOS |
|---|---|---|
| Subprocess | `CodexBarCore/Host/Process/SubprocessRunner.swift`, `ProcessPipeCapture.swift` | Uses `Foundation.Process` + POSIX `setpgid`/`kill`/`usleep`. Needs Windows process‑group handling. |
| PTY | `CodexBarCore/Host/PTY/TTYCommandRunner.swift` | POSIX `forkpty`/`openpty` for Claude CLI. **No Windows arm** → ConPTY. |
| Keychain | `KeychainCacheStore.swift`, `KeychainNoUIQuery.swift`, `KeychainAccessGate.swift`, `KeychainAccessPreflight.swift`, provider OAuth stores | `#if os(macOS) … #else return .missing/.failed`. Windows arm = Credential Manager/DPAPI. |
| Browser cookies | `BrowserDetection.swift`, `BrowserCookieImportOrder.swift`, `BrowserCookieAccessGate.swift`, 30+ provider importers | All via `SweetCookieKit` (macOS). Needs a Windows cookie backend. |
| Embedded browser | `OpenAIWeb/OpenAIDashboard*.swift`, `WebKit/WebKitTeardown.swift` | WKWebView. Windows arm = WebView2 (or drop the optional extra). |
| Autorelease pool | `AutoreleasePoolCompat.swift` | `#if os(Linux)` no‑op shim. Extend to Windows. |
| Networking | 68 files | `#if canImport(FoundationNetworking) import FoundationNetworking` — already correct for Windows. |

## 5. The integration seam for a Windows UI: `codexbar serve`

`CodexBarCLI/CLIServeCommand.swift` + `CLILocalHTTPServer.swift` implement a
localhost HTTP/JSON server:

- Routes: `GET /health`, `GET /usage?provider=…`, `GET /cost?provider=…`.
- Options: `--port` (default 8080), `--refresh-interval` (cache TTL, default 60s),
  `--request-timeout` (default 30s), `--json-output`, `--log-level`.
- Returns the exact same payloads the CLI emits (`output.payload`), with response
  caching, stale‑fallback, and per‑request deadlines.

This is already how Linux desktop integrations (Waybar, GNOME extension,
SketchyBar/`showy-quota`, Noctalia) consume CodexBar. **A Windows tray UI can use
the identical contract**, which is the backbone of the recommended architecture
(see `02`).

## 6. Build, scripts & release surface (all macOS‑shaped today)

- `Package.swift` — SwiftPM, `swift-tools-version: 6.2`, `platforms: [.macOS(.v14)]`.
- `Scripts/` — `package_app.sh`, `compile_and_run.sh`, `sign-and-notarize.sh`,
  `make_appcast.sh` (Sparkle), `build_icon.sh`, etc. **Bash + macOS tools.**
- `Makefile` — `swift build`/`swift test` plus macOS `open`/`pkill` targets.
- `appcast.xml`, `.mac-release.env`, `Icon.icns`, `WidgetExtension/` — macOS
  packaging artifacts.
- CI: `.github/` (audit separately — see `09`).

Windows needs its own packaging/build path (see `03`, `08`, `09`); none of the
macOS scripts are reusable directly, though their *logic* (build → sign →
appcast/update feed) maps over.

## 7. What this means for the plan

1. **~95K LOC engine is the reuse target** and is already Linux‑portable —
   Windows is incremental, not greenfield, for the engine.
2. **~294 files of macOS UI have no Windows equivalent** and define the shell
   workstream (the largest *new* build).
3. The **deep platform shims** (Keychain, cookies, PTY, WebView) are a bounded,
   enumerable list — not scattered everywhere.
4. The **`serve` seam** lets the UI and engine evolve independently and keeps
   provider behavior identical across OSes.

## Appendix — commands to refresh these numbers

```bash
# Total Swift files / LOC
find Sources -name '*.swift' | wc -l
find Sources -name '*.swift' -exec cat {} + | wc -l

# Per‑target file counts
for d in Sources/*/; do printf "%-30s " "$d"; find "$d" -name '*.swift' | wc -l; done

# Import frequency
grep -rhoE '^import [A-Za-z_]+' Sources --include='*.swift' | sort | uniq -c | sort -rn

# Conditional compilation
grep -rhoE '#if .*(os\(|canImport\()[^)]*\)' Sources --include='*.swift' | sort | uniq -c | sort -rn

# Per‑target platform import breakdown
for d in Sources/*/; do printf "%-30s AppKit:"; grep -rl 'import AppKit' "$d" --include='*.swift' 2>/dev/null | wc -l; done
```
