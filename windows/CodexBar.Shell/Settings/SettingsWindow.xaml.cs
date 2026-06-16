using CodexBar.Shell.Engine;
using CodexBar.Shell.Tray;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace CodexBar.Shell.Settings;

public sealed partial class SettingsWindow : Window
{
    public CliRunner? CliRunner { get; set; }
    public TrayController? TrayController { get; set; }

    public SettingsWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(760, 540));

        NavView.Loaded += (_, _) =>
        {
            NavView.SelectedItem = NavView.MenuItems[0];
            NavigateTo("Providers");
        };
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item && item.Tag is string tag)
            NavigateTo(tag);
    }

    private void NavigateTo(string tag)
    {
        object? parameter = tag == "Display" ? TrayController : CliRunner;
        var pageType = tag switch
        {
            "Providers" => typeof(ProvidersPage),
            "Display"   => typeof(DisplayPage),
            "Refresh"   => typeof(RefreshPage),
            "Advanced"  => typeof(AdvancedPage),
            "About"     => typeof(AboutPage),
            _           => null,
        };
        if (pageType is not null)
            ContentFrame.Navigate(pageType, parameter);
    }
}

// ── Inline pages ─────────────────────────────────────────────────────────────

public sealed class ProvidersPage : Page
{
    private CliRunner? _cli;

    public ProvidersPage()
    {
        var scroll = new ScrollViewer();
        var panel = new StackPanel { Spacing = 12, Padding = new Thickness(20) };
        scroll.Content = panel;
        Content = scroll;

        var heading = new TextBlock
        {
            Text = "Providers",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            Margin = new Thickness(0, 0, 0, 12),
        };
        panel.Children.Add(heading);

        var listView = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
        };
        panel.Children.Add(listView);

        Loaded += async (_, _) =>
        {
            if (_cli is null) return;
            var result = await _cli.ListProvidersAsync();
            if (result.Success && !string.IsNullOrEmpty(result.Stdout))
            {
                // Parse provider list from JSON; render a toggle + API key field per entry.
                RenderProviderList(listView, result.Stdout);
            }
        };
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _cli = e.Parameter as CliRunner;
    }

    private void RenderProviderList(ListView list, string json)
    {
        // Minimal parse: providers JSON is an array of objects with at least "id" and "enabled".
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var items = new List<ProviderToggleViewModel>();
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                var id = element.TryGetProperty("id", out var idProp) ? idProp.GetString() ?? "" : "";
                var enabled = element.TryGetProperty("enabled", out var enabledProp) && enabledProp.GetBoolean();
                items.Add(new ProviderToggleViewModel(id, enabled, _cli!));
            }
            list.ItemsSource = items;
            list.ItemTemplate = BuildProviderTemplate();
        }
        catch { /* malformed JSON: leave list empty */ }
    }

    private static DataTemplate BuildProviderTemplate()
    {
        // XAML DataTemplates cannot be trivially constructed in code for WinUI 3;
        // use an ItemTemplateSelector or XamlReader for dynamic templates.
        // For the scaffold, return null and render items via ItemContainerStyle.
        return null!;
    }
}

internal sealed class ProviderToggleViewModel(string id, bool enabled, CliRunner cli)
{
    public string Id { get; } = id;
    public bool Enabled { get; private set; } = enabled;

    public async Task ToggleAsync()
    {
        if (Enabled)
            await cli.DisableProviderAsync(Id);
        else
            await cli.EnableProviderAsync(Id);
        Enabled = !Enabled;
    }
}

public sealed class DisplayPage : Page
{
    private TrayController? _tray;
    private AppSettings _settings = AppSettings.Load();

