using H.NotifyIcon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodexBar.Shell.Tray;

public sealed class TrayController : IDisposable
{
    private readonly TaskbarIcon _trayIcon;
    private readonly FlyoutWindow _flyout;
    private bool _disposed;

    public event EventHandler? SettingsRequested;
    public event EventHandler? QuitRequested;

    public TrayController(FlyoutWindow flyout)
    {
        _flyout = flyout;
        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "CodexBar",
            ContextFlyout = BuildContextMenu(),
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

    private void ToggleFlyout()
    {
        if (_flyout.Visible)
            _flyout.HideWindow();
        else
            _flyout.ShowNearTray();
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();

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
