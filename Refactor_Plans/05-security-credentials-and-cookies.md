# 05 — Security: Credentials & Browser Cookies (Windows)

Two macOS subsystems have no automatic Windows fallback and gate a large share of
providers: **the Keychain** (API keys, OAuth tokens, cached cookie headers) and
**SweetCookieKit** (browser cookie extraction). Both already have clean seams in
the code; this doc specifies the Windows backends.

## 1. Credential storage — macOS Keychain → Windows

### 1.1 What uses the Keychain today (8 Core + 10 app files)
- `KeychainCacheStore.swift` — generic encrypted cache (cookie headers, snapshots);
  keyed by `category.identifier` (e.g. `cookie.<provider>`, `oauth.<provider>`).
- `KeychainNoUIQuery.swift` — forces non‑interactive reads (no prompts).
- `KeychainAccessGate.swift` / `KeychainAccessPreflight.swift` — global "disable
  Keychain" switch + preflight checks.
- Provider OAuth/credential stores: Claude OAuth (`ClaudeOAuthCredentials*`),
  Codex OAuth, VertexAI OAuth, Antigravity OAuth, Factory manual creds, Bedrock,
  Kimi K2 token store, etc.
- App‑side: `KeychainMigration.swift`, `KeychainPromptCoordinator.swift`.

Crucially, `KeychainCacheStore` already has the shape:
```swift
#if os(macOS)
   … SecItemCopyMatching / SecItemAdd / SecItemUpdate / SecItemDelete …
#else
   return .missing / .failed   // no-op on Linux today
#endif
```
So **Windows currently gets a no‑op store** (everything "missing"). We replace the
`#else` (or add `#elseif os(Windows)`) with a real backend.

### 1.2 Windows backend options

| Option | Mechanism | Pros | Cons |
|---|---|---|---|
| **Credential Manager** (recommended) | `CredWriteW`/`CredReadW`/`CredDeleteW`/`CredEnumerateW` (Wincred, in `WinSDK`) | OS‑managed, per‑user, roams optionally, supports enumeration (needed by `keys(category:)`) | 2.5 KB blob limit per credential (chunk large entries) |
| **DPAPI file vault** | `CryptProtectData`/`CryptUnprotectData` → encrypted blobs in `%LOCALAPPDATA%\CodexBar\` | No size limit; simple | We manage the file lifecycle; no built‑in enumeration UI |
| Hybrid | Small secrets in Credential Manager, large blobs DPAPI‑encrypted on disk | Best of both | Two code paths |

**Recommendation:** implement a `CredentialStore` Windows backend on **Credential
Manager** (it maps 1:1 to the `Key(category, identifier)` model and supports
enumeration for `keysResult(category:)`), with **DPAPI‑on‑disk** fallback for
entries exceeding the size limit (cached snapshots can be large).

### 1.3 Mapping the macOS API surface

| macOS (Security.framework) | Windows |
|---|---|
| `SecItemAdd` / `SecItemUpdate` | `CredWriteW` (`CRED_TYPE_GENERIC`) |
| `SecItemCopyMatching` (single) | `CredReadW` |
| `SecItemCopyMatching` (all, `kSecMatchLimitAll`) | `CredEnumerateW("CodexBar:cookie.*")` |
| `SecItemDelete` | `CredDeleteW` |
| Service name (`com.steipete.codexbar.cache`) | Target‑name prefix, e.g. `CodexBar:cache:<account>` |
| `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | `CRED_PERSIST_LOCAL_MACHINE`/`CRED_PERSIST_ENTERPRISE` (choose `LOCAL_MACHINE` for device‑local) |
| `KeychainNoUIQuery` (no prompt) | N/A — Credential Manager reads don't prompt; treat as no‑op |
| `KeychainAccessGate.isDisabled` | Keep — same global switch disables the Windows store too |
| `errSecInteractionNotAllowed` (locked) | Map from `GetLastError()` codes to the same `temporarilyUnavailable` result |

### 1.4 Implementation shape
Introduce a Swift `protocol SecretStore` in Core with `load/store/clear/keys`
returning the existing `LoadResult`/`ClearResult`/`KeysResult` enums (already
defined in `KeychainCacheStore`). Provide:
- `macOSKeychainSecretStore` (the current code, refactored behind the protocol),
- `WindowsCredentialSecretStore` (`#if os(Windows)`, Wincred + DPAPI),
- `NoopSecretStore` (Linux, current behavior).

Route `KeychainCacheStore` and the OAuth credential stores through the protocol.
This keeps the public API and tests intact (the existing test‑store override
mechanism still works) while swapping the platform backend. **Effort: L** (the
generic cache is straightforward; each OAuth store needs its read/write path
pointed at the protocol and Windows‑tested).

### 1.5 Reading credentials *written by other tools*
Some providers don't use CodexBar's own store — they read credentials that the
**provider's CLI** wrote (e.g. Claude Code, Codex, gcloud, AWS). On macOS some of
these live in the Keychain (e.g. "Claude Code‑credentials"); on Windows the same
CLIs typically store tokens in **files** (`~/.claude`, `~/.codex`,
`%APPDATA%\gcloud`, `~/.aws`). This is often *easier* on Windows (file reads, no
ACL prompts). Audit each OAuth provider's source‑of‑truth on Windows:
- Claude: CLI writes credentials to a file on Windows → read the file (no
  Keychain). 
- Codex: `~/.codex` config/auth files → read directly.
- gcloud/VertexAI, AWS/Bedrock: standard config dirs → read directly.

Document the per‑provider Windows credential location in each provider's plan row
(`06` matrix references this).

