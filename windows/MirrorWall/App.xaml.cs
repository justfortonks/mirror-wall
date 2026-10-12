using System.Windows;
using System.Windows.Threading;

namespace MirrorWall;

public partial class App : Application
{
    internal SlotStore Store { get; private set; } = null!;

    internal static new App Current => (App)Application.Current;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += Crashed;
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
        Store.PrepareForExit();
        base.OnExit(e);
    }

    /// <summary>Writes what went wrong to the log folder and says where, rather than vanishing.</summary>
    private void Crashed(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        string path = Path.Combine(AppPaths.Logs, "crash.log");
        try
        {
            Directory.CreateDirectory(AppPaths.Logs);
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {e.Exception}\n\n");
        }
        catch (IOException)
        {
        }
        MessageBox.Show($"Mirror Wall hit a problem it didn't expect:\n\n{e.Exception.Message}\n\nDetails are in {path}.",
            "Mirror Wall", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
