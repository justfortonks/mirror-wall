using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Net;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// The list of slots, their own windows, the uxplay location, and saving all of them. A port of
/// the Mac app's SlotStore. UI thread only.
/// </summary>
internal sealed class SlotStore : Observable
{
    public ObservableCollection<Slot> Slots { get; } = new();
    public const int MaxSlots = 8;

    private readonly Settings settings = Settings.Current;
    private readonly Dictionary<int, PopOutWindow> popOutWindows = new();
    private StageWindow? stageWindow;
    /// <summary>Set while quitting, so windows closing then are still reopened next launch.</summary>
    private bool terminating;

    public SlotStore()
    {
        var configs = settings.Slots ?? Enumerable.Range(1, 2).Select(id => new SlotConfig(id, SlotConfig.DefaultName(id, ComputerName))).ToList();
        // The Stage starts empty unless it's set to remember the phones chosen last time.
        if (settings.StagePhones != StagePhones.Chosen)
        {
            foreach (var config in configs) config.OnStage = null;
        }
        if (!SlotConfig.FrameRates.Contains(settings.MaxFrameRate)) settings.MaxFrameRate = 30;
        foreach (var config in configs.OrderBy(config => config.Id))
        {
            var slot = new Slot(config);
            Watch(slot);
            Slots.Add(slot);
        }
        UxPlayPath = LocateUxPlay(settings.UxPlayPath);
        Save();
        UpdateWindowTitles(); // also starts the OBS feeds that were on
    }

    /// <summary>The PC's name, as set in Settings › System › About (with its own capitals).</summary>
    public static string? ComputerName
    {
        get
        {
            try { return Dns.GetHostName(); }
            catch (System.Net.Sockets.SocketException) { return Environment.MachineName; }
        }
    }

    public string? UxPlayPath { get; private set; }

    public int MaxFrameRate => settings.MaxFrameRate;
    public bool SmoothMotion => settings.SmoothMotion;
    public bool SharpPicture => settings.SharpPicture;
    public PopOutSize PopOutSize => settings.PopOutSize;
    public bool PopOutSizeLocked => settings.PopOutSizeLocked;
    public IReadOnlyList<KnownPhone> KnownPhones => settings.KnownPhones;
    public bool AllowListEnabled => settings.AllowListEnabled;
    public IReadOnlyCollection<string> AllowedDeviceIds => settings.AllowedDevices;
    public StandbyPicture DefaultStandby => settings.DefaultStandby;
    /// <summary>Every slot sends its picture to OBS unless turned off in its own menu. Off by default.</summary>
    public bool ObsFeedForAllSlots => settings.ObsFeedForAllSlots;
    /// <summary>Reopens the slots' own windows that were open when Mirror Wall last quit. Off by default.</summary>
    public bool ReopensOwnWindows => settings.ReopenOwnWindows;
    /// <summary>Every slot shows a phone frame around its picture unless turned off in its own menu. Off by default.</summary>
    public bool BezelsForAllSlots => settings.BezelsForAllSlots;
    /// <summary>Keeps the PC and its screen awake while a phone is mirroring or a slot is recording. On by default.</summary>
    public bool KeepsAwake => settings.KeepAwake;
    /// <summary>Shows Mirror Wall's icon in the notification area, and keeps the app running (and
    /// mirroring) when the wall's window is closed. On by default.</summary>
    public bool ShowsTrayIcon => settings.TrayIcon;
    /// <summary>The app's look. Windows follow <see cref="Theme"/> changes as they happen.</summary>
    public Theme Theme => settings.Theme;
    /// <summary>Open to the Stage at launch, with the wall tucked away. Off by default.</summary>
    public bool OpensToStage => settings.OpenToStage;
    /// <summary>Which phones the Stage shows. None at launch by default.</summary>
    public StagePhones StagePhones => settings.StagePhones;
    /// <summary>The Stage's caption bar, for the current theme.</summary>
    public bool ShowsStageCaption => settings.Theme == Theme.Imprivata ? settings.StageCaptionImprivata : settings.StageCaptionStandard;
    /// <summary>Slots with a phone connected, so a phone only goes on the Stage when it first
    /// connects, and taking it off mid-demo sticks until it reconnects.</summary>
    private readonly HashSet<int> connectedSlotIds = new();

