using Microsoft.UI.Xaml;
using Microsoft.Web.WebView2.Core;

namespace CodexBar.Shell.Auth;

public sealed partial class OAuthWebViewWindow : Window
{
    private readonly string _redirectUriPrefix;
    private readonly TaskCompletionSource<string?> _tcs = new();

    public OAuthWebViewWindow(string providerName, string startUrl, string redirectUriPrefix)
    {
        InitializeComponent();
        _redirectUriPrefix = redirectUriPrefix;
        Title = $"Sign in to {providerName}";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(900, 700));

        Closed += (_, _) => _tcs.TrySetResult(null);

        WebView.Loaded += async (_, _) =>
        {
            await WebView.EnsureCoreWebView2Async();
            WebView.Source = new Uri(startUrl);
        };
    }

    private void WebView_NavigationStarting(Microsoft.Web.WebView2.WinUI.WebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (args.Uri.StartsWith(_redirectUriPrefix, StringComparison.OrdinalIgnoreCase))
        {
            args.Cancel = true;
            _tcs.TrySetResult(args.Uri);
            Close();
        }
    }

    public Task<string?> GetRedirectUrlAsync() => _tcs.Task;
}
