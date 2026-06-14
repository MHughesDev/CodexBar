# 07 — Windows UI Shell

Spec for the new Windows tray application that replaces `Sources/CodexBar` (the
macOS AppKit + SwiftUI menu‑bar app). Assumes **Option B** (C#/.NET 8 + WinUI 3 /
Windows App SDK); §9 notes the swift‑winrt (Option A) variation. The shell renders
engine data and triggers engine actions — it contains **no provider logic**.

## 1. Feature parity checklist (from the macOS app)

The Windows shell should match these user‑visible behaviors (source of truth:
macOS `UsageStore`, `MenuDescriptor`, `ProvidersPane`, `docs/ui.md`,
`docs/refresh-loop.md`):

- [ ] **Tray icon** with a dynamic usage meter; dim/indicator for stale/error/
      incident states.
- [ ] **Per‑provider status items** *or* **Merge‑Icons mode** (one tray icon + a
      provider switcher).
- [ ] **Flyout/popover**: provider cards with usage bars, reset countdowns,
      credits/spend, incident badges.
- [ ] **Settings window**: Providers (enable/disable, API keys, source choice),
      Display (icons/labels/bars/reset style/highest‑usage), Refresh cadence
      (manual/1m/2m/5m/15m), Advanced (disable cred store, diagnostics), About
      (version, update channel).
- [ ] **Notifications**: session quota warnings, login‑needed alerts.
- [ ] **Charts**: spend/usage history for API providers (OpenAI, Claude Admin,
      OpenRouter, z.ai, MiniMax, Mistral, Bedrock) + cost scans (Codex/Claude).
- [ ] **OAuth / device‑flow sign‑in** UI (where providers need it).
- [ ] **Launch at login**, **check for updates**, **quit**.
- [ ] Optional weekly‑reset celebration (Vortex confetti → optional WinUI effect).

## 2. Component → Windows mapping

| macOS concept | Windows (WinUI 3 / Win32) |
|---|---|
| `NSStatusBar` status item | Tray icon via `Shell_NotifyIcon` (`H.NotifyIcon.WinUI` package, or P/Invoke) |
| `NSMenu` popover | A borderless **WinUI window/flyout** anchored to the tray, dismiss‑on‑deactivate |
| SwiftUI settings `Scene` | A standard **WinUI window** with a `NavigationView` (Providers/Display/Refresh/Advanced/About) |
| Dynamic bar icon (`CoreGraphics`) | Render PNG/ICO at runtime with **Win2D**/Direct2D or `System.Drawing`, set as tray icon |
| `Charts` (SwiftUI) | **LiveChartsCore** or **CommunityToolkit** charts, or WinUI `Microsoft.UI.Xaml.Controls` |
| `UserNotifications` | **App notifications / toasts** (`CommunityToolkit.WinUI.Notifications` / `AppNotificationManager`) |
| `KeyboardShortcuts` | `RegisterHotKey` (global) |
| `WKWebView` (OAuth, OpenAI dashboard) | **WebView2** control |
| Vortex confetti overlay | Optional WinUI Composition particle effect (defer) |
| Login item (`ServiceManagement`) | Startup registry key or MSIX **Startup Task** |

## 3. Talking to the engine

### 3.1 Sidecar lifecycle
- On launch, the shell starts `codexbar.exe serve --port 0 --auth-token <random>`
  as a **child process** (job‑object‑bound so it dies with the shell), reads the
  chosen port from stdout, and stores the token.
- Poll `GET /usage` on the user's refresh cadence; `GET /cost` on demand;
  `GET /health` for liveness/restart.
- Parse JSON into view models. **The JSON shape is the same as the CLI/macOS** —
  reuse the field names from `CLIPayloads`/`output.payload`.

### 3.2 Actions (one‑shot CLI calls)
- Enable/disable provider → `codexbar config enable|disable --provider <id>`.
- Set API key → pipe to `codexbar config set-api-key --provider <id> --stdin`.
- List providers/config → `codexbar config providers`.
- These write `~/.codexbar/config.json`; `serve` notices via its config cache
  token and serves fresh data on the next poll.

