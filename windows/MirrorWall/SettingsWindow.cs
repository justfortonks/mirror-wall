using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>File › Settings: who can mirror, the standby picture, OBS and own windows, where files
/// are saved, and alerts.</summary>
internal sealed class SettingsWindow : Window
{
    private static SettingsWindow? open;
    private readonly SlotStore store;
    private readonly StackPanel content = new() { Margin = new Thickness(20) };

    public static void Show(Window owner, SlotStore store)
    {
        if (open != null)
        {
            open.Activate();
            return;
        }
        open = new SettingsWindow(store) { Owner = owner };
        open.Closed += (_, _) => open = null;
        open.Show();
    }

    private SettingsWindow(SlotStore store)
    {
        this.store = store;
        Title = "Mirror Wall Settings";
        Width = 520;
        Height = 760;
        MinWidth = 420;
        MinHeight = 400;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = content };
        store.PropertyChanged += StoreChanged;
        Closed += (_, _) => store.PropertyChanged -= StoreChanged;
        Build();
    }

    private void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SlotStore.KnownPhones) or nameof(SlotStore.AllowListEnabled)
            or nameof(SlotStore.AllowedDeviceIds) or nameof(SlotStore.DefaultStandby) or nameof(SlotStore.FlashOnDisconnect)
            or nameof(SlotStore.ObsFeedForAllSlots) or nameof(SlotStore.ReopensOwnWindows))
        {
            Build();
        }
    }

    /// <summary>Rebuilt whenever a setting changes, so every row matches.</summary>
    private void Build()
    {
        content.Children.Clear();

        Header("Who can mirror");
        var onlyTicked = new CheckBox { Content = "Only allow the phones ticked below", IsChecked = store.AllowListEnabled };
        onlyTicked.Click += (_, _) => store.SetAllowListEnabled(onlyTicked.IsChecked == true);
        content.Children.Add(onlyTicked);
        if (store.KnownPhones.Count == 0) Note("Phones appear here once they've mirrored to this PC.", 0.7);
        foreach (var phone in store.KnownPhones) content.Children.Add(PhoneRow(phone));
        Note("Off: any iPhone on your network can mirror to a slot. Changing this restarts the slots, so phones mirroring now will need to reconnect. If a ticked phone can't connect, turn this off, mirror once, and turn it back on.");

        Header("Standby picture");
        var choices = new ComboBox { Width = 200, HorizontalAlignment = HorizontalAlignment.Left };
        choices.Items.Add("Waiting message");
        choices.Items.Add("Blank");
        choices.Items.Add("Image…");
        choices.SelectedIndex = store.DefaultStandby.Kind switch { StandbyKind.Blank => 1, StandbyKind.Image => 2, _ => 0 };
        choices.SelectionChanged += (_, _) =>
        {
            int choice = choices.SelectedIndex;
            // After the list has closed, and rebuilt by the store's change (or put back if no image was picked).
            Dispatcher.BeginInvoke(() =>
            {
                switch (choice)
                {
                    case 0: store.SetDefaultStandby(StandbyPicture.Message); break;
                    case 1: store.SetDefaultStandby(StandbyPicture.Blank); break;
                    default: store.ChooseDefaultStandbyImage(); break;
                }
                Build();
            });
        };
        content.Children.Add(choices);
        if (store.DefaultStandby.Kind == StandbyKind.Image)
        {
            var different = new Button { Content = "Choose a Different Image…", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            different.Click += (_, _) => store.ChooseDefaultStandbyImage();
            content.Children.Add(different);
        }
        Note("What every slot, and its own window, shows while no phone is mirroring. A slot can have its own from its ⋯ menu. Images are scaled to fit, with black bars if the shape differs.");

        Header("OBS and own windows");
        var everySlot = new CheckBox
        {
            Content = "Send every slot to OBS (Spout)",
            IsChecked = store.ObsFeedForAllSlots,
            // Without MirrorSpout.dll (a build without Spout) there's nothing to send with.
            IsEnabled = SpoutFeed.IsAvailable,
        };
        everySlot.Click += (_, _) =>
        {
            bool on = everySlot.IsChecked == true;
            store.SetObsFeedForAllSlots(on);
            if (on) ObsSpoutPlugin.CheckWhenFeedTurnedOn(this);
        };
        content.Children.Add(everySlot);
        var reopen = new CheckBox { Content = "Reopen slots' own windows when Mirror Wall starts", IsChecked = store.ReopensOwnWindows, Margin = new Thickness(0, 8, 0, 0) };
        reopen.Click += (_, _) => store.SetReopensOwnWindows(reopen.IsChecked == true);
        content.Children.Add(reopen);
        Note("Sending to OBS applies to every slot, including ones you add later; a slot's ⋯ menu can still turn its own feed off or on. Own windows that were open when Mirror Wall quit stay closed unless the second switch is on.");

        Header("Save to");
        content.Children.Add(FolderRow("Recordings", Settings.Current.RecordingsFolder, SaveFolders.DefaultRecordings, path => Settings.Current.RecordingsFolder = path));
        content.Children.Add(FolderRow("Screenshots", Settings.Current.ScreenshotsFolder, SaveFolders.DefaultScreenshots, path => Settings.Current.ScreenshotsFolder = path));

        Header("Alerts");
        var flash = new CheckBox { Content = "Flash the taskbar button when a phone disconnects", IsChecked = store.FlashOnDisconnect };
        flash.Click += (_, _) => store.FlashOnDisconnect = flash.IsChecked == true;
        content.Children.Add(flash);
        Note("It keeps flashing until you click Mirror Wall. Windows doesn't flash it while Mirror Wall is the app in front.");
    }

    private UIElement PhoneRow(KnownPhone phone)
    {
        var row = new DockPanel { Margin = new Thickness(24, 8, 0, 0) };
        var forget = new Button { Content = "Forget", Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
        forget.Click += (_, _) => store.Forget(phone);
        DockPanel.SetDock(forget, Dock.Right);
        row.Children.Add(forget);
        var label = new StackPanel();
        label.Children.Add(new TextBlock { Text = phone.Name });
        string model = string.IsNullOrEmpty(phone.Model) ? "iPhone" : PhoneModels.Name(phone.Model);
        label.Children.Add(new TextBlock { Text = $"{model}, last mirrored {Ago(phone.LastSeen)}", FontSize = 11, Opacity = 0.7 });
        var tick = new CheckBox
        {
            Content = label,
            IsChecked = store.AllowedDeviceIds.Contains(phone.DeviceId),
            IsEnabled = store.AllowListEnabled,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        tick.Click += (_, _) => store.SetAllowed(phone, tick.IsChecked == true);
        row.Children.Add(tick);
        return row;
    }

    private UIElement FolderRow(string title, string? chosen, string fallback, Action<string?> save)
    {
        string shown = string.IsNullOrEmpty(chosen) ? fallback : chosen;
        bool missing = !string.IsNullOrEmpty(chosen) && SaveFolders.Usable(chosen, fallback) != chosen;
        var row = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (!string.IsNullOrEmpty(chosen))
        {
            var reset = new Button { Content = "Default", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(0, 0, 6, 0) };
            reset.Click += (_, _) => { save(null); Settings.Current.Save(); Build(); };
            buttons.Children.Add(reset);
        }
        var choose = new Button { Content = "Choose…", Padding = new Thickness(10, 2, 10, 2) };
        choose.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = $"Save {title.ToLowerInvariant()} to", InitialDirectory = shown };
            if (dialog.ShowDialog(this) != true) return;
            save(dialog.FolderName);
            Settings.Current.Save();
            Build();
        };
        buttons.Children.Add(choose);
        DockPanel.SetDock(buttons, Dock.Right);
        row.Children.Add(buttons);
        var label = new StackPanel();
        label.Children.Add(new TextBlock { Text = title });
        label.Children.Add(new TextBlock { Text = shown, FontSize = 11, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = shown });
        if (missing)
        {
            label.Children.Add(new TextBlock { Text = "Not available right now, so saving to the default folder", FontSize = 11, Foreground = Brushes.DarkOrange });
        }
        row.Children.Add(label);
        return row;
    }

    private void Header(string text) =>
        content.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, content.Children.Count == 0 ? 0 : 24, 0, 8),
        });

    private void Note(string text, double opacity = 0.6) =>
        content.Children.Add(new TextBlock { Text = text, FontSize = 11, Opacity = opacity, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });

    /// <summary>"just now", "5 minutes ago", "yesterday", "3 days ago"…</summary>
    private static string Ago(DateTime when)
    {
        var age = DateTime.Now - when.ToLocalTime();
        if (age.TotalMinutes < 1) return "just now";
        if (age.TotalHours < 1) return Plural((int)age.TotalMinutes, "minute");
        if (age.TotalDays < 1) return Plural((int)age.TotalHours, "hour");
        if (age.TotalDays < 2) return "yesterday";
        return age.TotalDays < 60 ? Plural((int)age.TotalDays, "day") : $"on {when.ToLocalTime():d MMM yyyy}";
    }

    private static string Plural(int count, string unit) => $"{count} {unit}{(count == 1 ? "" : "s")} ago";
}
