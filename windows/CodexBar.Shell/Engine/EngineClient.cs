using System.Net.Http.Json;
using System.Text.Json;

namespace CodexBar.Shell.Engine;

public sealed class EngineClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _http;
    private bool _disposed;

    public event EventHandler<UsageUpdatedEventArgs>? UsageUpdated;

    public EngineClient(int port, string authToken)
    {
        _http = new HttpClient
        {
            BaseAddress = new Uri($"http://127.0.0.1:{port}"),
            Timeout = TimeSpan.FromSeconds(30),
        };
        if (!string.IsNullOrEmpty(authToken))
            _http.DefaultRequestHeaders.Add("X-CodexBar-Token", authToken);
    }

    public async Task<List<ProviderDto>> GetUsageAsync(string? provider = null, CancellationToken ct = default)
    {
        var url = provider is not null ? $"/usage?provider={Uri.EscapeDataString(provider)}" : "/usage";
        var result = await _http.GetFromJsonAsync<List<ProviderDto>>(url, JsonOptions, ct);
        return result ?? [];
    }

    public async Task<List<CostDto>> GetCostAsync(string? provider = null, CancellationToken ct = default)
    {
        var url = provider is not null ? $"/cost?provider={Uri.EscapeDataString(provider)}" : "/cost";
        var result = await _http.GetFromJsonAsync<List<CostDto>>(url, JsonOptions, ct);
        return result ?? [];
    }

    public async Task<bool> GetHealthAsync(CancellationToken ct = default)
    {
        try
        {
            var health = await _http.GetFromJsonAsync<HealthDto>("/health", JsonOptions, ct);
            return health?.Status == "ok";
        }
        catch
        {
            return false;
        }
    }

    public async Task StartPollingAsync(TimeSpan interval, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var providers = await GetUsageAsync(ct: ct);
                UsageUpdated?.Invoke(this, new UsageUpdatedEventArgs(providers));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                // Network errors between polls are transient; the next poll will retry.
            }

            try { await Task.Delay(interval, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _http.Dispose();
    }
}

public sealed class UsageUpdatedEventArgs(List<ProviderDto> providers) : EventArgs
{
    public List<ProviderDto> Providers { get; } = providers;
}
