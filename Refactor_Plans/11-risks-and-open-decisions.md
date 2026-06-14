# 11 — Risks & Open Decisions

Revisit this document at every phase gate (`10`). Risks are rated **Likelihood ×
Impact** (L/M/H). Open Decisions (OD‑n) need a maintainer's call; recommended
defaults are given so work isn't blocked.

## Part A — Open decisions (need maintainer sign‑off)

### OD‑1 · Windows UI framework  ⭐ most important
**Question:** Build the shell in **C#/.NET + WinUI 3** (Option B) consuming the
engine via `codexbar serve`, or **pure Swift via swift‑winrt** (Option A)?
- **Recommended default:** **Option B** (lowest UI risk, best Windows tooling,
  proven `serve` seam). See `02`.
- **Impact if changed later:** the engine work (Phases 0–1, `03`–`05`) is identical
  for both, so this can be deferred until after the engine builds — but it gates
  the shell hiring/skills and the repo's second‑language commitment.

### OD‑2 · Primary installer format
**Question:** MSIX or MSI as the primary GUI installer?
- **Recommended default:** **MSIX** for the GUI app **+ portable ZIP** for the
  standalone CLI. MSI/WiX as fallback if MSIX sandboxing blocks browser‑cookie
  reads (see R‑3).

### OD‑3 · Chrome App‑Bound Encryption (ABE) stance
**Question:** How far to chase Chrome's App‑Bound cookie encryption (Chrome 127+)?
- **Recommended default:** Support **v10/v11 DPAPI** decryption (covers Edge,
  Brave, older/most Chromium) + **Firefox plaintext**; for ABE‑locked Chrome
  profiles, surface the existing **manual‑cookie paste** fallback and document the
  limitation. Don't ship an elevated COM/ABE‑bypass for v1 (fragile, cat‑and‑mouse,
  potential AV flags).

### OD‑4 · Provider support tier on Windows
**Question:** Which providers are "v1‑supported" vs "deferred"?
- **Recommended default:** v1 = all API‑key, OAuth/device‑flow, file/SQLite, and
  v10/v11‑cookie providers. Deferred = Claude‑CLI/PTY (until Phase 5), any
  Safari/macOS‑only source, ABE‑locked Chrome‑only providers. Publish the matrix
  in the README.

### OD‑5 · WidgetKit replacement
**Question:** Ship any Windows widget surface?
- **Recommended default:** **No for v1.** Revisit Windows 11 widgets post‑v1
  (`10` Phase 7).

### OD‑6 · Single repo vs separate Windows repo
**Question:** Keep Windows in this repo or split it out?
- **Recommended default:** **Single repo** (one engine, shared CI, no divergence).
  The `/windows/` shell and `#if os(Windows)` engine shims live alongside macOS.

### OD‑7 · Engine binding: sidecar `serve` vs in‑process FFI
**Question:** (If Option B) HTTP sidecar or a C‑ABI shared library?
- **Recommended default:** **Sidecar `serve`** — it already exists, is tested,
  isolates crashes, and the JSON contract is provider‑agnostic. Revisit FFI only
  if polling latency becomes a real problem.

### OD‑8 · Code‑signing approach
**Question:** Physical EV cert, OV cert, or **Azure Trusted Signing**?
- **Recommended default:** **Azure Trusted Signing** if eligible (no hardware,
  CI‑friendly, good reputation); else EV for instant SmartScreen trust. Start
  procurement during Phase 1 (lead time).

## Part B — Risk register

### R‑1 · PTY → ConPTY complexity  · L×H = **High**
`TTYCommandRunner` (forkpty/signals) has no clean Windows analogue; ConPTY is
involved and the active‑process registry must be rebuilt with handles/job objects.
- **Mitigation:** sequence last (`10` Phase 5); Claude works via OAuth/cookies
  without PTY, so v1 isn't blocked. Prototype a ConPTY echo round‑trip early to
  de‑risk before committing.

### R‑2 · Browser cookie decryption fragility  · M×H = **High**
DPAPI key extraction + AES‑GCM v10/v11, profile discovery, DB locking, and ABE
churn make this brittle and version‑sensitive across browsers.
- **Mitigation:** `CookieBackend` abstraction; copy‑DB‑to‑temp to dodge locks;
  fixture‑based tests; **manual‑cookie fallback** everywhere (already supported);
  ABE stance per OD‑3; prefer Edge/Brave in defaults.

### R‑3 · MSIX sandbox blocks reading browser cookies  · M×M = **Medium**
Packaged apps may be restricted from reading other apps' `%LOCALAPPDATA%` files.
- **Mitigation:** validate cookie reads from a packaged context in Phase 0/1; if
  blocked, declare the needed capability or ship the cookie build as **MSI** (OD‑2
  fallback).

