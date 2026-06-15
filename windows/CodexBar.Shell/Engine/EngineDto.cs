using System.Text.Json.Serialization;

namespace CodexBar.Shell.Engine;

public record RateWindowDto(
    [property: JsonPropertyName("usedPercent")] double UsedPercent,
    [property: JsonPropertyName("windowMinutes")] int? WindowMinutes,
    [property: JsonPropertyName("resetsAt")] DateTimeOffset? ResetsAt,
    [property: JsonPropertyName("resetDescription")] string? ResetDescription,
    [property: JsonPropertyName("nextRegenPercent")] double? NextRegenPercent)
{
    public double RemainingPercent => Math.Max(0, 100 - UsedPercent);
}

public record NamedRateWindowDto(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("window")] RateWindowDto Window);

public record ProviderIdentityDto(
    [property: JsonPropertyName("accountEmail")] string? AccountEmail,
    [property: JsonPropertyName("accountOrganization")] string? AccountOrganization,
    [property: JsonPropertyName("loginMethod")] string? LoginMethod);

public record UsageDto(
    [property: JsonPropertyName("primary")] RateWindowDto? Primary,
    [property: JsonPropertyName("secondary")] RateWindowDto? Secondary,
    [property: JsonPropertyName("tertiary")] RateWindowDto? Tertiary,
    [property: JsonPropertyName("extraRateWindows")] List<NamedRateWindowDto>? ExtraRateWindows,
    [property: JsonPropertyName("subscriptionExpiresAt")] DateTimeOffset? SubscriptionExpiresAt,
    [property: JsonPropertyName("subscriptionRenewsAt")] DateTimeOffset? SubscriptionRenewsAt,
    [property: JsonPropertyName("updatedAt")] DateTimeOffset UpdatedAt,
    [property: JsonPropertyName("identity")] ProviderIdentityDto? Identity);

public record CreditEventDto(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("date")] DateTimeOffset Date,
    [property: JsonPropertyName("service")] string Service,
    [property: JsonPropertyName("creditsUsed")] double CreditsUsed);

public record CreditsDto(
    [property: JsonPropertyName("remaining")] double Remaining,
    [property: JsonPropertyName("events")] List<CreditEventDto> Events,
    [property: JsonPropertyName("updatedAt")] DateTimeOffset UpdatedAt);

public record ProviderStatusDto(
    [property: JsonPropertyName("indicator")] string Indicator,
    [property: JsonPropertyName("description")] string? Description,
    [property: JsonPropertyName("updatedAt")] DateTimeOffset? UpdatedAt,
    [property: JsonPropertyName("url")] string Url);

public record ProviderErrorDto(
    [property: JsonPropertyName("code")] int Code,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("kind")] string? Kind);

public record ProviderDto(
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("account")] string? Account,
    [property: JsonPropertyName("version")] string? Version,
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("status")] ProviderStatusDto? Status,
    [property: JsonPropertyName("usage")] UsageDto? Usage,
    [property: JsonPropertyName("credits")] CreditsDto? Credits,
    [property: JsonPropertyName("error")] ProviderErrorDto? Error);

public record CostDailyEntryDto(
    [property: JsonPropertyName("date")] string Date,
    [property: JsonPropertyName("tokens")] long? Tokens,
    [property: JsonPropertyName("costUSD")] double? CostUsd);

public record CostTotalsDto(
    [property: JsonPropertyName("tokens")] long? Tokens,
    [property: JsonPropertyName("costUSD")] double? CostUsd);

public record CostDto(
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("updatedAt")] DateTimeOffset? UpdatedAt,
    [property: JsonPropertyName("currencyCode")] string? CurrencyCode,
    [property: JsonPropertyName("sessionTokens")] long? SessionTokens,
    [property: JsonPropertyName("sessionCostUSD")] double? SessionCostUsd,
    [property: JsonPropertyName("historyDays")] int? HistoryDays,
    [property: JsonPropertyName("last30DaysTokens")] long? Last30DaysTokens,
    [property: JsonPropertyName("last30DaysCostUSD")] double? Last30DaysCostUsd,
    [property: JsonPropertyName("daily")] List<CostDailyEntryDto> Daily,
    [property: JsonPropertyName("totals")] CostTotalsDto? Totals,
    [property: JsonPropertyName("error")] ProviderErrorDto? Error);

public record HealthDto(
    [property: JsonPropertyName("status")] string Status);

public record ServeReadyDto(
    [property: JsonPropertyName("port")] int Port,
    [property: JsonPropertyName("authToken")] string AuthToken);
