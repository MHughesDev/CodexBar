using CodexBar.Shell.Engine;
using Microsoft.UI.Xaml;

namespace CodexBar.Shell.Charts;

public sealed partial class ChartsWindow : Window
{
    private readonly EngineClient _engine;

    public ChartsWindow(EngineClient engine)
    {
        InitializeComponent();
        _engine = engine;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(680, 600));
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        ChartsPanel.Children.Clear();
        var costs = await _engine.GetCostAsync();
        foreach (var cost in costs)
        {
            var points = (cost.DailyEntries ?? [])
                .Select(e => new DailyUsagePoint(
                    DateOnly.Parse(e.Date),
                    (double)(e.TotalCost ?? e.InputTokens + e.OutputTokens)))
                .ToList();

            ChartsPanel.Children.Add(new UsageHistoryChart
            {
                ProviderName = cost.Provider,
                DataPoints = points,
            });
        }
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e) => _ = LoadAsync();
}
