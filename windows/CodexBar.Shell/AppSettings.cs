using System.Text.Json;

namespace CodexBar.Shell;

record AppSettings(
    bool ShowLabels = false,
    bool ShowUsageBars = true,
    bool ShowResetCountdown = true,
    bool MergeIconsMode = false,
    bool HighlightHighestUsage = true,
    int RefreshIntervalSeconds = 60)
{
    static string FilePath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codexbar", "shell-settings.json");

    public static AppSettings Load()
    {
        try
        {
            var path = FilePath;
            if (!File.Exists(path)) return new AppSettings();
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public void Save()
    {
        try
        {
            var path = FilePath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* best-effort */ }
    }
}
