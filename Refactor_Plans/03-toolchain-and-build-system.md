# 03 — Toolchain & Build System (Windows)

Goal: get `swift build` producing `codexbar.exe` and `CodexBarCore` on Windows,
and stand up the C#/WinUI shell build. This is the first executable milestone and
unblocks every other workstream.

> Verify exact version numbers against swift.org and Microsoft docs at execution
> time; treat versions here as "known‑good baselines," not pins.

## 1. Swift on Windows — what you need

Swift has supported Windows since 5.3 and is mature on 6.x. Install:

1. **Visual Studio 2022 Build Tools** (or full VS) with:
   - *Desktop development with C++* workload (MSVC toolset, Windows SDK).
   - The Windows 10/11 SDK (for WinSDK headers the toolchain links against).
2. **Swift toolchain for Windows** (from swift.org, matching the repo's
   `swift-tools-version`, i.e. **Swift 6.2+**). Install via the official
   installer or **winget**:
   ```powershell
   winget install --id Swift.Toolchain -e        # or the swift.org .exe installer
   ```
3. **Git for Windows**, **CMake**, and **Python 3** (swift‑syntax / build deps may
   want them). Most are pulled in by the VS workload.

Validate:
```powershell
swift --version          # expect Swift 6.2.x, target x86_64-unknown-windows-msvc
swift build --help
```

### Architectures
Target **x64** first (broadest install base), then **ARM64** (Windows on ARM /
Snapdragon laptops). The Swift toolchain supports both `x86_64` and `aarch64`
`-windows-msvc` triples. CI should build both (see `09`).

## 2. `Package.swift` changes

The package already gates macOS executables behind `#if os(macOS)`, so Windows
gets Core + CLI for free *if dependencies resolve*. Required changes:

### 2.1 Platforms
`platforms: [.macOS(.v14)]` constrains SwiftPM. This does **not** prevent building
on Windows (the `platforms` list declares *minimum Apple OS versions*, not an
allowlist), but confirm during bring‑up. No Windows entry exists in the
`SupportedPlatform` enum, so nothing to add there.

### 2.2 Dependency audit (the real gate)
Every package dependency must build on Windows or be excluded from the Windows
graph. Today's dependencies:

| Dependency | Used by | Windows status | Action |
|---|---|---|---|
| `swift-crypto` | Core | ✅ builds (BoringSSL) | keep |
| `swift-log` | Core/CLI | ✅ | keep |
| `swift-syntax` | macros (build‑time) | ✅ builds on Windows | keep |
| `Commander` | CLI | pure Swift — ⚠️ verify | keep, test build |
| `Sparkle` | app only | ❌ macOS‑only | already `#if os(macOS)`‑gated; ensure not in Windows graph |
| `KeyboardShortcuts` | app only | ❌ macOS‑only | gated to app target — fine |
| `Vortex` | app only | ❌ macOS‑only | gated to app target — fine |
| `SweetCookieKit` | **Core** | ❌ macOS‑only | **blocker** — see below |

**The critical issue:** `SweetCookieKit` is a dependency of **`CodexBarCore`**
(not just the app), and Core must build on Windows. Options, in order of
preference:
1. Make the SweetCookieKit dependency **conditional** so it's only linked on
   Apple platforms, and put all SweetCookieKit call‑sites behind
   `#if canImport(SweetCookieKit)` (some already are). Then provide a Windows
   cookie backend (see `05`). SwiftPM can't conditionalize a *dependency* by OS
   directly in the manifest, but you can:
   - Split cookie code into a separate target that only Apple builds link, **or**
   - Use the existing env‑switch pattern (`Package.swift` already branches
     SweetCookieKit local vs remote via `ProcessInfo`) to **omit** it for Windows
     builds via a `CODEXBAR_WINDOWS=1`‑style manifest branch, **or**
   - Vendor a thin `CookieBackend` protocol in Core, with the SweetCookieKit
     implementation compiled only on Apple platforms.
2. Confirm whether SweetCookieKit *itself* compiles on Windows (it's
   Keychain/Chromium‑oriented — almost certainly macOS‑only). Assume **no**.

