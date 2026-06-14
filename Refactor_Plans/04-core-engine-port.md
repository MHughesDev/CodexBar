# 04 — Core Engine Port (`CodexBarCore` + `CodexBarCLI` on Windows)

This is the workstream that makes the **engine** compile and run on Windows. It is
mostly **filling in Windows arms** of existing `#if` ladders, plus a few new shims.
The engine already builds on Linux, so "non‑Darwin" code paths largely exist; the
work is making "non‑Darwin" correctly mean **Linux *or* Windows**.

## 1. The conditional‑compilation strategy

The codebase uses two idioms. Extend both consistently:

```swift
// Idiom 1: syscall layer
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)      // ADD
import WinSDK
#else
import Glibc
#endif

// Idiom 2: capability gate
#if os(macOS)
    // Keychain / AppKit / WebKit …
#else
    // portable fallback (today: Linux; now must also satisfy Windows)
#endif
```

**Rule of thumb:** anywhere you see `#if canImport(Darwin) … #else import Glibc`,
Windows will currently try to `import Glibc` and fail. Audit all **30
`canImport(Darwin)`** sites and add a `WinSDK`/`os(Windows)` arm. Anywhere you see
`#if os(macOS) … #else return <no-op>`, Windows already gets the no‑op — those
need real Windows implementations only where the feature must work (cred store,
cookies, PTY).

## 2. File‑by‑file: the syscall / process layer

### 2.1 `AutoreleasePoolCompat.swift`
Currently `#if os(Linux)` provides a no‑op `autoreleasepool`. **Change to**
`#if !canImport(ObjectiveC)` (or `#if os(Linux) || os(Windows)`) so Windows also
gets the shim. **Effort: S.**

### 2.2 `Host/Process/SubprocessRunner.swift`
Uses `Foundation.Process` (✅ works on Windows) but POSIX‑specific control:
- `setpgid(pid, pid)` to make a process group, then `kill(-pgid, SIGTERM/SIGKILL)`
  to kill the whole tree. **No Windows equivalent.**
- `usleep`, `kill`, `SIGTERM`, `SIGKILL` from Darwin/Glibc.

Windows plan:
- Replace process‑group kill with a **Job Object**: create a job
  (`CreateJobObject`), assign the child (`AssignProcessToJobObject`) with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, and terminate via
  `TerminateJobObject` / closing the handle — kills the whole tree cleanly.
- Replace `process.terminate()` escalation with `TerminateProcess`.
- Replace `usleep(50000)` with `Sleep(50)` (WinSDK) or `Thread.sleep`.
- Gate all of this: keep the POSIX path for Darwin/Glibc, add a `#if os(Windows)`
  branch using `WinSDK`. Encapsulate as a small `ProcessTree` helper so the rest
  of `run(...)` is unchanged.

**Effort: M.** This is critical — **many providers shell out to CLIs** (Claude,
Codex, Gemini, Augment, Kiro, Grok, etc.).

### 2.3 `Host/Process/ProcessPipeCapture.swift`
`Pipe`/`FileHandle` async draining. Generally portable (Foundation), but
**validate non‑blocking reads** and EOF semantics on Windows pipes; the macOS
implementation may rely on `readabilityHandler` behavior. Add tests. **Effort: M.**

### 2.4 `Host/PTY/TTYCommandRunner.swift` — the hard one
Uses POSIX pseudo‑terminals (`forkpty`/`openpty`, `pid_t`, process registry with
signals) to run the **Claude CLI** as if attached to a real terminal (its
status/login flows need a TTY). There is **no PTY on Windows** in the POSIX sense.

Windows plan — **ConPTY** (`CreatePseudoConsole`, `ResizePseudoConsole`,
`ClosePseudoConsole`, with `STARTUPINFOEX` + `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`):
- Build a `WindowsPTY` type that creates input/output pipes, a pseudo‑console, and
  launches the child wired to it.
- Map the existing `TTYCommandRunner` public API onto ConPTY behind
  `#if os(Windows)`.
- The active‑process registry (currently `pid_t` + signal broadcast) becomes a
  `HANDLE`/job‑object registry.

**Effort: L.** This is the single most involved engine shim. **Mitigation:** PTY
is used by **Claude's CLI fallback** specifically. Sequence it *after* the API/
OAuth/cookie providers work, and ship Windows v1 with Claude via OAuth/cookies
(its other supported sources) if ConPTY slips. Track as risk in `11`.

### 2.5 `CodexBarClaudeWatchdog` / `CodexBarClaudeWebProbe`
Both are macOS‑gated executables that assist Claude PTY/web flows. For Windows,
either provide ConPTY‑based equivalents (after 2.4) or omit from v1. **Effort: M
(deferred).**

## 3. Filesystem & paths

Audit every hard‑coded POSIX path and `~` expansion. Providers read things like
`~/.codex`, `~/.claude`, `~/.config/...`, `~/.codexbar/config.json`, browser
profile dirs, and app‑support locations.

