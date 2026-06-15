using LiveChartsCore;
using LiveChartsCore.SkiaSharpView;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodexBar.Shell.Charts;

public record DailyUsagePoint(DateOnly Date, double Value);

public sealed partial class UsageHistoryChart : UserControl
{
    public static readonly DependencyProperty ProviderNameProperty =
        DependencyProperty.Register(nameof(ProviderName), typeof(string), typeof(UsageHistoryChart),
            new PropertyMetadata(string.Empty, (d, _) => ((UsageHistoryChart)d).Refresh()));

    public static readonly DependencyProperty DataPointsProperty =
        DependencyProperty.Register(nameof(DataPoints), typeof(IEnumerable<DailyUsagePoint>), typeof(UsageHistoryChart),
            new PropertyMetadata(null, (d, _) => ((UsageHistoryChart)d).Refresh()));

    public string ProviderName
    {
        get => (string)GetValue(ProviderNameProperty);
        set => SetValue(ProviderNameProperty, value);
    }

    public IEnumerable<DailyUsagePoint>? DataPoints
    {
        get => (IEnumerable<DailyUsagePoint>?)GetValue(DataPointsProperty);
        set => SetValue(DataPointsProperty, value);
    }

    public UsageHistoryChart() => InitializeComponent();

    private void Refresh()
    {
        ChartTitle.Text = $"Usage — {ProviderName}";

        var points = DataPoints?.ToList() ?? [];
        var values = points.Select(p => p.Value).ToArray();
        var labels = points.Select(p => p.Date.ToString("MMM d")).ToArray();

        Chart.Series = [new ColumnSeries<double> { Values = values, Name = ProviderName }];
        Chart.XAxes = [new Axis { Labels = labels, LabelsRotation = 45 }];
        Chart.YAxes = [new Axis { MinLimit = 0 }];
    }
}
