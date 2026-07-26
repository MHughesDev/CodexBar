using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace CodexBar.Shell.Notifications;

public static class ToastHelper
{
    // For unpackaged apps without a COM server / AUMID, AppNotificationManager.Register()
    // can corrupt the COM heap. Set _supported only after a proven successful registration.
    private static bool _supported;

    public static void Register()
    {
        // AppNotificationManager.Register() corrupts the COM heap for unpackaged apps
        // without a COM server / AUMID registered. Skip registration entirely for now.
        // _supported remains false so all Show* calls are no-ops.
    }

    public static void ShowQuotaWarning(string providerName, double usedPercent)
    {
        if (!_supported) return;
        var builder = new AppNotificationBuilder()
            .AddText("CodexBar — Quota Warning")
            .AddText($"{providerName} is at {usedPercent:F0}% of its limit.")
            .AddButton(new AppNotificationButton("Open CodexBar")
                .AddArgument("action", "open"));
        Send(builder);
    }

    public static void ShowLoginRequired(string providerName)
    {
        if (!_supported) return;
        var builder = new AppNotificationBuilder()
            .AddText("CodexBar — Sign In Required")
            .AddText($"{providerName} needs you to sign in again.")
            .AddButton(new AppNotificationButton("Sign In")
                .AddArgument("action", "login")
                .AddArgument("provider", providerName));
        Send(builder);
    }

    private static void Send(AppNotificationBuilder builder)
    {
        if (!_supported) return;
        try
        {
            var notification = builder.BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
            // Toast failures are non-fatal.
        }
    }

    private static void OnNotificationInvoked(
        AppNotificationManager sender,
        AppNotificationActivatedEventArgs args)
    {
        NotificationActivated?.Invoke(null, args);
    }

    public static event EventHandler<AppNotificationActivatedEventArgs>? NotificationActivated;
}
