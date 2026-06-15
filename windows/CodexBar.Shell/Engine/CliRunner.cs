using System.Diagnostics;
using System.Text;

namespace CodexBar.Shell.Engine;

public sealed class CliRunner(string enginePath)
{
    public async Task<CliResult> RunAsync(
        string arguments,
        string? stdinContent = null,
        CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = enginePath,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = stdinContent is not null,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        using var process = new Process { StartInfo = psi };
        process.Start();

        if (stdinContent is not null)
        {
            await process.StandardInput.WriteAsync(stdinContent);
            process.StandardInput.Close();
        }

        var stdout = await process.StandardOutput.ReadToEndAsync(ct);
        var stderr = await process.StandardError.ReadToEndAsync(ct);

        await process.WaitForExitAsync(ct);

        return new CliResult(process.ExitCode, stdout.Trim(), stderr.Trim());
    }

    public Task<CliResult> EnableProviderAsync(string providerId, CancellationToken ct = default)
        => RunAsync($"config enable --provider {providerId}", ct: ct);

    public Task<CliResult> DisableProviderAsync(string providerId, CancellationToken ct = default)
        => RunAsync($"config disable --provider {providerId}", ct: ct);

    public Task<CliResult> SetApiKeyAsync(string providerId, string apiKey, CancellationToken ct = default)
        => RunAsync($"config set-api-key --provider {providerId} --stdin", stdinContent: apiKey, ct: ct);

    public Task<CliResult> ListProvidersAsync(CancellationToken ct = default)
        => RunAsync("config providers", ct: ct);
}

public sealed record CliResult(int ExitCode, string Stdout, string Stderr)
{
    public bool Success => ExitCode == 0;
}