Plan:
- Centralize path resolution in a `PlatformPaths` helper (some likely exists —
  audit `Config/` and `AppGroupSupport.swift`). Provide Windows mappings:
  - `~` → `%USERPROFILE%` (FileManager `.homeDirectoryForCurrentUser` works).
  - XDG `~/.config/x` → keep `~/.config/x` if the provider CLI uses it on Windows
    too (many cross‑platform CLIs do), else `%APPDATA%\x`.
  - CodexBar's own config: `~/.codexbar/config.json` → keep under
    `%USERPROFILE%\.codexbar\` for cross‑OS consistency (the CLI already uses a
    dotfile dir; preserve it so `config` commands behave identically).
  - Browser profiles: see `05 §4` (these are very different on Windows).
- Replace any literal `/` joins with `URL`/`FileManager` APIs (mostly already the
  case). Watch for `:` path‑list splitting (`PATH` uses `;` on Windows) and line
  endings (`\r\n`).
- `FileManager.isExecutableFile(atPath:)` (used by `SubprocessRunner` to locate
  binaries) behaves differently on Windows (`.exe`/`.cmd`/`PATHEXT`). Add a
  Windows‑aware executable resolver (search `PATH` with `PATHEXT`). **Effort: M.**

## 4. Networking

Already handled: 68 files use `#if canImport(FoundationNetworking)`. `URLSession`,
cookies in requests, and TLS work on Windows via swift‑foundation. **Mostly free.**
Validate:
- Proxy handling (Windows system proxy via WinHTTP/WinINET differs).
- Custom `URLSessionDelegate` TLS pinning, if any.
- Any reliance on `.ephemeral`/cookie‑storage semantics.

**Effort: S–M (mostly verification + a few edge fixes).**

## 5. SQLite

6 files use system SQLite (`import SQLite3` / `sqlite3_*`) for local reads
(Windsurf cache, Cursor, OpenCode Go, Factory localStorage, Alibaba cookies, Codex
cost cache). Windows has **no system `libsqlite3` on the linker path by default**.
Options:
- Link **`winsqlite3.dll`** (ships with Windows 10+); expose it to Swift via a
  module map / system library target. Simplest, no vendoring.
- Or vendor the SQLite amalgamation as a small C target.

Gate the import (`#if canImport(SQLite3)` already present) and add the Windows
module mapping. **Effort: M.**

## 6. Crypto, logging, macros, autorelease

- **Crypto:** `swift-crypto` (`import Crypto`) already provides hashing/HMAC on
  non‑Apple. Ensure all crypto sites prefer `Crypto` when `!canImport(CryptoKit)`.
  `CommonCrypto` (1 file) is Apple‑only — replace that site with `Crypto`. **S–M.**
- **Logging:** `swift-log` is cross‑platform. The `os.Logger` (`import os`, 5
  files) is Apple‑only — already likely gated; ensure a swift‑log fallback on
  Windows. **S.**
- **Macros:** see `03 §2.3`.

## 7. The 4 AppKit imports inside Core

Core has **4 files importing AppKit** — these must not be in the Windows graph.
Audit each:
- If it's an `NSImage`/icon/pasteboard helper, **move it to the shell** or gate it
  `#if os(macOS)` and provide a portable type for the data the engine actually
  needs (e.g. raw bytes instead of `NSImage`).
- The engine's *public surface* must not expose AppKit types to the CLI/serve
  path (verify `serve`/`usage` JSON encoders don't touch AppKit). **Effort: M.**

## 8. WebKit in Core (`OpenAIWeb/`)

6 Core files use WKWebView to scrape the **OpenAI dashboard** for *optional* Codex
extras (code‑review remaining, usage breakdown, credits history). This is the only
provider feature needing an embedded browser in the engine.

Plan:
- Gate the WKWebView implementation `#if os(macOS)` (it likely already is via the
  app, but here it's in Core).
- For Windows, this offscreen‑scrape belongs in the **shell's WebView2** (the UI
  process), not the engine — the shell can run the navigation and hand cookies/
  results back, *or* this optional extra is **deferred** for v1.
- Define a `DashboardScraper` protocol in Core so the platform supplies the
  implementation (macOS: WKWebView; Windows: WebView2 in the shell; Linux:
  unavailable). **Effort: M (or S if deferred for v1).**

## 9. `serve` hardening for the Windows shell

`serve` already works cross‑platform. Two small additive enhancements for the
sidecar model (see `02 §5.4`):
- Accept `--port 0` to bind an OS‑chosen ephemeral port and print it (so the shell
  doesn't guess). 
- Optional `--auth-token <secret>` requiring an `Authorization`/custom header, so
  only the shell that spawned it can query. **Effort: S.** (Backward compatible.)

## 10. Engine port — definition of done

- [ ] All `canImport(Darwin)` ladders have a `WinSDK`/`os(Windows)` arm.
- [ ] `SubprocessRunner` kills process trees via Job Objects on Windows.
- [ ] Executable resolution honors `PATH`/`PATHEXT`.
- [ ] Paths resolve correctly for engine config + provider sources on Windows.
- [ ] SQLite links (`winsqlite3.dll`) and the 6 readers work.
- [ ] Networking verified for the top providers; proxies handled.
- [ ] No AppKit/WebKit symbols in the Windows engine graph.
- [ ] `codexbar.exe usage/cost/config/serve` all run on Windows.
- [ ] (Stretch) ConPTY‑backed `TTYCommandRunner` for Claude CLI.

## 11. Effort summary

| Area | Effort | Risk |
|---|---|---|
| `#if` ladder fixes, autorelease, logging, crypto | S–M | low |
| SubprocessRunner (Job Objects) + exec resolution | M | medium |
| Filesystem/paths centralization | M | medium |
| SQLite on Windows | M | low‑med |
| Networking verification | S–M | low |
| AppKit‑in‑Core removal/gating | M | medium |
| WebKit/OpenAI dashboard (defer or WebView2) | S–M | medium |
| **PTY → ConPTY** | **L** | **high** |
| serve sidecar hardening | S | low |
