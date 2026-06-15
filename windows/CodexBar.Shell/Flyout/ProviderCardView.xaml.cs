using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace CodexBar.Shell.Flyout;

public sealed partial class ProviderCardView : UserControl
{
    public ProviderCardView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (args.NewValue is ProviderCardViewModel vm)
            Bind(vm);
    }

    private void Bind(ProviderCardViewModel vm)
    {
        ProviderNameLabel.Text = vm.ProviderName;

        if (vm.Account is not null)
        {
            AccountLabel.Text = vm.Account;
            AccountLabel.Visibility = Visibility.Visible;
        }

        // Usage bar width is relative to the container; bind after layout via SizeChanged if needed.
        // Here we set a proportional width via a column definition trick or fixed max.
        var fraction = Math.Clamp(vm.UsedPercent / 100.0, 0.0, 1.0);
        UsageBar.Width = fraction * 280; // approximate card inner width
        UsageBar.Fill = new SolidColorBrush(UsageColor(fraction));

        ResetLabel.Text = vm.ResetDescription ?? string.Empty;
        CreditsLabel.Text = vm.CreditsRemaining.HasValue
            ? $"${vm.CreditsRemaining:F2}"
            : string.Empty;

        StatusDot.Fill = new SolidColorBrush(StatusColor(vm.StatusIndicator));
    }

    private static Color UsageColor(double fraction) => fraction switch
    {
        >= 1.0 => Color.FromArgb(255, 255, 60, 60),
        >= 0.8 => Color.FromArgb(255, 255, 165, 0),
        _ => Color.FromArgb(255, 60, 200, 100),
    };

    private static Color StatusColor(string indicator) => indicator switch
    {
        "none" => Color.FromArgb(255, 60, 200, 100),
        "minor" => Color.FromArgb(255, 255, 165, 0),
        "major" or "critical" => Color.FromArgb(255, 255, 60, 60),
        "maintenance" => Color.FromArgb(255, 100, 160, 255),
        _ => Color.FromArgb(255, 160, 160, 160),
    };
}
