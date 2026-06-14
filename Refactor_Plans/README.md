# CodexBar → Windows: Refactor Plans

> Planning documentation for porting **CodexBar** (a Swift 6 / macOS 14+ menu‑bar
> app) to a **Windows‑runnable tech stack**.

This folder contains the full plan set. It is **documentation only** — no source
code in this project has been changed. Each document is self‑contained but they
are meant to be read in order.

## Why this is achievable (the one‑paragraph version)

CodexBar is already split into a **portable engine** and a **macOS UI**. The
engine — `CodexBarCore` (~95K LOC, 49 providers) and `CodexBarCLI` — already
compiles and ships on **Linux**, and already exposes a local HTTP/JSON server via
`codexbar serve` (the same seam the Linux Waybar/GNOME/SketchyBar integrations
consume). Roughly **all macOS‑specific code is the UI layer** (`Sources/CodexBar`:
AppKit menu bar + SwiftUI + WidgetKit) plus a handful of thin platform shims
(Keychain, browser‑cookie decryption, PTY, an offscreen WebView). The port is
therefore: **(1) make the engine build on Windows, (2) replace the platform
shims, (3) build a native Windows tray UI on top of the engine.** It is a large
but well‑bounded effort — not a rewrite.

## Recommended target stack (at a glance)

| Layer | macOS today | Windows target (recommended) |
|---|---|---|
| Provider engine | `CodexBarCore` (Swift) | **Same Swift code**, built with the Swift‑for‑Windows toolchain |
| CLI / local server | `CodexBarCLI` + `codexbar serve` | **Same Swift code** → `codexbar.exe` |
| Credentials store | Keychain / Security.framework | **Windows Credential Manager + DPAPI** |
| Browser cookies | SweetCookieKit (Keychain‑backed) | **DPAPI v10 / App‑Bound** cookie decryptor |
| Subprocess / PTY | `Process` + POSIX signals / `forkpty` | `Process` + **Job Objects** / **ConPTY** |
| Embedded browser | WKWebView (OpenAI dashboard) | **WebView2** |
| Tray + popover + settings UI | AppKit `NSStatusBar` + SwiftUI | **WinUI 3 / Windows App SDK shell** consuming the engine |
| Auto‑update | Sparkle | **WinSparkle / MSIX app installer / winget** |
| Global hotkeys | KeyboardShortcuts | **`RegisterHotKey`** |
| Packaging | `.app` + notarization | **MSIX (primary) / MSI**, Authenticode signed |
| Widgets | WidgetKit | Out of scope for v1 (see roadmap) |

The single most consequential decision — **what language/framework the Windows
UI shell is written in** — is analysed in
[`02-target-architecture-and-stack-decision.md`](02-target-architecture-and-stack-decision.md).
The default recommendation is a **native WinUI 3 shell (C#/.NET) over the Swift
engine via `codexbar serve`**, with a **pure‑Swift (swift‑winrt) shell** as the
single‑language alternative.

## Document index

| # | Document | What it covers |
|---|---|---|
| — | [`README.md`](README.md) | This index + executive summary |
| 00 | [`00-overview-goals-and-scope.md`](00-overview-goals-and-scope.md) | Goals, success criteria, scope, non‑goals, glossary |
| 01 | [`01-current-architecture-audit.md`](01-current-architecture-audit.md) | Hard numbers: module map, platform‑coupling inventory, what's already portable |
| 02 | [`02-target-architecture-and-stack-decision.md`](02-target-architecture-and-stack-decision.md) | The stack options, decision matrix, recommended architecture + diagram |
| 03 | [`03-toolchain-and-build-system.md`](03-toolchain-and-build-system.md) | Swift on Windows toolchain, SwiftPM/`Package.swift` changes, local build |
| 04 | [`04-core-engine-port.md`](04-core-engine-port.md) | Making `CodexBarCore`/CLI compile & run on Windows (process, PTY, paths, syscalls, crypto, SQLite, networking) |
| 05 | [`05-security-credentials-and-cookies.md`](05-security-credentials-and-cookies.md) | Keychain→Credential Manager/DPAPI, SweetCookieKit→Windows cookie decryptor |
| 06 | [`06-dependency-replacement-matrix.md`](06-dependency-replacement-matrix.md) | Every external dependency: keep / replace / drop, with Windows equivalents |
| 07 | [`07-windows-ui-shell.md`](07-windows-ui-shell.md) | The Windows tray UI: tray icon, flyout/popover, settings, charts, icon rendering, notifications |
| 08 | [`08-packaging-distribution-and-updates.md`](08-packaging-distribution-and-updates.md) | MSIX/MSI, Authenticode signing, auto‑update, autostart, winget |
| 09 | [`09-testing-and-ci-cd.md`](09-testing-and-ci-cd.md) | Windows test strategy, GitHub Actions Windows runners, sharding |
| 10 | [`10-migration-roadmap-and-milestones.md`](10-migration-roadmap-and-milestones.md) | Phased plan, milestones, effort bands, sequencing, exit criteria |
| 11 | [`11-risks-and-open-decisions.md`](11-risks-and-open-decisions.md) | Risk register + decisions that need a maintainer's call |

## How to use these plans

1. Read **00** and **01** to align on scope and to see how much is already done.
2. Make the architecture call in **02** (this unblocks everything else).
3. Use **03–08** as the implementation specs for each workstream.
4. Track delivery against **10**; revisit **11** at every phase gate.

## Status & disclaimers

- This is a **forward‑looking plan**, not an implementation. Effort estimates are
  bands (S/M/L/XL), not commitments.
- A separate third‑party project, **Win‑CodexBar**, already exists as an
  independent Windows app. This plan deliberately takes the *opposite* approach:
  **port the real codebase** (maximize reuse of the 95K‑LOC engine) rather than
  reimplement it. See **02** for the trade‑off.
- All file paths, counts, and API references were gathered from the repository at
  the time of writing; re‑verify against `main` before starting work.
