using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace CodexBar.Shell.Notifications;

public static class ToastHelper
{
    private static bool _registered;

    public static void Register()
    {
        if (_registered) return;
        _registered = true;
        AppNotificationManager.Default.Register();
        AppNotificationManager.Default.NotificationInvoked += OnNotificationInvoked;
    }

    public static void ShowQuotaWarning(string providerName, double usedPercent)
    {
        var builder = new AppNotificationBuilder()
            .AddText("CodexBar — Quota Warning")
            .AddText($"{providerName} is at {usedPercent:F0}% of its limit.")
            .AddButton(new AppNotificationButton("Open CodexBar")
                .AddArgument("action", "open"));

        Send(builder);
    }

    public static void ShowLoginRequired(string providerName)
    {
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
        try
        {
            var notification = builder.BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
            // Toast failures are non-fatal; the user still sees data in the flyout.
        }
    }

    private static void OnNotificationInvoked(
        AppNotificationManager sender,
        AppNotificationActivatedEventArgs args)
    {
        // Args are dispatched back to the App for handling (open flyout, open settings, etc.).
        NotificationActivated?.Invoke(null, args);
    }

    public static event EventHandler<AppNotificationActivatedEventArgs>? NotificationActivated;
}