    public DisplayPage()
    {
        var panel = new StackPanel { Padding = new Thickness(20), Spacing = 16 };
        Content = panel;

        panel.Children.Add(new TextBlock
        {
            Text = "Display",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
        });

        var showBarsToggle = new ToggleSwitch
        {
            Header = "Show usage bars",
            IsOn = _settings.ShowUsageBars,
        };
        showBarsToggle.Toggled += (s, _) =>
        {
            _settings = _settings with { ShowUsageBars = ((ToggleSwitch)s).IsOn };
            _settings.Save();
        };
        panel.Children.Add(showBarsToggle);

        var showCountdownToggle = new ToggleSwitch
        {
            Header = "Show reset countdown",
            IsOn = _settings.ShowResetCountdown,
        };
        showCountdownToggle.Toggled += (s, _) =>
        {
            _settings = _settings with { ShowResetCountdown = ((ToggleSwitch)s).IsOn };
            _settings.Save();
        };
        panel.Children.Add(showCountdownToggle);

        var highlightToggle = new ToggleSwitch
        {
            Header = "Highlight highest-usage provider",
            IsOn = _settings.HighlightHighestUsage,
        };
        highlightToggle.Toggled += (s, _) =>
        {
            _settings = _settings with { HighlightHighestUsage = ((ToggleSwitch)s).IsOn };
            _settings.Save();
        };
        panel.Children.Add(highlightToggle);

        panel.Children.Add(new TextBlock { Text = "Icon mode", Margin = new Thickness(0, 8, 0, 0) });
        var iconModePanel = new StackPanel { Spacing = 8 };
        var perProviderRadio = new RadioButton { Content = "Per-Provider Icons", IsChecked = !_settings.MergeIconsMode, GroupName = "iconMode" };
        var mergeRadio = new RadioButton { Content = "Merge Icons (one icon, highest usage)", IsChecked = _settings.MergeIconsMode, GroupName = "iconMode" };

        perProviderRadio.Checked += (_, _) =>
        {
            _settings = _settings with { MergeIconsMode = false };
            _settings.Save();
            if (_tray is not null) _tray.MergeIconsMode = false;
        };
        mergeRadio.Checked += (_, _) =>
        {
            _settings = _settings with { MergeIconsMode = true };
            _settings.Save();
            if (_tray is not null) _tray.MergeIconsMode = true;
        };

        iconModePanel.Children.Add(perProviderRadio);
        iconModePanel.Children.Add(mergeRadio);
        panel.Children.Add(iconModePanel);
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _tray = e.Parameter as TrayController;
    }
}

public sealed class RefreshPage : Page
{
    public RefreshPage()
    {
        var panel = new StackPanel { Padding = new Thickness(20), Spacing = 16 };
        Content = panel;

        panel.Children.Add(new TextBlock
        {
            Text = "Refresh",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
        });

        var cadenceLabel = new TextBlock { Text = "Polling cadence" };
        panel.Children.Add(cadenceLabel);

        var combo = new ComboBox
        {
            Items =
            {
                new ComboBoxItem { Content = "Manual", Tag = 0 },
                new ComboBoxItem { Content = "Every 1 minute", Tag = 60 },
                new ComboBoxItem { Content = "Every 2 minutes", Tag = 120 },
                new ComboBoxItem { Content = "Every 5 minutes", Tag = 300 },
                new ComboBoxItem { Content = "Every 15 minutes", Tag = 900 },
            },
            SelectedIndex = 2,
        };
        panel.Children.Add(combo);
    }
}

public sealed class AdvancedPage : Page
{
    public AdvancedPage()
    {
        var panel = new StackPanel { Padding = new Thickness(20), Spacing = 16 };
        Content = panel;

        panel.Children.Add(new TextBlock
        {
            Text = "Advanced",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
        });

        var credToggle = new ToggleSwitch
        {
            Header = "Disable credential store",
            OffContent = "Credentials stored in Windows DPAPI",
            OnContent = "Credentials stored in plain config (not recommended)",
        };
        panel.Children.Add(credToggle);
    }
}

public sealed class AboutPage : Page
{
    public AboutPage()
    {
        var panel = new StackPanel { Padding = new Thickness(20), Spacing = 12 };
        Content = panel;

        panel.Children.Add(new TextBlock
        {
            Text = "About CodexBar",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
        });

        var version = System.Reflection.Assembly.GetExecutingAssembly()
            .GetName().Version?.ToString() ?? "0.0.0";

        panel.Children.Add(new TextBlock { Text = $"Version {version}" });

        var updateButton = new Button { Content = "Check for Updates" };
        updateButton.Click += (_, _) =>
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "https://github.com/your-org/codexbar/releases",
                UseShellExecute = true,
            });
        };
        panel.Children.Add(updateButton);
    }
}
