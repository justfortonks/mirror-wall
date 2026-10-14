using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace MirrorWall;

/// <summary>The few Windows calls .NET doesn't wrap.</summary>
internal static partial class Native
{
    // MARK: Receivers end with the app

    private static IntPtr job;

    /// <summary>
    /// Puts a receiver in a job that Windows closes when Mirror Wall exits, however it exits, so
    /// no uxplay is left behind holding a slot's ports and name (the Mac app looks for leftovers
    /// with pkill instead).
    /// </summary>
    public static void EndWithApp(Process process)
    {
        if (job == IntPtr.Zero)
        {
            job = CreateJobObject(IntPtr.Zero, null);
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            {
                BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE },
            };
            int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        AssignProcessToJobObject(job, process.Handle);
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    // MARK: Keep running at full speed

    /// <summary>
    /// Asks Windows not to slow the app down while its windows are hidden or minimized (Windows
    /// 11's efficiency mode), since other apps such as OBS may be capturing what it draws, and for
    /// a 1 ms timer so Smoother Motion shows frames on time. The Mac app opts out of App Nap.
    /// </summary>
    public static void RunAtFullSpeed()
    {
        var state = new PROCESS_POWER_THROTTLING_STATE
        {
            Version = 1,
            ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
            StateMask = 0,
        };
        SetProcessInformation(Process.GetCurrentProcess().Handle, ProcessPowerThrottling, ref state, (uint)Marshal.SizeOf(state));
        timeBeginPeriod(1);
    }

    private const int ProcessPowerThrottling = 4;
    private const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x1;
    private const uint PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = 0x4;

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_POWER_THROTTLING_STATE
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [DllImport("kernel32.dll")]
    private static extern bool SetProcessInformation(IntPtr process, int infoClass, ref PROCESS_POWER_THROTTLING_STATE info, uint size);

    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint milliseconds);

    // MARK: Taskbar alert

    /// <summary>Flashes the window's taskbar button until it's brought to the front, the way the
    /// Mac app bounces its Dock icon.</summary>
    public static void FlashUntilFocused(IntPtr window)
    {
        if (window == IntPtr.Zero) return;
        var info = new FLASHWINFO
        {
            cbSize = (uint)Marshal.SizeOf<FLASHWINFO>(),
            hwnd = window,
            dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
            uCount = uint.MaxValue,
            dwTimeout = 0,
        };
        FlashWindowEx(ref info);
    }

    private const uint FLASHW_ALL = 3;
    private const uint FLASHW_TIMERNOFG = 12;

    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("user32.dll")]
    private static extern bool FlashWindowEx(ref FLASHWINFO info);

    // MARK: Staying awake

    /// <summary>Keeps the PC and its screen from going to sleep on their own, or lets them again.
    /// Call from the UI thread only: Windows ties the request to the thread that made it.</summary>
    public static void KeepAwake(bool on)
    {
        SetThreadExecutionState(on ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED : ES_CONTINUOUS);
    }

    private const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1, ES_DISPLAY_REQUIRED = 0x2;

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint flags);

    // MARK: Folders

    /// <summary>Opens a folder in File Explorer, creating it if needed.</summary>
    public static void ShowFolder(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch (Exception error) when (error is Win32Exception or IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>Base for objects the windows bind to.</summary>
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Changed([System.Runtime.CompilerServices.CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool Set<T>(ref T field, T value, [System.Runtime.CompilerServices.CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed(name);
        return true;
    }
}
