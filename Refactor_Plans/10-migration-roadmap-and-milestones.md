# 10 — Migration Roadmap & Milestones

A phased plan that sequences the workstreams from `03`–`09` to reduce risk and
deliver value early. Effort is expressed in **bands** (S ≈ days, M ≈ 1–2 weeks,
L ≈ 3–6 weeks, XL ≈ multi‑month), not commitments. The bands assume ~1–2
engineers; the engine work and the shell work can parallelize once Phase 1 lands.

## Guiding sequencing principle

> **Prove the engine on Windows before building the UI.** Each phase ends in a
> demonstrable artifact. API‑key providers validate the cred store before cookies;
> cookies before the heavy UI; PTY/Claude‑CLI is sequenced last because it's the
> riskiest shim and has fallbacks.

---

## Phase 0 — Toolchain bring‑up & decision  · band: M
**Goal:** the engine compiles on Windows and the architecture is chosen.
- Install Swift 6.2 + VS C++ toolchain; resolve the dependency graph with
  SweetCookieKit excluded/gated (`03`).
- Get `CodexBarCore` + `CodexBarCLI` to **compile** on Windows with shims stubbed
  to no‑op (cred store returns missing, cookies empty, PTY unimplemented).
- Stand up the **Windows CI engine build job** (`09 §3.1`).
- **Make the architecture call (OD‑1):** confirm Option B (WinUI/C#) vs Option A
  (swift‑winrt). Engine work is identical either way, so this can finalize during
  the phase.

**Exit:** `swift build` produces `codexbar.exe` on Windows CI; `codexbar --help`
runs; decision recorded.

---

## Phase 1 — Engine MVP: API‑key providers + `serve`  · band: L
**Goal:** real data from Windows for the easy providers.
- Fix the `canImport(Darwin)` ladders; autorelease/logging/crypto shims (`04 §1,6`).
- Filesystem/path centralization (`04 §3`); `PATH`/`PATHEXT` exec resolution.
- `SubprocessRunner` Job‑Object process‑tree kill (`04 §2.2`).
- SQLite relink (`04 §5`).
- **`SecretStore` protocol + Windows Credential Manager/DPAPI backend** (`05 §1`).
- `serve` sidecar hardening (ephemeral port + auth token) (`04 §9`).
- Validate end‑to‑end: `codexbar usage --provider <api-key provider>` and
  `serve /usage` return correct JSON on Windows for several API‑key providers
  (e.g. ElevenLabs, OpenRouter, DeepSeek, z.ai, Doubao, Venice, Crof).

**Exit:** API‑key providers fully functional via CLI + `serve` on Windows, with
credentials persisted securely. Windows CI runs the portable test suite green.

---

## Phase 2 — Windows shell MVP (tray + flyout + settings)  · band: L→XL
**Goal:** a usable tray app for the providers Phase 1 enabled. *Parallelizable
with Phase 3.*
- Sidecar manager + HTTP client + DTOs + CLI action runner (`07 §3`).
- Tray icon + dynamic meter renderer (`07 §4`).
- Flyout with provider cards, usage bars, reset countdowns (`07 §1`).
- Settings: Providers (enable/disable, set API key), Display, Refresh cadence,
  Advanced, About (`07 §1`).
- Toast notifications (quota/login) (`07 §6`).
- Autostart + global hotkey + quit (`06`, `08 §5`).
- Define & freeze the **engine contract** doc + generate C# DTOs (`07 §3.4`).

**Exit:** install‑less dev run of the shell shows live usage for API‑key providers,
toggling/keys work, settings persist via `config.json`, autostart works.

---

## Phase 3 — Cookie & OAuth providers  · band: L→XL
**Goal:** unlock the large cookie/OAuth provider set. *Parallelizable with Phase 2.*
- `CookieBackend` protocol + move SweetCookieKit behind it (macOS unchanged)
  (`05 §3.3`).
- **Windows Chromium cookie decryptor** (v10/v11; Chrome/Edge/Brave/Vivaldi/Opera)
  + Firefox plaintext (`05 §3.3`).
- `BrowserDetection` for Windows profile discovery (`05 §3.4`).
- **App‑Bound Encryption** handling/decision + manual‑cookie fallback UI (`05 §3.3`,
  OD‑3).
- Per‑provider OAuth source audit on Windows (file vs store) + WebView2 OAuth/
  device‑flow host in the shell (`05 §1.5`, `07 §3.3`).

**Exit:** cookie‑based providers (Cursor, Grok, MiniMax, Manus, T3 Chat, Abacus,
Amp, Perplexity, Command Code, Alibaba, Ollama, Factory, Devin, …) and OAuth
providers (Codex, Gemini, VertexAI, Bedrock, Copilot) work on Windows, with manual‑
cookie fallback where ABE blocks.

---

## Phase 4 — Charts, dashboards & polish  · band: L
**Goal:** feature‑complete UI.
- History/spend charts for API providers + cost scans (`07 §1`, `06`).
- OpenAI dashboard extras: WebView2 scraper in the shell, or keep deferred
  (`04 §8`).
- Merge‑Icons mode + provider switcher; display options parity; theming/DPI/
  localization (`07 §2,7`).
- Optional weekly‑reset celebration effect (Vortex replacement) — lowest priority.

**Exit:** UI is at parity with the macOS menu for all Windows‑supported providers.

---

## Phase 5 — Claude CLI / PTY (ConPTY)  · band: L · risk: high
**Goal:** Claude's CLI/PTY fallback on Windows.
- `WindowsPTY` via ConPTY; map `TTYCommandRunner` onto it (`04 §2.4`).
- Port/replace `CodexBarClaudeWatchdog`/`CodexBarClaudeWebProbe` as needed.

**Note:** sequenced last because Claude also works via OAuth/cookies; if ConPTY
slips, v1 ships Claude via those sources and PTY follows. Could be pulled earlier
if Claude‑CLI users are a priority.

**Exit:** `codexbar usage --provider claude` via CLI/PTY works on Windows.

---

## Phase 6 — Packaging, signing, auto‑update, release  · band: L
**Goal:** shippable product. *Start signing/cert procurement early — it has lead time.*
- Bundle Swift runtime DLLs; self‑contained .NET publish; WebView2 bootstrapper
  (`08 §1`).
- MSIX (primary) + Startup Task; MSI/WiX fallback if needed (`08 §2`).
- Authenticode/MSIX signing (or Azure Trusted Signing) (`08 §3`).
- Auto‑update feed (app‑installer or WinSparkle) (`08 §4`).
- PowerShell release pipeline + `docs/RELEASING-windows.md`; GitHub Releases +
  winget; CLI portable zip (`08 §6,7`).
- Windows release CI job (`09 §3.4`).

**Exit:** signed installer with working auto‑update on GitHub Releases + winget;
`winget install CodexBar` works.

---

## Phase 7 — Stretch / post‑v1  · band: varies
- WidgetKit replacement (Windows 11 widgets board / live tiles).
- Windows Hello gating for the cred store (`06`).
- ARM64 parity hardening.
- Confetti/particle polish.

---

## Critical path & parallelism

```
Phase 0 ─▶ Phase 1 ─┬─▶ Phase 2 (shell) ─────────────┐
                    └─▶ Phase 3 (cookies/OAuth) ──────┤─▶ Phase 4 ─▶ Phase 6 ─▶ ship
                                          Phase 5 (PTY)┘   (can land in or after P4)
```
- **Phase 1 is the gate** for everything (it proves the engine + cred store).
- **Phases 2 and 3 parallelize** (UI vs engine‑shims) with two workstreams.
- **Phase 5 (PTY)** is independent and deferrable.
- **Phase 6 procurement (signing cert)** should start during Phase 1–2.

## Rough total

A first shippable Windows v1 (API‑key + cookie + OAuth providers, polished tray UI,
signed auto‑updating installer; Claude‑PTY and widgets deferred) is an
**L→XL overall effort** — on the order of a few engineer‑months with focused
work, dominated by the shell (Phase 2/4), the two big engine shims (cred store +
cookies), and packaging. The engine MVP (Phase 0–1) is reachable much sooner and
is the right early proof point.

## Milestone acceptance gates (summary)

| Milestone | Gate |
|---|---|
| M0 | Engine compiles on Windows CI; arch decided |
| M1 | API‑key providers via CLI + `serve`; cred store works |
| M2 | Tray UI MVP shows live usage; settings persist |
| M3 | Cookie + OAuth providers work on Windows |
| M4 | UI parity (charts, merge‑icons, display options) |
| M5 | Claude PTY via ConPTY (optional for v1) |
| M6 | Signed, auto‑updating installer shipped |
