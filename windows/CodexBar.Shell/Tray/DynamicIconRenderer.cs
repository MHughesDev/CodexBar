using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace CodexBar.Shell.Tray;

public static class DynamicIconRenderer
{
    private const int Size = 32;

    // Cache icon by signature to avoid GDI churn on every poll when usage hasn't changed.
    private static (double fraction, bool stale, Icon icon)? _cached;
    private static (string key, Icon icon)? _mergedCached;

    public static Icon Render(double usageFraction, bool isStale)
    {
        usageFraction = Math.Clamp(usageFraction, 0.0, 1.0);

        if (_cached is { } c && Math.Abs(c.fraction - usageFraction) < 0.005 && c.stale == isStale)
            return c.icon;

        _cached?.icon.Dispose();

        var icon = BuildIcon(usageFraction, isStale);
        _cached = (usageFraction, isStale, icon);
        return icon;
    }

    private static Icon BuildIcon(double usageFraction, bool isStale)
    {
        using var bmp = new Bitmap(Size, Size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        // Background pill
        var bgColor = isStale
            ? Color.FromArgb(200, 80, 80, 80)
            : Color.FromArgb(220, 30, 30, 30);
        using var bgBrush = new SolidBrush(bgColor);
        g.FillRoundedRect(bgBrush, new Rectangle(2, 2, Size - 4, Size - 4), 4);

        // Fill bar (bottom-anchored)
        int barMaxHeight = Size - 8;
        int fillHeight = (int)(barMaxHeight * usageFraction);
        if (fillHeight > 0)
        {
            var fillColor = usageFraction >= 1.0
                ? Color.FromArgb(220, 255, 60, 60)
                : usageFraction >= 0.8
                    ? Color.FromArgb(220, 255, 165, 0)
                    : Color.FromArgb(220, 60, 200, 100);
            using var fillBrush = new SolidBrush(fillColor);
            int y = Size - 4 - fillHeight;
            g.FillRoundedRect(fillBrush, new Rectangle(4, y, Size - 8, fillHeight), 2);
        }

        return Icon.FromHandle(bmp.GetHicon());
    }

    public static Icon RenderMerged(IReadOnlyList<(string name, double fraction)> providers, bool isStale, int size = 32)
    {
        var key = string.Join("|", providers.Select(p => $"{p.fraction:F2}")) + $"|{isStale}|{size}";
        if (_mergedCached is { } mc && mc.key == key) return mc.icon;
        _mergedCached?.icon.Dispose();

        using var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        var bgColor = isStale ? Color.FromArgb(200, 80, 80, 80) : Color.FromArgb(220, 30, 30, 30);
        using var bgBrush = new SolidBrush(bgColor);
        g.FillRoundedRect(bgBrush, new Rectangle(2, 2, size - 4, size - 4), 4);

        var shown = providers.Take(4).ToList();
        if (shown.Count > 0)
        {
            int segmentWidth = (size - 8) / shown.Count;
            int barMaxHeight = size - 8;
            for (int i = 0; i < shown.Count; i++)
            {
                var fraction = Math.Clamp(shown[i].fraction, 0, 1);
                int fillHeight = (int)(barMaxHeight * fraction);
                if (fillHeight <= 0) continue;
                var fillColor = fraction >= 1.0
                    ? Color.FromArgb(220, 255, 60, 60)
                    : fraction >= 0.8
                        ? Color.FromArgb(220, 255, 165, 0)
                        : Color.FromArgb(220, 60, 200, 100);
                using var fillBrush = new SolidBrush(fillColor);
                int x = 4 + i * segmentWidth;
                int y = size - 4 - fillHeight;
                g.FillRoundedRect(fillBrush, new Rectangle(x, y, segmentWidth - 1, fillHeight), 2);
            }
        }

        var icon = Icon.FromHandle(bmp.GetHicon());
        _mergedCached = (key, icon);
        return icon;
    }

    private static void FillRoundedRect(this Graphics g, Brush brush, Rectangle rect, int radius)
    {
        using var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        g.FillPath(brush, path);
    }
}
