# 02 — Target Architecture & Stack Decision

This document chooses the Windows tech stack. It is the **load‑bearing decision**:
everything in `03`–`10` follows from it.

## 1. The fundamental split

CodexBar already separates **Engine** (portable Swift) from **Shell** (OS UI).
The port keeps that split and adds a Windows shell:

```
                ┌─────────────────────────────────────────────┐
                │            Provider Engine (Swift)           │
                │  CodexBarCore (49 providers, fetch/parse,    │
                │  OAuth/device-flow, cookies, status, cost)   │
                │  + CodexBarCLI (codexbar.exe, `serve`)       │
                │  ── builds on macOS / Linux / WINDOWS ──     │
                └───────────────▲──────────────▲──────────────┘
                                │              │
              in-process (FFI)  │              │  localhost HTTP/JSON
              or shared library │              │  (`codexbar serve`)
                                │              │
                ┌───────────────┴───┐   ┌──────┴───────────────┐
                │  macOS Shell      │   │   Windows Shell (NEW) │
                │ AppKit + SwiftUI  │   │  tray + flyout +      │
                │ (unchanged)       │   │  settings + charts    │
                └───────────────────┘   └──────────────────────┘
```

The only real question is **what the Windows shell is built with, and how it
talks to the engine.**

## 2. Options considered

### Option A — Pure Swift everywhere (engine + shell in Swift)
Build the shell in Swift on Windows using **swift‑winrt → WinUI 3 / Windows App
SDK** (the approach The Browser Company used to ship Swift apps on Windows), or
**SwiftCrossUI** (a SwiftUI‑like cross‑platform framework with a WinUI backend).

- ✅ One language; engine linked in‑process (no IPC); maximal conceptual reuse;
  the existing SwiftUI view *models* (`MenuDescriptor`, `ProvidersPane`, etc.)
  can inform the port.
- ✅ Single binary; no .NET runtime to ship.
- ❌ Swift‑on‑Windows **GUI** tooling is young: swift‑winrt is powerful but
  low‑level and sparsely documented; SwiftCrossUI is promising but not yet proven
  for a 294‑file‑equivalent app with tray, charts, WebView2, notifications.
- ❌ Highest execution risk for the *UI* workstream.

### Option B — Swift engine + native WinUI 3 shell in C#/.NET  ⭐ recommended
Compile the engine to `codexbar.exe`; build the shell in **C#/.NET 8 + WinUI 3
(Windows App SDK)** (or WPF). The shell consumes the engine via the **existing
`codexbar serve`** JSON contract and direct CLI invocations for actions.

- ✅ Best‑in‑class, battle‑tested Windows UI tooling (tray, flyouts, MVVM,
  WinUI charts, WebView2, toast notifications, MSIX) with deep docs.
- ✅ Reuses **100% of the engine** with zero provider‑logic rewrite; the
  `serve`/CLI seam is *already shipped and proven* by Linux integrations.
- ✅ Clean process isolation: an engine crash can't take down the tray, and the
  UI and engine version independently.
- ✅ Fastest path to a polished, idiomatic Windows app.
- ❌ Two languages in the repo; an IPC boundary (localhost HTTP + CLI) to define
  and version.
- ❌ Must ship the Swift runtime DLLs **and** the .NET runtime (or self‑contained
  .NET). Larger installer.

### Option C — Full rewrite in a cross‑platform UI stack
Reimplement the UI (and possibly logic) in **Tauri/Electron (TS)**, **.NET MAUI**,
or **Flutter**.

- ✅ Potential single UI codebase across OSes.
- ❌ Discards the 95K‑LOC Swift engine or forces a parallel reimplementation —
  enormous effort and permanent divergence risk.
- ❌ The existing third‑party **Win‑CodexBar** already occupies the "separate
  reimplementation" niche; duplicating that defeats the purpose of *porting*.
- ❌ Worst reuse of existing investment.

## 3. Decision matrix

Weighted 1–5 (5 = best). Weights reflect that engine reuse and UI delivery risk
dominate this project.

| Criterion (weight) | A: Pure Swift | B: Swift engine + WinUI/C# | C: Rewrite |
|---|:--:|:--:|:--:|
| Engine reuse (×5) | 5 | 5 | 1 |
| UI delivery risk / tooling maturity (×5) | 2 | 5 | 4 |
| Time‑to‑first‑usable‑build (×4) | 2 | 4 | 2 |
| Long‑term maintenance / one team (×3) | 4 | 3 | 3 |
| Native Windows look & feel (×3) | 3 | 5 | 4 |
| Installer size / footprint (×2) | 5 | 3 | 2 |
| Avoids logic divergence across OSes (×4) | 5 | 5 | 1 |
| **Weighted total** | **80** | **108** | **57** |

> Scoring is indicative, to make the trade‑offs explicit — not a precise metric.
> The gap between **B** and the others is robust to reasonable re‑weighting.

## 4. Recommendation

**Adopt Option B: reuse the Swift engine unchanged, and build a native Windows
shell in C#/.NET + WinUI 3 that consumes the engine via `codexbar serve` and the
CLI.**

Rationale:
- The engine is the irreplaceable asset and already runs cross‑platform; B reuses
  it with **zero provider rewrites**.
- The `serve` JSON seam is **already built and proven** in production by Linux
  integrations — we're not inventing the contract, just adding a first‑party
  consumer.
