using System;
using System.Runtime.InteropServices;

namespace CodexBar.Shell.AutoUpdate;

internal static class SparkleUpdater
{
    // WinSparkle uses the registry key HKCU\Software\<CompanyName>\<AppName> to
    // persist the "last checked" timestamp; no additional setup is needed beyond init.
    private const string WinSparkleDll = "WinSparkle.dll";

    [DllImport(WinSparkleDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void win_sparkle_set_appcast_url([MarshalAs(UnmanagedType.LPStr)] string url);

    [DllImport(WinSparkleDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void win_sparkle_init();

    [DllImport(WinSparkleDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void win_sparkle_check_update_with_ui();

    [DllImport(WinSparkleDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void win_sparkle_cleanup();

    public static void Initialize(string appcastUrl)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(appcastUrl);
        win_sparkle_set_appcast_url(appcastUrl);
        win_sparkle_init();
    }

    public static void CheckForUpdates()
    {
        win_sparkle_check_update_with_ui();
    }

    public static void Shutdown()
    {
        win_sparkle_cleanup();
    }
}