    private bool anySlotInUse;
    /// <summary>True while a phone is connecting, mirroring or has its screen off, or a slot is recording.</summary>
    public bool AnySlotInUse { get => anySlotInUse; private set => Set(ref anySlotInUse, value); }

    public bool ShowStats
    {
        get => settings.ShowStats;
        set
        {
            if (settings.ShowStats == value) return;
            settings.ShowStats = value;
            settings.Save();
            Changed();
        }
    }

    public bool FlashOnDisconnect
    {
        get => settings.FlashOnDisconnect;
        set
        {
            settings.FlashOnDisconnect = value;
            settings.Save();
            Changed();
        }
    }

    /// <summary>Saves a slot's config when it learns a new phone's name, and retitles windows to match.</summary>
    private void Watch(Slot slot)
    {
        slot.MaxFrameRate = settings.MaxFrameRate;
        slot.Renderer.SmoothMotion = settings.SmoothMotion;
        slot.SharpPicture = settings.SharpPicture;
        slot.AllowedDevices = AllowedDevices;
        slot.ShowsBezel = slot.Config.Bezel ?? settings.BezelsForAllSlots;
        slot.OnConfigChanged = () =>
        {
            Save();
            UpdateWindowTitles();
        };
        slot.OnPhoneSeen = Remember;
        slot.OnPhoneDropped = AlertPhoneDropped;
        slot.PropertyChanged += SlotChanged;
    }

