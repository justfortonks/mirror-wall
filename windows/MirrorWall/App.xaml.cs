using System.Windows;
using System.Windows.Threading;

namespace MirrorWall;

public partial class App : Application
{
    internal SlotStore? Store { get; private set; }

    internal static new App Current => (App)Application.Current;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += Crashed;
        // A problem on a background thread (receiving, recording, OBS feed) ends the app; this at
        // least leaves a note of why.
        AppDomain.CurrentDomain.UnhandledException += (_, args) => WriteCrashLog(args.ExceptionObject);
        Native.RunAtFullSpeed();
        Store = new SlotStore();
        var window = new MainWindow(Store);
        MainWindow = window;
        window.Show();
        Store.StartAll();
        Store.RestoreOwnWindows();
        window.Activate();
    }

    protected override void OnExit(ExitEventArgs e)
    {
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
