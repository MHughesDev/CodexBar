using CodexBar.Shell.Engine;
using CodexBar.Shell.Flyout;
using CodexBar.Shell.Notifications;
using CodexBar.Shell.Settings;
using CodexBar.Shell.Tray;
using Microsoft.UI.Xaml;

namespace CodexBar.Shell;

public partial class App : Application
{
    private const string MutexName = "CodexBar.Shell.SingleInstance";

    private Mutex? _mutex;
    private SidecarManager? _sidecar;
    private EngineClient? _engineClient;
    private TrayController? _trayController;
    private FlyoutWindow? _flyout;
    private SettingsWindow? _settingsWindow;
    private CancellationTokenSource? _pollCts;

    public App()
    {
        InitializeComponent();
        UnhandledException += App_UnhandledException;
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Single-instance guard: if another instance holds the mutex, quit silently.
        _mutex = new Mutex(initiallyOwned: true, MutexName, out bool isNew);
        if (!isNew)
        {
            Exit();
            return;
        }

        ToastHelper.Register();
        ToastHelper.NotificationActivated += OnNotificationActivated;

        var enginePath = ResolveEnginePath();

        _sidecar = new SidecarManager(enginePath);
        try
        {
            await _sidecar.StartAsync();
        }
        catch (Exception ex)
        {
            // Cannot start engine — surface an error toast and exit.
            ToastHelper.ShowQuotaWarning("Engine", 0);
            _ = ex;
            Exit();
            return;
        }

        _engineClient = new EngineClient(_sidecar.Port, _sidecar.AuthToken);

        _flyout = new FlyoutWindow();
        _flyout.BindEngineClient(_engineClient);

        var cliRunner = new CliRunner(enginePath);

        _trayController = new TrayController(_flyout);
        _trayController.SettingsRequested += OnSettingsRequested;
        _trayController.QuitRequested += OnQuitRequested;

        _engineClient.UsageUpdated += OnUsageUpdated;

        _pollCts = new CancellationTokenSource();
        _ = _engineClient.StartPollingAsync(TimeSpan.FromMinutes(2), _pollCts.Token);
    }

    private void OnUsageUpdated(object? sender, UsageUpdatedEventArgs e)
    {
        if (_trayController is null) return;

        // Compute the highest usage fraction across all providers with a primary window.
        double maxFraction = 0;
        bool anyStale = false;

        foreach (var p in e.Providers)
        {
            if (p.Usage?.Primary is { } window)
            {
                maxFraction = Math.Max(maxFraction, window.UsedPercent / 100.0);
                if (DateTimeOffset.UtcNow - p.Usage.UpdatedAt > TimeSpan.FromMinutes(5))
                    anyStale = true;
            }

            // Emit quota warnings for providers crossing the 90% threshold.
            if (p.Usage?.Primary?.UsedPercent >= 90 && p.Error is null)
                ToastHelper.ShowQuotaWarning(p.Provider, p.Usage.Primary.UsedPercent);

            if (p.Error?.Kind == "provider" &&
                p.Error.Message.Contains("auth", StringComparison.OrdinalIgnoreCase))
                ToastHelper.ShowLoginRequired(p.Provider);
        }

        _trayController.UpdateIcon(Math.Clamp(maxFraction, 0, 1), anyStale);
    }

    private void OnSettingsRequested(object? sender, EventArgs e)
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow
            {
                CliRunner = _sidecar is null ? null : new CliRunner(ResolveEnginePath()),
            };
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }
        _settingsWindow.Activate();
    }

    private void OnQuitRequested(object? sender, EventArgs e) => Shutdown();

    private void App_UnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        // Log and continue where possible; mark handled to prevent OS crash dialog.
        System.Diagnostics.Debug.WriteLine($"Unhandled: {e.Exception}");
        e.Handled = true;
    }

    private void OnNotificationActivated(object? sender, Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs args)
    {
        if (args.Arguments.TryGetValue("action", out var action) && action == "open")
            _flyout?.ShowNearTray();
    }

    private void Shutdown()
    {
        _pollCts?.Cancel();
        _engineClient?.Dispose();
        _sidecar?.Stop();
        _sidecar?.Dispose();
        _trayController?.Dispose();
        _mutex?.ReleaseMutex();
        _mutex?.Dispose();
        Exit();
    }

    private static string ResolveEnginePath()
    {
        // Look for codexbar.exe next to the shell executable first, then on PATH.
        var dir = AppContext.BaseDirectory;
        var candidate = Path.Combine(dir, "codexbar.exe");
        return File.Exists(candidate) ? candidate : "codexbar.exe";
    }
}