    /// <summary>Sends the standby picture to OBS when the phone leaves.</summary>
    private void SlotChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(Slot.State) or nameof(Slot.RecordingSince)) UpdateKeepAwake();
        if (sender is Slot connecting && e.PropertyName is nameof(Slot.State)) PutOnStageIfNew(connecting);
        if (sender is Slot slot && e.PropertyName is nameof(Slot.State) or nameof(Slot.HasPicture))
        {
            // After the change has settled, as the Mac app does.
            Application.Current.Dispatcher.BeginInvoke(() => SendStandbyToObs(slot));
        }
    }

    /// <summary>With Settings › Wall › Stage › Phones on the Stage set to every phone, a phone that
    /// connects goes on the Stage. It can still be taken off from the Stage's control bar; that holds until the phone
    /// disconnects and connects again.</summary>
    private void PutOnStageIfNew(Slot slot)
    {
        bool connected = slot.State is SlotState.Connecting or SlotState.Live or SlotState.Paused;
        if (!connected)
        {
            connectedSlotIds.Remove(slot.Id);
            return;
        }
        if (!connectedSlotIds.Add(slot.Id)) return;
        if (settings.StagePhones == StagePhones.All && !slot.ShowsOnStage) SetShowsOnStage(slot, true);
    }

    // MARK: Allow-list and alerts

    /// <summary>The device IDs receivers are restricted to, or null when any phone may connect.</summary>
    private IReadOnlyList<string>? AllowedDevices =>
        settings.AllowListEnabled ? settings.AllowedDevices.OrderBy(id => id, StringComparer.Ordinal).ToList() : null;

    private void Remember(KnownPhone phone)
    {
        settings.KnownPhones.RemoveAll(known => known.DeviceId == phone.DeviceId);
        settings.KnownPhones.Insert(0, phone);
        settings.Save();
        Changed(nameof(KnownPhones));
    }

    public void Forget(KnownPhone phone)
    {
        settings.KnownPhones.RemoveAll(known => known.DeviceId == phone.DeviceId);
        settings.Save();
        Changed(nameof(KnownPhones));
        SetAllowed(phone, false);
    }

    /// <summary>Turning the allow-list on starts with every known phone ticked, so nobody is locked
    /// out by surprise.</summary>
    public void SetAllowListEnabled(bool enabled)
    {
        if (enabled == settings.AllowListEnabled) return;
        if (enabled && settings.AllowedDevices.Count == 0) settings.AllowedDevices = settings.KnownPhones.Select(phone => phone.DeviceId).ToList();
        settings.AllowListEnabled = enabled;
        settings.Save();
        Changed(nameof(AllowListEnabled));
        Changed(nameof(AllowedDeviceIds));
        ApplyAllowList();
    }

    public void SetAllowed(KnownPhone phone, bool allowed)
    {
        bool has = settings.AllowedDevices.Contains(phone.DeviceId);
        if (has == allowed) return;
        if (allowed) settings.AllowedDevices.Add(phone.DeviceId);
        else settings.AllowedDevices.Remove(phone.DeviceId);
        settings.Save();
        Changed(nameof(AllowedDeviceIds));
        if (settings.AllowListEnabled) ApplyAllowList();
    }

    /// <summary>Receivers read the allow-list when they start, so each one restarts.</summary>
    private void ApplyAllowList()
    {
        foreach (var slot in Slots)
        {
            slot.AllowedDevices = AllowedDevices;
            Restart(slot);
        }
    }

    /// <summary>Flashes the taskbar button until Mirror Wall is clicked (Windows doesn't while
    /// it's in front).</summary>
    private void AlertPhoneDropped()
    {
        if (!settings.FlashOnDisconnect || Application.Current.MainWindow is not { } window) return;
        Native.FlashUntilFocused(new System.Windows.Interop.WindowInteropHelper(window).Handle);
    }

    // MARK: uxplay

    /// <summary>Where to look for uxplay: the one installed with Mirror Wall first (it brings its
    /// own GStreamer, so it works on any PC), then any the user picked, then MSYS2's usual place.</summary>
    public static IEnumerable<string> CandidatePaths(string? savedPath)
    {
        yield return Path.Combine(AppPaths.App, "receiver", PackagedReceiver.ExecutableName);
        if (!string.IsNullOrEmpty(savedPath)) yield return savedPath;
        yield return @"C:\msys64\ucrt64\bin\uxplay.exe";
    }

    public static string? LocateUxPlay(string? savedPath) => CandidatePaths(savedPath).FirstOrDefault(File.Exists);

    public void ChooseUxPlay()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Choose the uxplay program",
            Filter = "uxplay|uxplay.exe|Programs|*.exe",
        };
        if (dialog.ShowDialog() != true) return;
        settings.UxPlayPath = dialog.FileName;
        settings.Save();
        UxPlayPath = dialog.FileName;
        Changed(nameof(UxPlayPath));
        StopAll();
        StartAll();
    }

    // MARK: Slots

    public void StartAll()
    {
        if (UxPlayPath == null) return;
        foreach (var slot in Slots) slot.Start(UxPlayPath);
    }

    public void StopAll()
    {
        foreach (var slot in Slots) slot.Stop();
    }

    public bool IsAnyRecording => Slots.Any(slot => slot.RecordingSince != null);

    public void StartAllRecordings()
    {
        foreach (var slot in Slots) slot.StartRecording();
    }

    public void StopAllRecordings()
    {
        foreach (var slot in Slots) slot.StopRecording();
    }

    public bool CanAddSlot => Slots.Count < MaxSlots && UxPlayPath != null;

    public void AddSlot()
    {
        if (!CanAddSlot) return;
        var used = Slots.Select(slot => slot.Id).ToHashSet();
        int id = Enumerable.Range(1, MaxSlots).First(candidate => !used.Contains(candidate));
        var slot = new Slot(new SlotConfig(id, SlotConfig.DefaultName(id, ComputerName)));
        Watch(slot);
        int index = Slots.TakeWhile(existing => existing.Id < id).Count();
        Slots.Insert(index, slot);
        if (UxPlayPath != null) slot.Start(UxPlayPath);
        Save();
        UpdateWindowTitles();
        Changed(nameof(CanAddSlot));
        UpdateKeepAwake();
    }

    public void Remove(Slot slot)
    {
        CloseOwnWindow(slot);
        slot.SetObsFeed(false, "");
        slot.Shutdown();
        slot.PropertyChanged -= SlotChanged;
        connectedSlotIds.Remove(slot.Id);
        StandbyPictures.Discard(slot.Config.Standby);
        Slots.Remove(slot);
        settings.PopOutCustomLongSides.Remove(slot.Id);
        settings.PopOutPositions.Remove(slot.Id);
        Save();
        UpdateWindowTitles();
        Changed(nameof(CanAddSlot));
    }

    /// <summary>Changes the frame rate phones are asked for. Each receiver restarts to apply it, so
    /// phones mirroring now have to reconnect.</summary>
    public void SetMaxFrameRate(int rate)
    {
        if (rate == settings.MaxFrameRate || !SlotConfig.FrameRates.Contains(rate)) return;
        settings.MaxFrameRate = rate;
        settings.Save();
        Changed(nameof(MaxFrameRate));
        foreach (var slot in Slots)
        {
            slot.MaxFrameRate = rate;
            Restart(slot);
        }
    }

    /// <summary>Turns Smoother Motion on or off for every slot. Takes effect at once; nothing restarts.</summary>
    public void SetSmoothMotion(bool on)
    {
        if (on == settings.SmoothMotion) return;
        settings.SmoothMotion = on;
        settings.Save();
        Changed(nameof(SmoothMotion));
        foreach (var slot in Slots) slot.Renderer.SmoothMotion = on;
    }

    /// <summary>Turns the sharper picture on or off. Each receiver restarts to apply it, so phones
    /// mirroring now have to reconnect.</summary>
    public void SetSharpPicture(bool on)
    {
        if (on == settings.SharpPicture) return;
        settings.SharpPicture = on;
        settings.Save();
        Changed(nameof(SharpPicture));
        foreach (var slot in Slots)
        {
            slot.SharpPicture = on;
            Restart(slot);
        }
    }

    public void Restart(Slot slot)
    {
        if (UxPlayPath != null) slot.Restart(UxPlayPath);
    }

    public void Rename(Slot slot, string name)
    {
        string tidy = SlotConfig.TidyName(name);
        if (tidy.Length == 0 || tidy == slot.Name) return;
        slot.Rename(tidy, UxPlayPath);
        Save();
        UpdateWindowTitles();
    }

    public void ResetName(Slot slot) => Rename(slot, SlotConfig.DefaultName(slot.Id, ComputerName));

    // MARK: Standby pictures and screenshots

    public void SetStandby(Slot slot, StandbyPicture? standby)
    {
        var old = slot.Config.Standby;
        if (standby == old) return;
        slot.SetStandby(standby);
        StandbyPictures.Discard(old);
        Save();
        SendStandbyToObs(slot);
    }

    public void ChooseStandbyImage(Slot slot)
    {
        if (StandbyPictures.Choose($"slot-{slot.Id}") is { } picture) SetStandby(slot, picture);
    }

    /// <summary>What <paramref name="slot"/> shows while no phone is mirroring: its own choice, or the one for all slots.</summary>
    public StandbyPicture StandbyFor(Slot slot) => slot.Config.Standby ?? settings.DefaultStandby;

    public void SetDefaultStandby(StandbyPicture standby)
    {
        var old = settings.DefaultStandby;
        if (standby == old) return;
        settings.DefaultStandby = standby;
        settings.Save();
        StandbyPictures.Discard(old);
        Changed(nameof(DefaultStandby));
        foreach (var slot in Slots) SendStandbyToObs(slot);
    }

    public void ChooseDefaultStandbyImage()
    {
        if (StandbyPictures.Choose("all-slots") is { } picture) SetDefaultStandby(picture);
    }

    public void ScreenshotAll()
    {
        foreach (var slot in Slots) slot.TakeScreenshot();
    }

    // MARK: Own windows

    public bool IsPoppedOut(Slot slot) => popOutWindows.ContainsKey(slot.Id);

    public void SetPopOutSize(PopOutSize size)
    {
        if (size == settings.PopOutSize) return;
        settings.PopOutSize = size;
        settings.Save();
        Changed(nameof(PopOutSize));
        foreach (var window in popOutWindows.Values) window.Fit();
    }

    public void SetPopOutSizeLocked(bool locked)
    {
        if (locked == settings.PopOutSizeLocked) return;
        settings.PopOutSizeLocked = locked;
        settings.Save();
        Changed(nameof(PopOutSizeLocked));
        foreach (var window in popOutWindows.Values) window.UpdateResizable();
    }

    /// <summary>Each slot's own Custom size: its window's longer side.</summary>
    public double? CustomLongSide(Slot slot) => settings.PopOutCustomLongSides.TryGetValue(slot.Id, out double side) ? side : null;

    public void SetCustomLongSide(Slot slot, double side)
    {
        settings.PopOutCustomLongSides[slot.Id] = side;
        settings.Save();
    }

    public double[]? PopOutPosition(Slot slot) => settings.PopOutPositions.TryGetValue(slot.Id, out var place) ? place : null;

    /// <summary>Remembers where a slot's window is; saved to disk once <paramref name="save"/> (after a move ends).</summary>
    public void SetPopOutPosition(Slot slot, double left, double top, bool save)
    {
        settings.PopOutPositions[slot.Id] = new[] { left, top };
        if (save && !terminating) settings.Save();
    }

    public void OpenOwnWindow(Slot slot)
    {
        if (popOutWindows.TryGetValue(slot.Id, out var existing))
        {
            existing.Activate();
            return;
        }
        string title = WindowTitles.GetValueOrDefault(slot.Id, $"MacMirror-{slot.Name}");
        var window = new PopOutWindow(slot, this, title);
        int id = slot.Id;
        window.Closed += (_, _) => OwnWindowClosed(id);
        popOutWindows[id] = window;
        window.Show();
        SavePoppedOut();
        Changed(nameof(IsPoppedOut));
    }

    // MARK: Stage

    public StageLayout StageLayout => settings.StageLayout;

    public void ShowStage()
    {
        if (stageWindow == null)
        {
            stageWindow = new StageWindow(this);
            stageWindow.Closed += (_, _) =>
            {
                stageWindow = null;
                // Opened to the Stage with no notification area icon: closing the Stage mustn't
                // leave Mirror Wall running with nothing on screen to get back to it from.
                if (!ShowsTrayIcon && !App.Current.Quitting && Application.Current.MainWindow is { IsVisible: false })
                {
                    MainWindow.ShowMain();
                }
            };
            stageWindow.Show();
        }
        if (stageWindow.WindowState == WindowState.Minimized) stageWindow.WindowState = WindowState.Normal;
        stageWindow.Activate();
    }

    public void SetShowsOnStage(Slot slot, bool on)
    {
        slot.SetShowsOnStage(on);
        Save();
    }

    public void SetStageLayout(StageLayout layout)
    {
        if (layout == settings.StageLayout) return;
        settings.StageLayout = layout;
        settings.Save();
        Changed(nameof(StageLayout));
    }

    public void CloseOwnWindow(Slot slot)
    {
        if (popOutWindows.TryGetValue(slot.Id, out var window)) window.Close();
    }

    /// <summary>Reopens the windows that were open when the app last quit, if that's turned on.</summary>
    public void RestoreOwnWindows()
    {
        if (!settings.ReopenOwnWindows) return;
        var ids = settings.PoppedOut.ToHashSet();
        foreach (var slot in Slots.Where(slot => ids.Contains(slot.Id)).ToList()) OpenOwnWindow(slot);
    }

    /// <summary>Called as the wall closes, before Windows closes the slots' own windows, so they
    /// are still reopened next launch.</summary>
    public void BeginExit()
    {
        terminating = true;
        settings.Save();
    }

    public void PrepareForExit()
    {
        BeginExit();
        // Every receiver is asked to quit first, so they shut down together rather than in turn.
        foreach (var slot in Slots) slot.AskReceiverToQuit();
        foreach (var slot in Slots) slot.Shutdown();
        DnsServiceAdvertiser.WaitForWithdrawals(TimeSpan.FromSeconds(1.5));
    }

    private Dictionary<int, string> WindowTitles => SlotConfig.WindowTitles(Slots.Select(slot => slot.Config));

    /// <summary>Keeps the slots' own windows and OBS feeds named after their phones. A feed goes by
    /// the same name as the window, so an OBS scene can switch between the two without renaming.</summary>
    private void UpdateWindowTitles()
    {
        var titles = WindowTitles;
        foreach (var (id, window) in popOutWindows)
        {
            if (titles.TryGetValue(id, out var title) && window.Title != title) window.Title = title;
        }
        foreach (var slot in Slots.Where(WantsObsFeed))
        {
            if (titles.TryGetValue(slot.Id, out var title) && slot.ObsFeedName != title)
            {
                slot.SetObsFeed(true, title);
                SendStandbyToObs(slot);
            }
        }
    }

    /// <summary>Whether a slot should send to OBS: its own choice, or the setting for all slots.</summary>
    private bool WantsObsFeed(Slot slot) => slot.Config.ObsFeed ?? settings.ObsFeedForAllSlots;

    /// <summary>Turns a slot's OBS feed (Spout) on or off. Remembered per slot, as a choice of its
    /// own only when it differs from the setting for all slots.</summary>
    public void SetObsFeed(Slot slot, bool on)
    {
        bool started = slot.SetObsFeed(on, WindowTitles.GetValueOrDefault(slot.Id, $"MacMirror-{slot.Name}"));
        slot.RememberObsFeed(started && on != settings.ObsFeedForAllSlots ? (bool?)on : null);
        Save();
        SendStandbyToObs(slot);
    }

    /// <summary>Turns every slot's OBS feed on or off, including slots added later. A slot's own
    /// menu can still change it afterwards.</summary>
    public void SetObsFeedForAllSlots(bool on)
    {
        if (on == settings.ObsFeedForAllSlots) return;
        settings.ObsFeedForAllSlots = on;
        var titles = WindowTitles;
        foreach (var slot in Slots)
        {
            slot.RememberObsFeed(null);
            slot.SetObsFeed(on, titles.GetValueOrDefault(slot.Id, $"MacMirror-{slot.Name}"));
            SendStandbyToObs(slot);
        }
        Save();
        Changed(nameof(ObsFeedForAllSlots));
    }

    public void SetReopensOwnWindows(bool on)
    {
        if (on == settings.ReopenOwnWindows) return;
        settings.ReopenOwnWindows = on;
        settings.Save();
        Changed(nameof(ReopensOwnWindows));
    }

    // MARK: Phone bezels

    /// <summary>Turns a slot's phone frame on or off. Remembered per slot, unless it matches the
    /// setting for all slots.</summary>
    public void SetBezel(Slot slot, bool on)
    {
        slot.RememberBezel(on == settings.BezelsForAllSlots ? null : on);
        slot.ShowsBezel = on;
        Save();
    }

    /// <summary>Turns every slot's phone frame on or off, including slots added later. A slot's own
    /// menu can still change it afterwards.</summary>
    public void SetBezelsForAllSlots(bool on)
    {
        if (on == settings.BezelsForAllSlots) return;
        settings.BezelsForAllSlots = on;
        foreach (var slot in Slots)
        {
            slot.RememberBezel(null);
            slot.ShowsBezel = on;
        }
        Save();
        Changed(nameof(BezelsForAllSlots));
    }

    /// <summary>Puts the phone frame around a slot's OBS feed, or takes it off. Remembered per slot.</summary>
    public void SetFramesObsFeed(Slot slot, bool on)
    {
        slot.SetFramesObsFeed(on);
        Save();
        SendStandbyToObs(slot);
    }

    // MARK: Keeping the PC awake, and the tray icon

    public void SetKeepsAwake(bool on)
    {
        if (on == settings.KeepAwake) return;
        settings.KeepAwake = on;
        settings.Save();
        Changed(nameof(KeepsAwake));
        UpdateKeepAwake();
    }

    /// <summary>Stops the PC (and its screen) going to sleep on its own while a slot is in use, and
    /// lets it again once none is. Choosing Sleep or closing a laptop's lid still works.</summary>
    private void UpdateKeepAwake()
    {
        AnySlotInUse = Slots.Any(slot => slot.RecordingSince != null || slot.State is SlotState.Connecting or SlotState.Live or SlotState.Paused);
        Native.KeepAwake(settings.KeepAwake && AnySlotInUse);
    }

    public void SetShowsTrayIcon(bool on)
    {
        if (on == settings.TrayIcon) return;
        settings.TrayIcon = on;
        settings.Save();
        Changed(nameof(ShowsTrayIcon));
    }

    public void SetTheme(Theme theme)
    {
        if (theme == settings.Theme) return;
        settings.Theme = theme;
        settings.Save();
        Themes.Apply(theme);
        Changed(nameof(Theme));
        Changed(nameof(ShowsStageCaption));
    }

    public void SetOpensToStage(bool on)
    {
        if (on == settings.OpenToStage) return;
        settings.OpenToStage = on;
        settings.Save();
        Changed(nameof(OpensToStage));
    }

    public void SetStagePhones(StagePhones choice)
    {
        if (choice == settings.StagePhones) return;
        settings.StagePhones = choice;
        settings.Save();
        Changed(nameof(StagePhones));
    }

    public void SetShowsStageCaption(bool on)
    {
        if (settings.Theme == Theme.Imprivata) settings.StageCaptionImprivata = on; else settings.StageCaptionStandard = on;
        settings.Save();
        Changed(nameof(ShowsStageCaption));
    }

    /// <summary>
    /// While no phone is mirroring, sends the slot's standby picture down its OBS feed, drawn as its
    /// own window draws it and at the size of the phone's last picture (an iPhone-shaped 1179×2556
    /// before any phone has connected). Live pictures replace it when a phone returns.
    /// </summary>
    public void SendStandbyToObs(Slot slot)
    {
        if (!slot.SendsToObs || slot.ShowsPicture) return;
        var size = slot.LastPictureSize ?? new Size(1179, 2556);
        int width = (int)size.Width, height = (int)size.Height;
        // Laid out at a third of the size and drawn 3× (288 dpi), so the waiting message is about as
        // big relative to the picture as in the slot's own window.
        var content = new System.Windows.Controls.Grid { Width = width / 3.0, Height = height / 3.0, Background = Brushes.Black };
        content.Children.Add(StandbyView.Make(StandbyFor(slot), slot));
        content.Measure(new Size(content.Width, content.Height));
        content.Arrange(new Rect(0, 0, content.Width, content.Height));
        content.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width, height, 288, 288, PixelFormats.Pbgra32);
        bitmap.Render(content);
        var picture = new Picture(width, height, null);
        bitmap.CopyPixels(picture.Pixels, picture.Stride, 0);
        slot.SendToObs(picture);
        picture.Release();
    }

    private void OwnWindowClosed(int id)
    {
        popOutWindows.Remove(id);
        if (!terminating) SavePoppedOut();
        Changed(nameof(IsPoppedOut));
    }

    private void SavePoppedOut()
    {
        settings.PoppedOut = popOutWindows.Keys.OrderBy(id => id).ToList();
        settings.Save();
    }

    private void Save()
    {
        settings.Slots = Slots.Select(slot => slot.Config).ToList();
        settings.Save();
    }
}
