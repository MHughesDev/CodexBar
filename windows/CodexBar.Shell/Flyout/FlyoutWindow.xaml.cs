using CodexBar.Shell.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace CodexBar.Shell.Flyout;

public sealed partial class FlyoutWindow : Window
{
    private const int FlyoutWidth = 320;
    private const int FlyoutHeight = 480;

    public bool Visible { get; private set; }

    public FlyoutWindow()
    {
        InitializeComponent();
        AppWindow.IsShownInSwitchers = false;

        var presenter = Microsoft.UI.Windowing.OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(hasBorder: false, hasTitleBar: false);
        AppWindow.SetPresenter(presenter);
        AppWindow.Resize(new SizeInt32(FlyoutWidth, FlyoutHeight));

        Activated += FlyoutWindow_Activated;
    }

    public void BindEngineClient(EngineClient client)
    {
        client.UsageUpdated += OnUsageUpdated;
    }

    private void OnUsageUpdated(object? sender, UsageUpdatedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var viewModels = e.Providers.Select(p => new ProviderCardViewModel(p)).ToList();
            ProviderList.ItemsSource = viewModels;

            var mostStale = e.Providers
                .Where(p => p.Usage?.UpdatedAt != null)
                .Select(p => p.Usage!.UpdatedAt)
                .OrderBy(t => t)
                .FirstOrDefault();

            LastUpdatedLabel.Text = mostStale == default
                ? string.Empty
                : $"Updated {FormatAgo(mostStale)}";
        });
    }

    private static string FormatAgo(DateTimeOffset t)
    {
        var elapsed = DateTimeOffset.UtcNow - t;
        if (elapsed.TotalSeconds < 90) return "just now";
        if (elapsed.TotalMinutes < 60) return $"{(int)elapsed.TotalMinutes}m ago";
        return $"{(int)elapsed.TotalHours}h ago";
    }

    public void ShowNearTray()
    {
        PositionNearTray();
        Activate();
        AppWindow.Show();
        Visible = true;
    }

    public void HideWindow()
    {
        AppWindow.Hide();
        Visible = false;
    }

    private void PositionNearTray()
    {
        // Position bottom-right, near the system tray, accounting for DPI.
        var displayArea = Microsoft.UI.Windowing.DisplayArea.Primary;
        var workArea = displayArea.WorkArea;
        var x = workArea.X + workArea.Width - FlyoutWidth - 8;
        var y = workArea.Y + workArea.Height - FlyoutHeight - 8;
        AppWindow.Move(new PointInt32(x, y));
    }

    private void FlyoutWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        // Dismiss when focus moves elsewhere, mirroring macOS popover behaviour.
        if (args.WindowActivationState == WindowActivationState.Deactivated)
            HideWindow();
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        // The App wires an on-demand refresh; raise a routed request via the button tag.
        if (RefreshButton.Tag is Func<Task> refresh)
            await refresh();
    }
}

public sealed class ProviderCardViewModel(ProviderDto provider)
{
    public string ProviderName { get; } = provider.Provider;
    public string? Account { get; } = provider.Account;
    public double UsedPercent { get; } = provider.Usage?.Primary?.UsedPercent ?? 0;
    public string? ResetDescription { get; } = provider.Usage?.Primary?.ResetDescription;
    public double? CreditsRemaining { get; } = provider.Credits?.Remaining;
    public bool HasError { get; } = provider.Error is not null;
    public string? ErrorMessage { get; } = provider.Error?.Message;
    public string StatusIndicator { get; } = provider.Status?.Indicator ?? "none";
}
