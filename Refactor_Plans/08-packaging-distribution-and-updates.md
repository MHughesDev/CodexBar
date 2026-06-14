# 08 — Packaging, Distribution & Updates (Windows)

Replaces the macOS packaging path (`.app` bundle, ad‑hoc/Developer ID signing,
notarization, Sparkle `appcast.xml`) with a Windows equivalent.

## 1. What must ship together

A Windows install contains:
1. **`codexbar.exe`** (engine/CLI) + **the Swift Windows runtime DLLs**
   (swiftCore, Foundation, FoundationNetworking, dispatch, BlocksRuntime, etc.).
   The Swift runtime is **not** present on user machines — bundle it.
2. **The shell** (`CodexBar.exe`): WinUI 3 app + its dependencies.
   - **Windows App SDK** runtime (framework‑dependent or self‑contained).
   - **.NET 8** runtime (use **self‑contained** publish to avoid a separate
     install, at the cost of size).
   - **WebView2** runtime (ship the **Evergreen bootstrapper**; don't bundle a
     fixed version unless required).
3. App icon(s) as `.ico`, license, and (optionally) the bundled CLI on `PATH`
   (mirroring `bin/install-codexbar-cli.sh` on macOS).

## 2. Installer format

| Format | Verdict | Notes |
|---|---|---|
| **MSIX** | **Primary** | Clean install/uninstall, per‑user, Startup Task for autostart, built‑in app‑installer auto‑update, Store‑ready, sandbox‑friendly. Requires all components to be packageable (WebView2 Evergreen is fine; Swift DLLs ship as plain files inside the package). |
| **MSI** (WiX) | **Fallback** | Maximum compatibility, enterprise‑friendly, classic install dir. Use if MSIX constraints (e.g. CLI on global `PATH`, unrestricted file access to browser profiles) bite. |
| **winget** | **Distribution channel** | Publish either format to winget‑pkgs for `winget install CodexBar`. |
| **Portable ZIP** | **Nice‑to‑have** | A no‑install zip for the CLI alone (mirrors the macOS/Linux CLI tarballs the README already ships). |

> **Decision needed (OD‑2 in `11`):** MSIX vs MSI as primary. Recommendation: MSIX
> for the GUI app, **plus** a portable ZIP for the standalone `codexbar.exe` CLI so
> Windows users get the same "just the CLI" option Linux users have today.

### Browser‑profile access caveat for MSIX
MSIX apps run with some virtualization. Reading other apps' files under
`%LOCALAPPDATA%` (browser cookies) generally works for the **current user**, but
validate cookie reads from within the packaged/sandboxed context early — if MSIX
restricts it, either declare the right capability or fall back to MSI for the
cookie‑reading build. (Tracked as a risk in `11`.)

## 3. Code signing (Authenticode)

- Acquire an **Authenticode code‑signing certificate** (OV, or **EV** for instant
  SmartScreen reputation). Without signing, SmartScreen will warn users.
- Sign **`codexbar.exe`, the shell `.exe`, and the installer** with
  `signtool` (SHA‑256, timestamped).
- For MSIX, the package signing cert's publisher must match the manifest
  `Publisher`.
- This is the Windows analogue of macOS Developer ID + notarization; there is **no
  notarization step**, but SmartScreen reputation accrues over signed downloads
  (EV bypasses the warm‑up).

## 4. Auto‑update

Three viable mechanisms (replacing Sparkle):

| Mechanism | Pros | Cons | Fit |
|---|---|---|---|
| **MSIX app‑installer auto‑update** | Built into Windows; declarative update URI; no extra code | MSIX‑only; needs a hosted `.appinstaller` + packages | **Recommended if MSIX is primary** |
| **WinSparkle** | Sparkle‑like; reuses the **existing appcast mental model**; works with MSI/portable | C library to integrate into the shell; you host the appcast/feed | **Recommended if MSI/portable primary** |
| **winget upgrade** | Zero in‑app code | User‑initiated; not silent/auto | Complementary channel |

Recommendation: pick the updater that matches the primary installer (MSIX →
app‑installer; MSI → WinSparkle). Keep a **single version source** (`version.env`
already exists) feeding both macOS and Windows release metadata.

### Update feed
- MSIX: host an `.appinstaller` XML pointing at versioned packages.
- WinSparkle: host a Windows `appcast.xml` (separate from the macOS Sparkle
  `appcast.xml`; different signatures/enclosures). Reuse the *generation* approach
  from `Scripts/make_appcast.sh` logic, re‑implemented in PowerShell.

## 5. Autostart (launch at login)

Replaces `ServiceManagement` login item:
- **MSIX:** declare a **Startup Task** (`windows.startupTask` extension) toggled by
  the OS Settings → Startup apps and via the app.
- **MSI/portable:** write `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
  (per‑user) on enable; remove on disable.

## 6. Build & release pipeline (Windows)

Add PowerShell scripts under `/windows/build/` (parallel to macOS `Scripts/`):

```
windows/build/
  build-engine.ps1     # swift build -c release --product CodexBarCLI (x64, arm64)
                       # + collect Swift runtime DLLs
  build-shell.ps1      # dotnet publish -c Release (self-contained, per arch)
  package-msix.ps1     # makeappx + signtool  → CodexBar-<ver>-<arch>.msix
  package-msi.ps1      # WiX  → CodexBar-<ver>-<arch>.msi   (fallback)
  package-cli-zip.ps1  # zip codexbar.exe + runtime  → CLI tarball equivalent
  make-appinstaller.ps1 / make-winsparkle-appcast.ps1
```

Mirror the macOS `RELEASING.md` flow: bump version → build → sign → package →
publish feed → upload to GitHub Releases. Document it in a new
`docs/RELEASING-windows.md`.

## 7. Distribution surface

- **GitHub Releases**: add Windows assets next to the macOS/Linux ones:
  `CodexBar-<ver>-win-x64.msix`, `-arm64.msix`, `CodexBarCLI-<ver>-win-x64.zip`,
  `-arm64.zip`.
- **winget**: submit manifests to `microsoft/winget-pkgs`.
- **README**: replace the "Looking for a Windows version? → Win‑CodexBar" pointer
  with the first‑party Windows download + note the relationship.

## 8. Effort

| Item | Effort |
|---|---|
| Bundle Swift runtime DLLs reliably | M |
| MSIX packaging + Startup Task | M |
| Authenticode/MSIX signing setup | M (mostly procurement) |
| Auto‑update (app‑installer or WinSparkle) | M |
| MSI/WiX fallback | M (optional) |
| CLI portable zip | S |
| Release scripts (PowerShell) + docs | M |
| winget submission | S |
