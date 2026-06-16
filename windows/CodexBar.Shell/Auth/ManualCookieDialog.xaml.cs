using Microsoft.UI.Xaml;

namespace CodexBar.Shell.Auth;

public sealed partial class ManualCookieDialog : Window
{
    public string? CookieValue { get; private set; }

    public ManualCookieDialog(string providerName)
    {
        InitializeComponent();
        Title = $"Paste Cookie for {providerName}";
        TitleText.Text = $"Cookie for {providerName}";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(480, 300));
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        var value = CookiePasteBox.Text?.Trim();
        if (!string.IsNullOrEmpty(value))
        {
            CookieValue = value;
            Close();
        }
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();
}
