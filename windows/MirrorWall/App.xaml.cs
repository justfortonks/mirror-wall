using System.Windows;
using System.Windows.Threading;

namespace MirrorWall;

public partial class App : Application
{
    internal SlotStore? Store { get; private set; }
    internal TrayIcon? Tray { get; private set; }
    /// <summary>Set by <see cref="Quit"/>, so closing the wall then really quits.</summary>
    internal bool Quitting { get; private set; }

    internal static new App Current => (App)Application.Current;

    // Held for as long as this copy runs; Windows lets go of it when the process ends.
    private static Mutex? instanceMutex;
    private const string InstanceMutexName = @"Local\MirrorWall-Running";
    private const string ShowWallEventName = @"Local\MirrorWall-ShowWall";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (!BecomeTheOnlyCopy())
        {
            Shutdown();
            return;
        }
        DispatcherUnhandledException += Crashed;
        // A problem on a background thread (receiving, recording, OBS feed) ends the app; this at
        // least leaves a note of why.
        AppDomain.CurrentDomain.UnhandledException += (_, args) => WriteCrashLog(args.ExceptionObject);
        Native.RunAtFullSpeed();
        Store = new SlotStore();
        Tray = new TrayIcon(Store);
        var window = new MainWindow(Store);
        MainWindow = window;
        // Settings › Wall › Stage › "Open to the Stage": the wall stays tucked away (it's still in
        // the Stage's menus and the notification area icon's), and the Stage opens instead.
        if (!Store.OpensToStage) window.Show();
        Store.StartAll();
        Store.RestoreOwnWindows();
        if (Store.OpensToStage) Store.ShowStage();
        else window.Activate();
    }

    /// <summary>
    /// Only one Mirror Wall can run: a second copy can't open the slots' ports, so every tile would
    /// show an error while the first copy, often hidden behind its notification area icon, carries
    /// on mirroring. Opening Mirror Wall again instead brings back the running copy's wall.
    /// </summary>
    /// <returns>false if another copy is running, which has been asked to show its wall.</returns>
    private static bool BecomeTheOnlyCopy()
    {
        var mutex = new Mutex(false, InstanceMutexName);
        var showWall = new EventWaitHandle(false, EventResetMode.AutoReset, ShowWallEventName);
        bool owned;
        try
        {
            owned = mutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            owned = true; // the last copy ended without letting go
        }
        if (!owned)
        {
            showWall.Set();
            // A copy that's quitting (say, for an update) can't show its wall; take over once it's gone.
            try
            {
                owned = mutex.WaitOne(TimeSpan.FromSeconds(5));
            }
            catch (AbandonedMutexException)
            {
                owned = true;
            }
            if (!owned) return false;
            showWall.Reset();
        }
        instanceMutex = mutex;
        new Thread(() =>
        {
            while (true)
            {
                showWall.WaitOne();
                Current?.Dispatcher.InvokeAsync(MirrorWall.MainWindow.ShowMain);
            }
        }) { Name = "Mirror Wall show wall", IsBackground = true }.Start();
        return true;
    }

    /// <summary>Quits Mirror Wall, even while the notification area icon would otherwise keep it
    /// running with the wall closed.</summary>
    internal void Quit()
    {
        Quitting = true;
        if (MainWindow is { } wall) wall.Close();
        else Shutdown();
    }

    /// <summary>Signing out or shutting down closes the wall for real.</summary>
    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        Quitting = true;
        base.OnSessionEnding(e);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Tray?.Dispose();
        Store?.PrepareForExit();
        base.OnExit(e);
    }

    /// <summary>Writes what went wrong to the log folder and says where, rather than vanishing.</summary>
    private void Crashed(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        string path = WriteCrashLog(e.Exception);
        MessageBox.Show($"Mirror Wall hit a problem it didn't expect:\n\n{e.Exception.Message}\n\nDetails are in {path}.",
            "Mirror Wall", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
        // Nothing to carry on with if it happened while opening.
        if (MainWindow is not { IsLoaded: true }) Shutdown(1);
    }

    private static string WriteCrashLog(object problem)
    {
        string path = Path.Combine(AppPaths.Logs, "crash.log");
        try
        {
            Directory.CreateDirectory(AppPaths.Logs);
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {problem}\n\n");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
        return path;
    }
}
