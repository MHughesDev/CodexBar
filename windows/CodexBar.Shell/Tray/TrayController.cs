using CodexBar.Shell.Engine;
using H.NotifyIcon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodexBar.Shell.Tray;

public sealed class TrayController : IDisposable
{
    private readonly TaskbarIcon _trayIcon;
    private readonly FlyoutWindow _flyout;
    private bool _disposed;
    private string? _pinnedProvider;

    public bool MergeIconsMode { get; set; }

    public event EventHandler? SettingsRequested;
    public event EventHandler? QuitRequested;

    public TrayController(FlyoutWindow flyout)
    {
        _flyout = flyout;
        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "CodexBar",
            ContextFlyout = BuildContextMenu([]),
        };

        _trayIcon.LeftClickCommand = new RelayCommand(ToggleFlyout);
    }

    public void UpdateIcon(double usageFraction, bool isStale)
    {
        var icon = DynamicIconRenderer.Render(usageFraction, isStale);
        _trayIcon.Icon = icon;
        _trayIcon.ToolTipText = isStale
            ? $"CodexBar — {usageFraction:P0} used (stale)"
            : $"CodexBar — {usageFraction:P0} used";
    }

    public void UpdateIcon(IReadOnlyList<ProviderDto> providers, bool isStale)
    {
        if (!providers.Any()) return;

        if (MergeIconsMode)
        {
            var segments = providers
                .Select(p => (p.Provider, UsageFraction(p)))
                .ToList();
            var icon = DynamicIconRenderer.RenderMerged(segments, isStale);
            _trayIcon.Icon = icon;
            var highest = providers.MaxBy(UsageFraction);
            _trayIcon.ToolTipText = isStale ? "CodexBar (stale)" : $"CodexBar — highest: {highest?.Provider}";
            _trayIcon.ContextFlyout = BuildContextMenu(providers);
        }
        else
        {
            // Single-provider mode: show the pinned provider or the highest-usage one
            var provider = _pinnedProvider is not null
                ? providers.FirstOrDefault(p => p.Provider == _pinnedProvider) ?? providers.MaxBy(UsageFraction)
                : providers.MaxBy(UsageFraction);
            if (provider is null) return;
            var fraction = UsageFraction(provider);
            UpdateIcon(fraction, isStale);
        }
    }

    private static double UsageFraction(ProviderDto p)
    {
        if (p.Usage is { Used: { } used, Limit: { } limit } && limit > 0)
            return (double)used / limit;
        return 0;
    }

    private void ToggleFlyout()
    {
        if (_flyout.Visible)
            _flyout.HideWindow();
        else
            _flyout.ShowNearTray();
    }

    private MenuFlyout BuildContextMenu(IReadOnlyList<ProviderDto> providers)
    {
        var menu = new MenuFlyout();

        if (MergeIconsMode && providers.Count > 1)
        {
            var providerMenu = new MenuFlyoutSubItem { Text = "Provider" };
            foreach (var p in providers)
            {
                var item = new MenuFlyoutItem { Text = p.Provider };
                item.Click += (_, _) => { _pinnedProvider = p.Provider; };
                providerMenu.Items.Add(item);
            }
            menu.Items.Add(providerMenu);
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        var settingsItem = new MenuFlyoutItem { Text = "Settings" };
        settingsItem.Click += (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty);

        var updateItem = new MenuFlyoutItem { Text = "Check for Updates" };
        updateItem.Click += (_, _) => CheckForUpdates();

        var quitItem = new MenuFlyoutItem { Text = "Quit CodexBar" };
        quitItem.Click += (_, _) => QuitRequested?.Invoke(this, EventArgs.Empty);

        menu.Items.Add(settingsItem);
        menu.Items.Add(updateItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(quitItem);
        return menu;
    }

    private static void CheckForUpdates()
    {
        // Placeholder: open releases page until auto-update is wired.
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "https://github.com/your-org/codexbar/releases",
            UseShellExecute = true,
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _trayIcon.Dispose();
    }
}

// Minimal ICommand implementation to avoid taking a CommunityToolkit dependency here.
internal sealed class RelayCommand(Action execute) : System.Windows.Input.ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => execute();
}
