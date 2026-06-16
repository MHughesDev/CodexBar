using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexBar.Shell.Engine;

public sealed class SidecarManager : IDisposable
{
    private static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern nint CreateJobObject(nint lpJobAttributes, string? lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AssignProcessToJobObject(nint hJob, nint hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetInformationJobObject(nint hJob, int jobObjectInfoClass, ref JobObjectExtendedLimitInformation lpJobObjectInfo, int cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(nint hObject);

        [StructLayout(LayoutKind.Sequential)]
        public struct IoCounters
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags, MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public nuint Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        public const int JobObjectExtendedLimitInformationClass = 9;
        public const uint JobObjectLimitKillOnJobClose = 0x2000;
    }

    private Process? _process;
    private nint _jobHandle = nint.Zero;
    private bool _disposed;

    public int Port { get; private set; }
    public string AuthToken { get; private set; } = string.Empty;

    private readonly string _enginePath;

    public SidecarManager(string enginePath)
    {
        _enginePath = enginePath;
    }

    // Port regex matches the stderr line: "CodexBar server listening on http://127.0.0.1:<port>"
    private static readonly System.Text.RegularExpressions.Regex _portRegex =
        new(@"listening on http://127\.0\.0\.1:(\d+)", System.Text.RegularExpressions.RegexOptions.Compiled);

    public async Task StartAsync(CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = _enginePath,
            Arguments = "serve --port 0",
            UseShellExecute = false,
            RedirectStandardOutput = false,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

        _process = new Process { StartInfo = psi };
        _process.Start();

        BindToJobObject(_process);

        // Engine writes: "CodexBar server listening on http://127.0.0.1:<port>" to stderr.
        while (await _process.StandardError.ReadLineAsync(ct) is { } line)
        {
            var match = _portRegex.Match(line);
            if (match.Success)
            {
                Port = int.Parse(match.Groups[1].Value);
                return;
            }
        }

        throw new InvalidOperationException("Engine exited before emitting port announcement on stderr.");
    }

    public void Stop()
    {
        if (_process is { HasExited: false })
        {
            try { _process.Kill(entireProcessTree: true); } catch { /* best-effort */ }
        }
    }

    private void BindToJobObject(Process process)
    {
        _jobHandle = NativeMethods.CreateJobObject(nint.Zero, null);
        if (_jobHandle == nint.Zero) return;

        var info = new NativeMethods.JobObjectExtendedLimitInformation();
        info.BasicLimitInformation.LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose;

        NativeMethods.SetInformationJobObject(
            _jobHandle,
            NativeMethods.JobObjectExtendedLimitInformationClass,
            ref info,
            Marshal.SizeOf<NativeMethods.JobObjectExtendedLimitInformation>());

        NativeMethods.AssignProcessToJobObject(_jobHandle, process.Handle);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        _process?.Dispose();
        if (_jobHandle != nint.Zero)
        {
            NativeMethods.CloseHandle(_jobHandle);
            _jobHandle = nint.Zero;
        }
    }
}