> **Recommended:** introduce a `CookieBackend` protocol in Core and move
> SweetCookieKit behind it (`#if canImport(SweetCookieKit)`), with a Windows
> implementation. This also cleanly decouples cookie storage for testing. Detailed
> in `05 §3`.

### 2.3 Macros on Windows
`CodexBarMacros` is a compiler plugin built with swift‑syntax. swift‑syntax builds
on Windows and SwiftPM runs macro plugins on Windows, so `@...` provider‑
registration macros should work. **Risk:** macro plugin execution can be finicky
on first Windows bring‑up; if blocked, the fallback is to pre‑expand macros or
guard with prebuilt sources. Track as a bring‑up risk (`11`).

## 3. Foundation feature flags

Mirror the existing non‑Darwin patterns; Windows is "not Darwin":
- Networking: `#if canImport(FoundationNetworking) import FoundationNetworking`
  (already pervasive) — gives `URLSession` on Windows.
- XML: `FoundationXML` similarly (`#if canImport(FoundationXML)`).
- Crypto: prefer `swift-crypto` (`import Crypto`) on non‑Apple; CryptoKit stays
  behind `#if canImport(CryptoKit)`.

## 4. Local build commands (Windows)

```powershell
# Engine + CLI (debug)
swift build --product CodexBarCLI

# Release
swift build -c release --product CodexBarCLI

# Run the server
.\.build\release\codexbar.exe serve --port 8765 --refresh-interval 60

# Run a one-shot
.\.build\release\codexbar.exe usage --provider codex --format json
```

The macOS `Makefile`/`Scripts/*.sh` are Bash + macOS‑tool based and won't run as‑
is on Windows. Add a parallel **PowerShell** build surface under `/windows/build/`
(see `08`), e.g. `build-engine.ps1`, `build-shell.ps1`, `package-msix.ps1`.

## 5. C#/.NET shell toolchain (Option B)

- **.NET 8 SDK** (LTS) + **Windows App SDK / WinUI 3** workload.
- **WebView2 SDK** (NuGet `Microsoft.Web.WebView2`) + the Evergreen runtime
  bootstrapper.
- Build:
  ```powershell
  dotnet build windows/CodexBar.Shell/CodexBar.Shell.csproj -c Release
  ```
- The shell project references the WebView2, charting (e.g. `LiveChartsCore` or
  WinUI `CommunityToolkit` charts), and notification packages — finalized in `07`.

## 6. Wiring the engine into the shell build

The MSIX/MSI must bundle:
- `codexbar.exe` (+ the **Swift runtime redistributable DLLs** — the Swift
  Windows runtime is *not* assumed present on user machines; ship the
  `swiftCore.dll`, `Foundation.dll`, `FoundationNetworking.dll`, BlocksRuntime,
  dispatch, etc. produced/located by the toolchain).
- The .NET app (self‑contained publish to avoid a separate .NET install, or
  framework‑dependent + bundle the runtime).
- WebView2 Evergreen bootstrapper.

Packaging detail lives in `08`; this section just flags that **the engine binary +
Swift runtime are build artifacts the shell packaging consumes.**

## 7. Bring‑up checklist (Milestone 0)

- [ ] Swift 6.2 toolchain + VS C++ workload installed; `swift --version` OK.
- [ ] Dependency graph resolves on Windows with SweetCookieKit excluded/gated.
- [ ] `CodexBarCore` compiles (with Windows shims stubbed to no‑op where needed).
- [ ] `CodexBarCLI` compiles → `codexbar.exe`.
- [ ] `codexbar.exe usage --provider <api-key-provider> --format json` returns
      valid JSON for at least one **API‑key** provider (no cookies/Keychain).
- [ ] `codexbar.exe serve` starts and `GET /health` returns `{"status":"ok"}`.
- [ ] .NET 8 + WinUI 3 "hello tray" builds and shows a tray icon.
- [ ] CI Windows job builds the engine (see `09`).

Hitting this checklist proves the architecture end‑to‑end before investing in the
full UI and the harder shims.
