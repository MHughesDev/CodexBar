using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;

namespace CodexBar.Shell.Auth;

public sealed partial class DeviceFlowWindow : Window
{
    private readonly string _userCode;
    private readonly string _verificationUri;
    private readonly TaskCompletionSource<bool> _tcs = new();

    public DeviceFlowWindow(string providerName, string userCode, string verificationUri)
    {
        InitializeComponent();
        _userCode = userCode;
        _verificationUri = verificationUri;

        Title = $"Authorize {providerName}";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(440, 260));

        UserCodeText.Text = userCode;
        VerificationLink.Content = verificationUri;
        VerificationLink.NavigateUri = new Uri(verificationUri);

        Closed += (_, _) => _tcs.TrySetResult(false);
    }

    public void NotifyAuthorized()
    {
        _tcs.TrySetResult(true);
        DispatcherQueue.TryEnqueue(Close);
    }

    public Task<bool> WaitForAuthorizationAsync(CancellationToken ct)
    {
        ct.Register(() => _tcs.TrySetResult(false));
        return _tcs.Task;
    }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        var data = new DataPackage();
        data.SetText(_userCode);
        Clipboard.SetContent(data);
    }

    private async void VerificationLink_Click(object sender, RoutedEventArgs e)
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri(_verificationUri));
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _tcs.TrySetResult(false);
        Close();
    }
}
