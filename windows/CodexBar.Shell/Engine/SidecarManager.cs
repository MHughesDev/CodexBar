using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

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

    public async Task StartAsync(CancellationToken ct = default)
    {
        AuthToken = Guid.NewGuid().ToString();

        var psi = new ProcessStartInfo
        {
            FileName = _enginePath,
            Arguments = $"serve --port 0 --auth-token {AuthToken}",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = false,
            CreateNoWindow = true,
        };

        _process = new Process { StartInfo = psi };
        _process.Start();

        BindToJobObject(_process);

        var firstLine = await _process.StandardOutput.ReadLineAsync(ct);
        if (string.IsNullOrWhiteSpace(firstLine))
            throw new InvalidOperationException("Engine did not emit port announcement on stdout.");

        var announcement = JsonSerializer.Deserialize<ServeReadyDto>(firstLine)
            ?? throw new InvalidOperationException("Engine port announcement was not valid JSON.");

        Port = announcement.Port;
        // Auth token from announcement confirms the engine received our token correctly.
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
