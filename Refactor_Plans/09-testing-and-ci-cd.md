# 09 — Testing & CI/CD (Windows)

The macOS project has a large XCTest/swift‑testing suite (the `Tests/` directory
holds 200+ test files) plus a Linux test target (`TestsLinux`). The strategy for
Windows: **run the portable tests on a Windows runner from day one**, add
Windows‑specific shim tests, and keep the engine honest continuously — exactly how
Linux portability is maintained today.

## 1. Test inventory today

- `Tests/CodexBarTests` — the big suite; depends on `CodexBar` (macOS app),
  `CodexBarCore`, `CodexBarCLI`, `CodexBarWidget`. **macOS‑gated** in
  `Package.swift` (inside `#if os(macOS)`).
- `TestsLinux` — a separate target depending only on `CodexBarCore` + `CodexBarCLI`
  (the portable surface). **This is the template for Windows tests.**
- Tooling: `Scripts/ci_swift_test_by_suite.py`, `Scripts/test.sh`, sharding
  helpers (the suite is sharded because macOS AppKit/menu tests are brittle).

## 2. Windows test strategy

### 2.1 Reuse the Linux test target
`TestsLinux` already exercises Core + CLI without any UI. **Run it on Windows.**
Most provider parsing/usage/config/serve tests are pure logic and should pass once
the engine compiles. Add a `CodexBarWindowsTests` target only if Windows‑specific
test code is needed; otherwise point CI at the existing portable target.

> Audit which `Tests/CodexBarTests` cases are actually engine‑level (parsers,
> provider fetchers with stubs, `CLIServeRouterTests`, `CostUsage*Tests`,
> `ProviderRegistryTests`, etc.) versus AppKit/menu‑bound. The engine‑level ones
> can likely be shared into the portable target and run on Windows + Linux. This
> *increases* cross‑platform coverage as a side benefit.

### 2.2 New Windows shim tests (Swift)
Add focused tests for each new Windows backend:
- `WindowsCredentialSecretStore` round‑trip (write/read/delete/enumerate, large‑
  blob DPAPI fallback).
- `WindowsChromiumCookieBackend` v10/v11 decryption against **synthetic fixtures**
  (a known key + AES‑GCM‑encrypted value — never real user cookies).
- `SubprocessRunner` process‑tree kill via Job Object (spawn a child that spawns a
  grandchild; assert the tree dies).
- Executable resolution with `PATH`/`PATHEXT`.
- `WindowsPTY`/ConPTY smoke test (echo round‑trip) once implemented.
- Path mapping tests (`~`, `%APPDATA%`, browser profile discovery) with injected
  environment.

Follow the repo conventions (AGENTS.md): `FeatureNameTests` with
`test_caseDescription`; **never** run tests that touch real credentials/cookies —
use stubs/fixtures/test stores (the existing `KeychainCacheStore` test‑store
override pattern extends to the `SecretStore` protocol).

### 2.3 Shell tests (C#)
- Unit tests for DTO parsing of `/usage`/`/cost` JSON (golden files captured from
  the CLI).
- Notification‑rule tests (port `QuotaWarningNotificationLogic` cases) — *or* keep
  the rule in the engine and test it there (preferred).
- Sidecar lifecycle tests (spawn/health/restart) with a stub server.
- Optional UI automation (WinAppDriver/Appium) for tray + settings smoke — keep
  light; UI automation is as brittle on Windows as headless AppKit is on macOS
  (AGENTS.md already warns about this for mac).

## 3. CI/CD

### 3.1 Add a Windows engine job (highest priority)
In `.github/workflows`, add a job on `windows-latest`:
```yaml
jobs:
  windows-engine:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: compnerd/gha-setup-swift@main   # or swift.org setup action
        with: { swift-version: "6.2" }
      - run: swift build -c release --product CodexBarCLI
      - run: swift test --filter CodexBarLinuxTests   # the portable suite
```
This catches portability regressions on every PR, the same role the Linux build
plays. Make it **required** once green.

### 3.2 Build matrix
- Arch: `x64` and `arm64` (cross/native).
- Configs: debug (tests) + release (artifacts).
- Keep macOS/Linux jobs unchanged; Windows is additive.

### 3.3 Sharding
Reuse the sharding approach (`ci_swift_test_by_suite.py`) if the Windows suite
grows large; initially the portable subset is small enough to run unsharded.

### 3.4 Release pipeline
On tags, a `windows-release` job runs the PowerShell pipeline from `08` (build →
sign → package → publish). Signing secrets (cert + password / Azure Trusted
Signing) go in GitHub Actions secrets; consider **Azure Trusted Signing** to avoid
managing a physical cert.

## 4. Manual/live testing policy

Carry over the macOS rule (AGENTS.md): **never auto‑run live provider probes** that
hit real accounts or touch real secrets in CI. Windows CI runs parser/stub tests
only. Live validation is manual, opt‑in (`LIVE_TEST=1`‑style), and done by a human
on a real Windows box with real browser sessions.

## 5. Definition of done

- [ ] Windows engine build job green on every PR (x64 at minimum).
- [ ] Portable test target passes on Windows.
- [ ] Each Windows shim has fixture‑based tests.
- [ ] Release job produces signed MSIX + CLI zip on tags.
- [ ] No regressions to macOS/Linux CI.