- WinUI 3 + C# is the lowest‑risk way to deliver a polished tray app on Windows
  (tray, toasts, WebView2, charts, MSIX all first‑class).
- Process isolation makes the product more robust than the in‑process macOS model.

**Keep Option A (swift‑winrt) on the table as the "single‑language" alternative**
for a team that strongly prefers no second language and is willing to absorb GUI
tooling risk; the engine work in `03`–`05` is *identical* either way, so the
architecture call can even be deferred until after the engine builds on Windows.

> This is the one genuinely consequential, reversible‑only‑at‑cost decision in the
> plan. It is recorded as **OD‑1** in `11-risks-and-open-decisions.md` for explicit
> maintainer sign‑off. The recommended default (B) lets all engine work start
> immediately regardless.

## 5. Recommended architecture (Option B), in detail

### 5.1 Components
- **`codexbar.exe`** — the existing CLI, built for Windows. Two roles:
  1. **Sidecar server:** the shell launches `codexbar serve --port <ephemeral>`
     as a child process at startup and polls `/usage` / `/cost` / `/health`.
  2. **Action runner:** the shell invokes `codexbar config …`, `codexbar
     login …`, etc. for one‑shot actions (enable/disable provider, set API key).
- **`CodexBar.Shell` (C#/.NET 8, WinUI 3)** — the tray app:
  - System‑tray icon with dynamic usage meter (GDI/Direct2D or pre‑rendered).
  - Flyout/popover window: provider cards, usage bars, reset countdowns.
  - Settings window: provider toggles, refresh cadence, display options, advanced.
  - Toast notifications for quota/login events.
  - Embedded **WebView2** for OAuth/device‑flow sign‑in and OpenAI dashboard.
- **Platform shims inside the engine** (Swift, `#if os(Windows)`): credential
  store, cookie decryption, subprocess/PTY (see `04`/`05`).

### 5.2 Data flow
```
tray launch ─▶ spawn `codexbar serve` (sidecar) ─▶ poll /usage every N s
   │                                                     │
   └── user action (toggle, set key, login) ─────────────┘
                 │
                 ▼  run `codexbar config …` / OAuth via WebView2
        write ~/.codexbar/config.json + credentials (DPAPI)
                 │
                 ▼  serve re-reads config (config cache token) → fresh /usage
```
The shell holds **no provider logic** — it renders engine JSON and triggers engine
actions. This guarantees macOS/Windows parity.

### 5.3 Why the sidecar (not FFI) for B
Calling Swift from C# via P/Invoke is possible but adds a brittle C ABI surface
across 49 providers' async APIs. The `serve` HTTP seam already exists, is
typed/tested, handles caching and timeouts, and decouples crashes. Use it. (If
latency ever matters, the same engine can later expose a C‑ABI shared library;
the UI contract wouldn't change much because it's already JSON‑shaped.)

### 5.4 Security of the sidecar
- Bind `127.0.0.1` only (already the default), on an **ephemeral port** chosen by
  the shell, not the fixed 8080.
- Add a per‑launch shared secret (header/token) the shell passes and `serve`
  requires — small enhancement to `serve` (tracked in `04`/`11`).
- The sidecar runs as the same user; no elevation.

## 6. Repository shape (recommended)

Keep one repo, add Windows alongside macOS/Linux:

```
/Package.swift                 # engine + CLI build everywhere; macOS execs gated
/Sources/CodexBarCore/...      # + #if os(Windows) shims (new files)
/Sources/CodexBarCLI/...       # unchanged (+ optional serve auth)
/Sources/CodexBarPlatformWindows/   # NEW: Swift Windows shims (cred store, cookies, PTY)  [optional grouping]
/windows/                      # NEW
  CodexBar.Shell/              #   C#/.NET WinUI 3 app
  CodexBar.Setup/              #   MSIX/MSI packaging project
  build/                       #   PowerShell build scripts
/Refactor_Plans/               # this folder
```

The Windows shims can live inside `CodexBarCore` behind `#if os(Windows)` (matches
existing style) or be grouped in a dedicated `CodexBarPlatformWindows` target that
Core depends on conditionally. Prefer **in‑Core `#if os(Windows)` branches** to
mirror the existing Linux handling and avoid a new dependency edge — see `04 §6`.

## 7. What carries over from the macOS shell (as a spec, not code)

The macOS app can't be compiled on Windows, but its **state models** are the
functional spec for the C# shell. Mine these for behavior:
- `UsageStore` (refresh cadence, fetch orchestration, merge‑icons logic).
- `MenuDescriptor`, `ProvidersPane`, `CodexAccountsSectionState` (menu/settings
  state that AGENTS.md already treats as the stable, testable seams).
- Icon rendering rules (`docs/ui.md`, `docs/icon.md`).
- Notification logic (`QuotaWarningNotificationLogic`, `LoginNotificationLogic`
  tests encode the rules — port them as C# unit tests).

## 8. Summary

| Decision | Choice |
|---|---|
| Engine | **Reuse** `CodexBarCore` + `CodexBarCLI`, build for Windows |
| Engine ↔ UI seam | **`codexbar serve`** (localhost JSON) + CLI for actions |
| Windows UI | **WinUI 3 / Windows App SDK in C#/.NET 8** (Option B) |
| Single‑language alternative | swift‑winrt shell (Option A) — same engine work |
| Rejected | Full rewrite (Option C) |
| Repo | Single repo; add `/windows/` + `#if os(Windows)` engine shims |
