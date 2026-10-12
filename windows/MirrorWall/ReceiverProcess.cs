using System.Diagnostics;
using System.Text;
using System.Windows.Threading;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// Runs one uxplay process and streams its output lines. The packaged uxplay is patched to write
/// its log unbuffered (windows/receiver/uxplay-windows.patch), so lines arrive as they happen
/// rather than in blocks, which on the Mac left the app many seconds behind.
/// </summary>
internal sealed class ReceiverProcess
{
    private readonly Process process;
    private readonly Dispatcher dispatcher;
    private readonly Action<string> onLine;
    private readonly Action<int> onExit;

    /// <summary>Both callbacks arrive on the UI thread.</summary>
    public ReceiverProcess(string executable, IEnumerable<string> arguments, Action<string> onLine, Action<int> onExit)
    {
        this.onLine = onLine;
        this.onExit = onExit;
        dispatcher = Dispatcher.CurrentDispatcher;
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(executable) ?? "",
        };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);

        var inherited = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(entry => (string)entry.Key, entry => (string?)entry.Value ?? "", StringComparer.OrdinalIgnoreCase);
        Directory.CreateDirectory(AppPaths.Cache);
        var environment = PackagedReceiver.Environment(executable, inherited, Path.Combine(AppPaths.Cache, "gstreamer-registry.bin"), Directory.Exists);
        if (environment != null)
        {
            info.Environment.Clear();
            foreach (var (key, value) in environment) info.Environment[key] = value;
        }

        process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => Received(e.Data);
        process.ErrorDataReceived += (_, e) => Received(e.Data);
        process.Exited += (_, _) =>
        {
            // Let the last output lines arrive first.
            process.WaitForExit();
            int status = process.ExitCode;
            dispatcher.BeginInvoke(() => onExit(status));
        };
    }

    public void Start()
    {
        process.Start();
        Native.EndWithApp(process);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    public bool IsRunning
    {
        get
        {
            try { return !process.HasExited; }
            catch (InvalidOperationException) { return false; }
        }
    }

    /// <summary>Asks uxplay to shut down (it quits when its input closes) without waiting.</summary>
    public void CloseInput()
    {
        if (!IsRunning) return;
        try { process.StandardInput.Close(); }
        catch (IOException) { }
    }

    /// <summary>Asks uxplay to shut down cleanly (by closing its input), then ends it if it hasn't.</summary>
    public void Stop(int waitMilliseconds = 1500)
    {
        if (!IsRunning) return;
        try { process.StandardInput.Close(); }
        catch (IOException) { }
        if (process.WaitForExit(waitMilliseconds)) return;
        try { process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
        process.WaitForExit(1000);
    }

    private void Received(string? line)
    {
        if (string.IsNullOrEmpty(line)) return;
        line = line.TrimEnd('\r');
        dispatcher.BeginInvoke(() => onLine(line));
    }
}

/// <summary>Where the app keeps its files.</summary>
internal static class AppPaths
{
    /// <summary>%APPDATA%\Mirror Wall: settings and standby pictures.</summary>
    public static string Data => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Mirror Wall");

    /// <summary>%LOCALAPPDATA%\Mirror Wall: GStreamer's plugin registry and the slots' logs.</summary>
    public static string Cache => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mirror Wall");

    public static string Logs => Path.Combine(Cache, "Logs");

    /// <summary>The folder MirrorWall.exe is in.</summary>
    public static string App => AppContext.BaseDirectory;
}