### R‑4 · Credential store semantics mismatch  · M×M = **Medium**
Credential Manager's 2.5 KB blob limit and persistence/roaming semantics differ
from Keychain; cached snapshots can be large.
- **Mitigation:** chunking or **DPAPI‑on‑disk** for large entries (`05 §1.2`);
  map lock/unavailable error codes to the existing `temporarilyUnavailable` result
  so callers behave identically.

### R‑5 · Shell is a large net‑new build  · M×H = **High (schedule)**
The macOS app is 294 files; the Windows shell is built from scratch.
- **Mitigation:** ship a **thin v1** (tray + flyout + settings) and layer charts/
  OAuth/merge‑icons later (`10` Phases 2→4); reuse macOS *state models* as the spec;
  keep all logic in the engine so the shell stays a thin renderer.

### R‑6 · Foundation API gaps on Windows  · M×M = **Medium**
swift‑foundation on Windows occasionally lags Darwin (date/locale, URL edge cases,
`Process` pipe nuances, proxy handling).
- **Mitigation:** Windows CI from day one (`09`); fix gaps with small shims; the
  Linux build already shook out many non‑Darwin issues.

### R‑7 · Macro plugin execution on Windows  · L×M = **Medium**
`CodexBarMacros` (swift‑syntax plugin) must run during the Windows build.
- **Mitigation:** validate in Phase 0; if blocked, pre‑expand or guard with
  generated sources as a temporary fallback.

### R‑8 · AppKit/WebKit leakage in Core  · L×M = **Low‑Med**
4 AppKit + 6 WebKit files in Core could pull macOS types into the Windows engine
graph or the `serve`/`usage` public surface.
- **Mitigation:** audit and gate/move them early (`04 §7,8`); add a CI assertion
  that the Windows engine links without AppKit/WebKit.

### R‑9 · Swift runtime distribution  · M×M = **Medium**
Users won't have the Swift runtime; bundling the right DLL set (and keeping it in
sync with the toolchain) is fiddly, and AV/SmartScreen may flag unsigned binaries.
- **Mitigation:** automate DLL collection in `build-engine.ps1`; sign everything
  (OD‑8); test on a clean Windows VM with no dev tools.

### R‑10 · Provider parity drift across OSes  · M×M = **Medium**
Divergent behavior if logic creeps into the shell or via `#if os(Windows)` forks.
- **Mitigation:** keep **all** provider logic in the engine; shell renders JSON
  only; share engine‑level tests on Windows + Linux + macOS; "additive, not
  invasive" principle (`00 §5`).

### R‑11 · ARM64 Windows coverage  · L×M = **Low‑Med**
ARM64 toolchain/runtime/deps may lag x64.
- **Mitigation:** ship x64 first; add ARM64 to CI matrix and treat as fast‑follow.

### R‑12 · Maintainer bandwidth / two‑platform tax  · M×M = **Medium**
A second shell + Windows release pipeline is ongoing maintenance.
- **Mitigation:** single repo + shared engine + shared contract minimize duplicate
  work; Windows CI prevents silent rot; consider community ownership of the shell
  (note the existing Win‑CodexBar community interest).

## Part C — Assumptions to validate before starting

1. The current dependency versions of `Commander`, `swift-crypto`, `swift-log`,
   and `swift-syntax` build on the Swift 6.2 Windows toolchain. *(Verify in Phase 0.)*
2. `SweetCookieKit` is the **only** Core‑level Swift dependency that won't build on
   Windows. *(Verify by resolving the graph with it gated.)*
3. `Package.swift`'s `platforms: [.macOS(.v14)]` does not block Windows builds
   *(declares Apple minimums, not an allowlist — confirm empirically).*
4. The `serve` JSON contract is stable enough to be the UI's data source for all
   target providers. *(Confirm field coverage during Phase 1.)*
5. Reading the current user's Chromium cookie/Local State files needs no elevation
   outside MSIX sandbox constraints. *(Confirm in Phase 0/1; ties to R‑3.)*

## Part D — Decisions Made (Phase 0)

### OD‑1 · Windows UI framework — RESOLVED
**Decision:** **Option B — C#/.NET WinUI 3 shell consuming `codexbar serve`.**
The engine (Phases 0–1) is platform-agnostic; the shell will be built in C#/WinUI 3
and communicate with the Swift engine over the existing `codexbar serve` HTTP/JSON
interface. This minimises UI risk, leverages best-in-class Windows tooling, and
avoids Swift/C# interop.

### OD‑7 · Engine binding: sidecar `serve` vs in‑process FFI — RESOLVED
**Decision:** **Sidecar HTTP via `codexbar serve`.**
The `serve` command is already cross-platform, tested, and provider-agnostic. The
C# shell will poll or subscribe to it. FFI will not be pursued unless polling
latency is measured to be a concrete user-facing problem (revisit Phase 4+).
