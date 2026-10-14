using System.ComponentModel;
using System.Windows;
using MirrorWall.Core;
using Forms = System.Windows.Forms;

namespace MirrorWall;

/// <summary>
/// Mirror Wall's icon in the notification area (the Mac app's menu bar icon): its menu lists every
/// slot and how it's doing, with ways back to the wall. While it's shown, closing the wall only
/// hides it, so phones keep mirroring to their own windows and OBS.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly SlotStore store;
    private readonly Forms.NotifyIcon icon = new() { Text = "Mirror Wall" };
    private bool toldAboutHiding;

    public TrayIcon(SlotStore store)
    {
        this.store = store;
        try
        {
            if (Environment.ProcessPath is string path) icon.Icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
        }
        catch (Exception error) when (error is ArgumentException or IOException)
        {
        }
        icon.Icon ??= System.Drawing.SystemIcons.Application;
        icon.ContextMenuStrip = new Forms.ContextMenuStrip();
        icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) MainWindow.ShowMain();
        };
        icon.Visible = store.ShowsTrayIcon;
        store.PropertyChanged += StoreChanged;
    }

    private void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SlotStore.ShowsTrayIcon)) icon.Visible = store.ShowsTrayIcon;
    }

    /// <summary>Says once that Mirror Wall is still running after its window was closed.</summary>
    public void TellAboutHiding()
    {
        if (toldAboutHiding) return;
        toldAboutHiding = true;
        icon.ShowBalloonTip(5000, "Mirror Wall is still running",
            "Phones keep mirroring. Click this icon to bring the wall back, or right-click it to exit.", Forms.ToolTipIcon.None);
    }

    private void BuildMenu()
    {
        var menu = icon.ContextMenuStrip!;
        menu.Items.Clear();
        foreach (var slot in store.Slots.ToList())
        {
            menu.Items.Add($"{Dot(slot.State)} {slot.Name}: {Status(slot)}", null, (_, _) => Later(() => store.OpenOwnWindow(slot)));
        }
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Show Mirror Wall Window", null, (_, _) => Later(MainWindow.ShowMain));
        if (store.IsAnyRecording)
            menu.Items.Add("Stop All Recordings", null, (_, _) => Later(store.StopAllRecordings));
        else
            menu.Items.Add("Record All Slots", null, (_, _) => Later(store.StartAllRecordings));
        menu.Items.Add("Settings…", null, (_, _) => Later(() =>
        {
            MainWindow.ShowMain();
            if (Application.Current.MainWindow is Window wall) SettingsWindow.Show(wall, store);
        }));
        menu.Items.Add("Check for Update…", null, (_, _) => Later(() => Updater.Check(Application.Current.MainWindow)));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit Mirror Wall", null, (_, _) => Later(App.Current.Quit));
    }

    /// <summary>After the menu has closed, as the app's other menus do.</summary>
    private static void Later(Action action) => Application.Current.Dispatcher.BeginInvoke(action);

    private static string Dot(SlotState state) => state switch
    {
        SlotState.Live => "🟢",
        SlotState.Waiting or SlotState.Connecting or SlotState.Paused => "🟡",
        SlotState.Disconnected => "🟠",
        SlotState.Stopped => "⚪",
        _ => "🔴",
    };

    /// <summary>"Live, Tom's iPhone, recording", "Waiting"…</summary>
    private static string Status(Slot slot)
    {
        string phone = slot.PhoneName is string name ? $", {name}" : "";
        string recording = slot.RecordingSince != null ? ", recording" : "";
        return slot.State switch
        {
            SlotState.Stopped => "Stopped",
            SlotState.Failed => "Error",
            SlotState.Waiting => "Waiting",
            SlotState.Connecting => "Connecting" + phone,
            SlotState.Disconnected => "Disconnected",
            SlotState.Paused => "Screen off" + phone + recording,
            _ => "Live" + phone + recording,
        };
    }

    public void Dispose()
    {
        store.PropertyChanged -= StoreChanged;
        icon.Visible = false;
        icon.Dispose();
    }
}
