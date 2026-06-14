# 00 — Overview, Goals & Scope

## 1. What CodexBar is today

CodexBar is a macOS 14+ **menu‑bar app** that keeps AI coding‑provider usage
limits visible: per‑provider session/weekly/monthly windows, reset countdowns,
credit balances, spend dashboards, and provider status. It supports **49 provider
families** (Codex, OpenAI, Claude, Cursor, Gemini, Copilot, Bedrock, …) and ships
a bundled `codexbar` CLI for scripts/CI (macOS + Linux).

Tech stack today:

- **Language:** Swift 6.2 (strict concurrency), SwiftPM build.
- **UI:** AppKit (`NSStatusBar`/`NSMenu`), SwiftUI (settings, cards, charts),
  WidgetKit (widgets).
- **Engine:** `CodexBarCore` — networking, parsing, OAuth/device‑flow, browser
  cookie import, local file/SQLite probes, subprocess/PTY CLI runners.
- **macOS‑only dependencies:** Sparkle (updates), KeyboardShortcuts (hotkeys),
  Vortex (confetti), SweetCookieKit (browser cookie extraction), plus Apple
  frameworks (Security, WebKit, ServiceManagement, LocalAuthentication).

## 2. Goal

> **Produce a Windows‑native build of CodexBar that a Windows 10/11 user can
> install and run, presenting AI provider usage in the Windows system tray, while
> reusing the existing Swift provider engine as much as possible.**

## 3. Success criteria (definition of done for the overall effort)

A Windows release is "done" when:

1. **Engine parity (CLI):** `codexbar.exe` builds from the existing Swift sources
   and runs `usage`, `cost`, `config`, and `serve` on Windows 10/11 (x64 +
   ARM64), with the **same JSON output contract** as macOS/Linux for all
   providers whose auth model is reachable on Windows.
2. **Credentials:** API keys, OAuth/device‑flow tokens, and cached cookies are
   stored securely using **Windows Credential Manager / DPAPI** (functional
   equivalent of the macOS Keychain paths).
3. **Browser cookies:** Cookie‑based providers work against **Chrome/Edge/Brave**
   on Windows (DPAPI/App‑Bound decryption), matching the macOS browser set as
   closely as the platform allows.
4. **Tray app:** A Windows tray application shows per‑provider meters, a
   popover/flyout with provider cards + reset countdowns, a settings window
   (provider toggles, refresh cadence, display options), and quota/login
   notifications — feature‑comparable to the macOS menu.
5. **Distribution:** A signed installer (MSIX primary, MSI fallback) with
   working **auto‑update** and **launch‑at‑login**.
6. **CI:** GitHub Actions builds and tests the engine on a **Windows runner** on
   every PR; the installer is produced on tagged releases.

A provider is considered **"Windows‑supported"** when its auth source exists on
Windows (API key, OAuth/device flow, browser cookies, local config/SQLite, or a
provider CLI present on `PATH`). Providers that depend on a macOS‑only source are
explicitly listed as **deferred/unsupported** (see `06`).

## 4. Scope

### In scope
- Porting `CodexBarCore` + `CodexBarCLI` to compile and run on Windows.
- Windows implementations of the platform shims: credential store, cookie
  decryption, subprocess/PTY, file paths, offscreen WebView.
- A native Windows tray UI shell with settings, popover, charts, notifications.
- Replacing macOS‑only dependencies with Windows equivalents.
- Windows packaging, signing, auto‑update, autostart.
- Windows CI for the engine (and, if feasible, UI smoke tests).

### Out of scope (v1)
- **WidgetKit widgets** — no direct Windows equivalent. Optional later
  (Windows 11 widgets board or live tiles); tracked in `10`.
- **macOS‑specific provider sources** that have no Windows analogue (e.g.
  Safari cookies, macOS‑only app data locations). These degrade gracefully.
- **Re‑architecting provider logic.** The port must not fork provider behavior;
  changes are limited to platform shims and additive `#if os(Windows)` branches.
- **Dropping macOS support.** The macOS app remains the reference; Windows is an
  additional platform sharing the engine. No regressions to macOS/Linux.

### Explicit non‑goals
- Not a rewrite in a new language/framework (Electron/Tauri/Flutter). See `02`
  for why, and how this differs from the existing `Win‑CodexBar` fork.
- Not byte‑for‑byte UI parity with macOS. The Windows UI should be *native and
  idiomatic*, not a pixel clone of the AppKit menu.

## 5. Guiding principles

1. **Maximize reuse.** Every line of provider logic that runs on Linux today
   should run on Windows. Treat the engine as the crown jewels.
2. **Additive, not invasive.** Prefer new `#if os(Windows)` branches and new
   files over edits that risk macOS/Linux behavior. Mirror the existing
   `#if canImport(Darwin) … #else …` and `#if os(macOS) … #else …` patterns.
3. **One source of truth for data.** The Windows UI consumes the same engine
   output (ideally via `codexbar serve` / shared library) so provider behavior
   never diverges across OSes.
4. **Degrade gracefully.** A provider whose source is unavailable on Windows
   shows a clear "unsupported on Windows" state, never a crash.
5. **Keep CI honest.** Land a Windows build job early so portability regressions
   are caught continuously, exactly as Linux is today.

## 6. Glossary

| Term | Meaning |
|---|---|
| **Engine** | `CodexBarCore` + `CodexBarCLI` — the portable provider/fetch/parse code. |
| **Shell** | The OS‑specific UI app that renders engine data (macOS menu‑bar app today; new Windows tray app). |
| **Provider** | One AI service integration (49 today), living under `Sources/CodexBarCore/Providers/`. |
| **Source** | How a provider authenticates/reads data: API key, OAuth, device flow, browser cookies, local file/SQLite, or a provider CLI. |
| **`serve`** | `codexbar serve` — a local HTTP/JSON server (`/health`, `/usage`, `/cost`) the shell can poll. |
| **DPAPI** | Windows Data Protection API — user‑scoped encryption used by Credential Manager and Chromium cookie storage. |
| **ConPTY** | Windows pseudo‑console API (`CreatePseudoConsole`) — the Windows analogue of `forkpty`. |
| **WebView2** | Microsoft Edge (Chromium) embedded browser control for Windows. |
| **MSIX** | Modern Windows app package format (sandboxed install, clean uninstall, store/sideload). |