### 3.3 OAuth / device flow
- Providers needing browser auth: host **WebView2**, drive the provider's OAuth
  page, capture the redirect/token, and hand it to the engine (CLI subcommand or
  config write). For device flow, show the code + verification URL and poll.
- Cookie‑based providers: the engine's Windows `CookieBackend` reads browser
  cookies directly (`05`); the shell only needs to surface "which browser" and a
  "paste cookie manually" fallback.

### 3.4 Contract definition (action item)
Write a short **`engine-contract.md`** (JSON schemas for `/usage`, `/cost`,
`/health`, and the `config` CLI verbs) so the shell and engine teams share one
spec. Generate C# DTOs from it. (Tracked in `10`.)

## 4. Tray icon rendering

The dynamic meter is core to CodexBar's identity. Plan:
- Port the icon *rules* from `docs/icon.md`/`docs/ui.md` (bar fill = usage,
  dim = stale/error, overlay = incident).
- Render at the current DPI to an `Icon`/`HICON` (Direct2D/Win2D), update on each
  refresh. Cache by a signature (mirror the existing
  `StatusItemIconObservationSignature` idea) to avoid needless redraws.
- Support light/dark taskbar themes (Windows accent/theme APIs).

## 5. Settings persistence

All settings already persist in `~/.codexbar/config.json` via the engine. The
shell should treat that file (through the `config` CLI) as the **single source of
truth**, not keep a parallel settings store, so CLI and UI stay consistent (the
macOS app and CLI already share this file).

## 6. Notifications

- Quota warnings + login alerts: port the decision logic encoded in
  `QuotaWarningNotificationLogic`/`LoginNotificationLogic` (and their tests) into
  the shell as C# (or, better, have the engine emit a "should notify" signal in
  the `/usage` payload so the rule lives once in Swift). Prefer the latter to
  avoid logic divergence.
- Use Windows toasts; clicking a toast opens the relevant provider card.

## 7. Accessibility & localization

- The app is localized (`defaultLocalization: "en"`, `LocalizationBundleTests`,
  catalogs). Decide whether to reuse the engine's localization (expose strings via
  the engine) or maintain shell `.resw` resources. Recommend **engine‑sourced
  strings** for provider‑facing text, shell resources for chrome.
- WinUI gives accessibility (UIA) largely for free; ensure tray/flyout are
  keyboard‑navigable.

## 8. Shell module layout (suggested)

```
windows/CodexBar.Shell/
  App.xaml(.cs)                 # app lifetime, single-instance
  Tray/                         # NotifyIcon, dynamic icon renderer
  Flyout/                       # popover window + provider cards
  Settings/                     # NavigationView panes
  Engine/                       # sidecar manager, HTTP client, CLI runner, DTOs
  Auth/                         # WebView2 OAuth/device-flow host
  Notifications/                # toast helpers
  Charts/                       # history charts
  Resources/                    # icons, .resw, themes
```

## 9. Option A (pure Swift) variation

If the swift‑winrt path is chosen instead:
- The "Engine/" layer becomes **in‑process** (link `CodexBarCore` directly; no
  sidecar/HTTP) — call the same fetchers the CLI calls.
- UI is built with **WinUI 3 via swift‑winrt** projections (tray via Win32 interop
  for `Shell_NotifyIcon`, WebView2 via its WinRT API).
- Charts/notifications/hotkeys use the same WinRT/Win32 APIs from Swift.
- Everything in §1–§7 still applies; only the language and the engine binding
  differ. **Higher UI risk, one language.** (See `02`.)

## 10. Effort

| Area | Effort |
|---|---|
| Tray + dynamic icon | M |
| Flyout + provider cards | L |
| Settings window (all panes) | L |
| Engine client (sidecar + CLI + DTOs) | M |
| OAuth/device‑flow WebView2 | M |
| Charts | M |
| Notifications | S–M |
| Autostart/hotkeys/quit/about | S |
| Theming/DPI/localization | M |

The shell is the **largest net‑new build** in the project; budget accordingly
(`10`). Mitigate by shipping a minimal tray+flyout+settings v1 and layering charts/
OAuth polish afterward.