## 2. The macOS Keychain UX problems do *not* port

The README's lengthy "Keychain access control / Always Allow" guidance and the
`KEYCHAIN_FIX.md` doc describe macOS‑specific ACL pain (Chromium Safe Storage
prompts, ACL resets). **None of this exists on Windows** — Credential Manager and
DPAPI are silent per‑user. This is a genuine UX *win* for the Windows port; drop
the related prompt‑coordination code paths (`KeychainPromptCoordinator`,
`KeychainNoUIQuery`) on Windows.

## 3. Browser cookies — SweetCookieKit → Windows

### 3.1 What uses it (37 files)
`SweetCookieKit` provides browser cookie extraction on macOS and is a **direct
dependency of `CodexBarCore`**. Cookie‑based providers (Cursor, OpenCode, Grok,
T3 Chat, Manus, MiniMax, MiMo, Abacus, Amp, Perplexity, Mistral, Command Code,
Devin, Factory, Alibaba, Ollama, Copilot budget, Claude web, OpenAI dashboard, …)
rely on it. Central files: `BrowserDetection.swift`, `BrowserCookieImportOrder.swift`,
`BrowserCookieAccessGate.swift`, plus per‑provider `*CookieImporter.swift`.

### 3.2 Why it can't just be recompiled
SweetCookieKit decrypts cookies using macOS mechanisms (Keychain "Safe Storage"
key, Apple crypto, Safari/macOS profile layout). Windows Chromium cookie
encryption is entirely different:
- Cookies live in `%LOCALAPPDATA%\<Browser>\User Data\<Profile>\Network\Cookies`
  (SQLite).
- Values are encrypted with a key stored in `…\User Data\Local State` (JSON),
  itself protected by **DPAPI** (the `os_crypt.encrypted_key`, base64,
  `DPAPI`‑prefixed). Modern Chrome (v127+, 2024) adds **App‑Bound Encryption
  (ABE)** that ties the key to the browser via an elevated COM service — a moving
  target.

### 3.3 Plan: a `CookieBackend` abstraction
1. Define `protocol CookieBackend` in Core: `cookies(forDomain:browsers:) ->
   [HTTPCookie]` plus browser discovery. Move the existing SweetCookieKit usage
   behind it (`#if canImport(SweetCookieKit)` — some sites already are).
2. **macOS:** `SweetCookieKitCookieBackend` (existing behavior).
3. **Windows:** `WindowsChromiumCookieBackend`:
   - Enumerate installed Chromium browsers (Chrome, Edge, Brave, Vivaldi, Opera)
     by their `User Data` paths under `%LOCALAPPDATA%`/`%APPDATA%`.
   - Read `Local State` → base64‑decode `os_crypt.encrypted_key` → strip `DPAPI`
     prefix → `CryptUnprotectData` → AES‑GCM key.
   - Open the `Cookies` SQLite DB (copy‑to‑temp to avoid lock), read
     `encrypted_value`, decrypt **v10/v11** (AES‑256‑GCM, 3‑byte prefix, 12‑byte
     nonce) using `swift-crypto`.
   - **App‑Bound Encryption:** detect `v20`/ABE values; for v1, **document the
     limitation** (some Chrome profiles may not be decryptable headless) and
     prefer Edge/Brave or manual‑cookie entry where ABE blocks. Track ABE handling
     as an explicit risk/decision (`11`). Manual cookie paste (already supported
     for several providers) is the universal fallback.
   - Firefox (if SweetCookieKit supports it on mac): cookies are in
     `cookies.sqlite` and **not encrypted** → easy win on Windows.
4. **Linux:** keep current behavior (no‑op or libsecret, as today).

### 3.4 `BrowserDetection` on Windows
Rewrite browser path discovery for Windows profile layouts and registry‑based
install detection. Preserve the existing **import order / Chrome‑first default**
policy (AGENTS.md: "default Chrome‑only when possible to avoid other browser
prompts") — on Windows there are no prompts, so the policy is about reliability,
not permissions. **Effort: L** (this plus 3.3 is the second‑largest engine shim
after PTY).

### 3.5 Cookie cache
Decrypted cookie headers are cached via `KeychainCacheStore` (now the Windows
`CredentialStore`/DPAPI). So §1 must land before cookie caching works end‑to‑end.

## 4. Full Disk Access → not needed on Windows

macOS needs Full Disk Access to read Safari cookies. Windows has **no Safari** and
no equivalent gate for reading the current user's own browser files — the app runs
as the user and can read `%LOCALAPPDATA%` directly. Remove FDA‑related guidance and
gates on Windows. (Reading *another* user's profile would need elevation, but
that's out of scope.)

## 5. Effort & sequencing

| Item | Effort | Notes |
|---|---|---|
| `SecretStore` protocol + macOS refactor | M | no behavior change on mac |
| Windows Credential Manager + DPAPI backend | L | unblocks API‑key + OAuth caching |
| Per‑provider OAuth source audit (file vs store) | M | many become file reads on Windows |
| `CookieBackend` protocol + macOS move | M | decouples SweetCookieKit |
| Windows Chromium cookie decryptor (v10/v11) | L | core of cookie providers |
| App‑Bound Encryption handling/decision | M | risk; manual‑cookie fallback exists |
| `BrowserDetection` for Windows | M | profile discovery |

**Sequence:** SecretStore (§1) → CookieBackend macOS move (§3.3.1) → Windows
cookie decryptor (§3.3.3) → BrowserDetection (§3.4). API‑key providers work after
§1 alone, so they validate the cred store before tackling cookies.
