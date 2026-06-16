# Engine Contract

Defines the HTTP API that `codexbar.exe serve` exposes and the CLI verbs the
Windows shell invokes for one-shot actions. Both sides of the boundary must
agree on this document.

---

## Startup

The shell launches:

```
codexbar.exe serve --port 0 --auth-token <random-uuid>
```

On first successful listen, `serve` writes a single line to **stdout**:

```json
{"port": 54321, "authToken": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

`port` is the ephemeral TCP port chosen by the OS (when `--port 0` is passed).
`authToken` echoes the value supplied via `--auth-token`. The shell reads this
line, stores both values, and uses them for all subsequent requests.

---

## Authentication

Every HTTP request must include:

```
X-CodexBar-Token: <authToken>
```

The server returns `401 Unauthorized` if the header is absent or the token does
not match. When `--auth-token` is not passed to `serve`, the endpoint is
unauthenticated and the header is ignored.

---

## Base URL

```
http://127.0.0.1:<port>
```

The server binds only to the loopback interface.

---

## Endpoints

### `GET /health`

Liveness probe. Always returns 200 while the server is running.

**Response `200 OK`**

```json
{ "status": "ok" }
```

---

### `GET /usage`

Returns usage data for all enabled providers, or a single provider when filtered.

**Query parameters**

| Parameter  | Type   | Description                                      |
|------------|--------|--------------------------------------------------|
| `provider` | string | Optional. Provider ID (e.g. `claude`, `openai`). Omit for all enabled providers. |

**Response `200 OK` — array of `ProviderPayload`**

```json
[
  {
    "provider": "claude",
    "account": "user@example.com",
    "version": "2025-06",
    "source": "web",
    "status": {
      "indicator": "none",
      "description": "All systems operational",
      "updatedAt": "2025-06-01T12:00:00Z",
      "url": "https://status.anthropic.com"
    },
    "usage": { ... },
    "credits": { ... },
    "error": null
  }
]
```

When a provider fetch fails, the entry is still included; `error` is non-null
and `usage`/`credits` may be null. The engine uses last-good caching and may
substitute a previously successful response for an errored provider row.

#### `ProviderPayload` fields

| Field               | Type                  | Description                                              |
|---------------------|-----------------------|----------------------------------------------------------|
| `provider`          | string                | Provider ID matching `codexbar config providers` output  |
| `account`           | string \| null        | Display name / email for the authenticated account       |
| `version`           | string \| null        | API/plan version string (provider-specific)              |
| `source`            | string                | Data source: `"web"`, `"api"`, `"cli"`, `"local"`, etc. |
| `status`            | `ProviderStatus` \| null | Provider operational status from status page          |
| `usage`             | `UsageSnapshot` \| null  | Rate-window and provider-specific usage detail        |
| `credits`           | `CreditsSnapshot` \| null | Credit balance and recent usage events              |
| `antigravityPlanInfo` | object \| null      | Antigravity-specific plan info (omit if unused)          |
| `openaiDashboard`   | object \| null        | OpenAI web dashboard data (omit if unused)               |
| `error`             | `ProviderError` \| null  | Present when the fetch failed                         |

#### `ProviderStatus`

```json
{
  "indicator": "none",
  "description": "All systems operational",
  "updatedAt": "2025-06-01T12:00:00Z",
  "url": "https://status.anthropic.com"
}
```

| Field        | Type           | Values                                                         |
|--------------|----------------|----------------------------------------------------------------|
| `indicator`  | string (enum)  | `"none"` · `"minor"` · `"major"` · `"critical"` · `"maintenance"` · `"unknown"` |
| `description`| string \| null | Human-readable status message from provider                    |
| `updatedAt`  | ISO 8601 \| null | Timestamp of the last status page update                    |
| `url`        | string         | Status page URL                                                |

#### `UsageSnapshot`

Contains rate-window data and optional provider-specific detail objects. The
three main rate windows (`primary`, `secondary`, `tertiary`) share the same
`RateWindow` shape.

```json
{
  "primary": {
    "usedPercent": 42.5,
    "windowMinutes": 300,
    "resetsAt": "2025-06-01T18:00:00Z",
    "resetDescription": "Resets at 6 PM UTC",
    "nextRegenPercent": null
  },
  "secondary": null,
  "tertiary": null,
  "extraRateWindows": [
    {
      "id": "daily",
      "title": "Daily",
      "window": { "usedPercent": 10.0, "windowMinutes": 1440, "resetsAt": "2025-06-02T00:00:00Z", "resetDescription": null, "nextRegenPercent": null }
    }
  ],
  "subscriptionExpiresAt": null,
  "subscriptionRenewsAt": "2025-07-01T00:00:00Z",
  "updatedAt": "2025-06-01T14:23:00Z",
  "identity": {
    "accountEmail": "user@example.com",
    "accountOrganization": null,
    "loginMethod": "oauth"
  }
}
```

**`RateWindow` fields**

| Field              | Type              | Description                                             |
|--------------------|-------------------|---------------------------------------------------------|
| `usedPercent`      | number            | 0–100+ (over-limit is possible)                        |
| `windowMinutes`    | integer \| null   | Length of the rate window in minutes                    |
| `resetsAt`         | ISO 8601 \| null  | When the window resets                                  |
| `resetDescription` | string \| null    | Human-readable reset timing (e.g. "Resets in 2h 10m")  |
| `nextRegenPercent` | number \| null    | Rolling-window: % restored on the next regen tick       |

Provider-specific sub-objects (`kiroUsage`, `ampUsage`, `zaiUsage`,
`openRouterUsage`, `openAIAPIUsage`, `claudeAdminAPIUsage`, `mistralUsage`,
`deepgramUsage`, etc.) may be present or null. The Windows shell should render
them only when relevant provider cards are implemented; ignore unknown fields.

#### `CreditsSnapshot`

```json
{
  "remaining": 18.42,
  "events": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "date": "2025-06-01T10:00:00Z",
      "service": "claude-3-5-sonnet",
      "creditsUsed": 0.12
    }
  ],
  "updatedAt": "2025-06-01T14:23:00Z"
}
```

| Field       | Type            | Description                              |
|-------------|-----------------|------------------------------------------|
| `remaining` | number          | Credit balance in USD or provider units  |
| `events`    | array           | Recent credit consumption events         |
| `updatedAt` | ISO 8601        | Timestamp of this snapshot               |

#### `ProviderError`

```json
{
  "code": 1,
  "message": "Authentication required",
  "kind": "provider"
}
```

| Field     | Type           | Description                                                       |
|-----------|----------------|-------------------------------------------------------------------|
| `code`    | integer        | Exit-code-mapped error code                                       |
| `message` | string         | Human-readable error description                                  |
| `kind`    | string \| null | `"args"` · `"config"` · `"provider"` · `"runtime"` · null        |

---

### `GET /cost`

Returns token-cost history for providers that support cost scanning (Claude,
Codex). Filter by provider with `?provider=<id>`.

**Query parameters** — same as `/usage`.

**Response `200 OK` — array of `CostPayload`**

```json
[
  {
    "provider": "claude",
    "source": "api",
    "updatedAt": "2025-06-01T14:00:00Z",
    "currencyCode": "USD",
    "sessionTokens": 140000,
    "sessionCostUSD": 0.42,
    "historyDays": 30,
    "last30DaysTokens": 4200000,
    "last30DaysCostUSD": 12.60,
    "daily": [
      {
        "date": "2025-06-01",
        "tokens": 140000,
        "costUSD": 0.42
      }
    ],
    "totals": {
      "tokens": 4200000,
      "costUSD": 12.60
    },
    "error": null
  }
]
```

**`CostPayload` fields**

| Field              | Type              | Description                              |
|--------------------|-------------------|------------------------------------------|
| `provider`         | string            | Provider ID                              |
| `source`           | string            | Data source                              |
| `updatedAt`        | ISO 8601 \| null  | Snapshot timestamp                       |
| `currencyCode`     | string \| null    | e.g. `"USD"`                             |
| `sessionTokens`    | integer \| null   | Tokens in the current session            |
| `sessionCostUSD`   | number \| null    | Cost for the current session in USD      |
| `historyDays`      | integer \| null   | Number of days covered by `daily`        |
| `last30DaysTokens` | integer \| null   | Tokens in the last 30 days               |
| `last30DaysCostUSD`| number \| null    | Cost in the last 30 days                 |
| `daily`            | array             | Per-day breakdown                        |
| `totals`           | object \| null    | Aggregate totals                         |
| `error`            | `ProviderError` \| null | Present when the fetch failed      |

---

## Error responses

| Status | When                                              |
|--------|---------------------------------------------------|
| `400`  | Unknown `provider` query parameter                |
| `401`  | Missing or invalid `X-CodexBar-Token`             |
| `405`  | Non-GET method                                    |
| `404`  | Unknown path                                      |
| `500`  | Config load failure                               |
| `504`  | Fetch timed out (default 30 s)                    |

Error body:

```json
{ "error": "message string" }
```

---

## Config CLI verbs

The shell calls these synchronously for one-shot actions.

```
codexbar config providers
```
Lists all known providers and their enabled state. Output is JSON.

```
codexbar config enable  --provider <id>
codexbar config disable --provider <id>
```
Enables or disables a provider in `~/.codexbar/config.json`. Zero exit code
on success. The running `serve` process detects the config change on the next
poll via a config cache token and returns fresh data.

```
codexbar config set-api-key --provider <id> --stdin
```
Reads an API key from stdin and stores it in the credential store (DPAPI on
Windows). The process exits 0 on success.

---

## Notes

- All timestamps are ISO 8601 with UTC timezone (`Z` suffix).
- The shell must tolerate unknown JSON fields (forward compatibility).
- `usedPercent` may exceed 100 when a provider allows burst over quota.
- The engine uses last-good caching: a stale-but-successful response may be
  returned when the live fetch fails, with the original timestamps preserved.
  The shell should treat `updatedAt` values significantly older than the poll
  cadence as stale and display a staleness indicator.
