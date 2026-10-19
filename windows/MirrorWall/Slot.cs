using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Threading;
using MirrorWall.Core;

namespace MirrorWall;

public enum SlotState
{
    Stopped,
    /// <summary>Receiver running, no phone attached.</summary>
    Waiting,
    /// <summary>A phone is connecting; no picture yet.</summary>
    Connecting,
    Live,
    /// <summary>The phone paused its stream, usually because its screen locked.</summary>
    Paused,
    /// <summary>The phone stopped mirroring; it has to reconnect from Screen Mirroring.</summary>
    Disconnected,
    Failed,
}

/// <summary>
/// A running mirroring slot: its uxplay process, the RTP stream it forwards, and the renderer.
/// A port of the Mac app's Slot. Properties change on the UI thread only.
/// </summary>
internal sealed class Slot : Observable
{
    public SlotConfig Config { get; private set; }
    public int Id => Config.Id;
    public string Name => Config.Name;

    private SlotState state = SlotState.Stopped;
    public SlotState State
    {
        get => state;
        private set
        {
            if (value == state) return;
            state = value;
            StateSince = DateTime.Now;
            Changed();
            Changed(nameof(StateSince));
            Changed(nameof(ShowsPicture));
            if (spoutFeed != null) spoutFeed.PassesFrames = CarriesPhoneFrames;
            UpdateListing();
        }
    }
    /// <summary>Why the slot failed, while <see cref="State"/> is Failed.</summary>
    public string? FailureMessage { get; private set; }

    /// <summary>True while a phone is (or is about to be) mirroring, so its frames belong in the OBS feed.</summary>
    private bool CarriesPhoneFrames => State is SlotState.Connecting or SlotState.Live or SlotState.Paused;

    /// <summary>When the current state began, e.g. how long the screen has been off.</summary>
    public DateTime StateSince { get; private set; } = DateTime.Now;

    private DateTime? connectedSince;
    /// <summary>When the current phone connected; null when none is.</summary>
    public DateTime? ConnectedSince { get => connectedSince; private set => Set(ref connectedSince, value); }

    /// <summary>When the last picture arrived; null until the first one. Not announced on every
    /// change: views that show it re-read it on their one-second timer.</summary>
    public DateTime? LastFrameAt { get; private set; }

    private bool hasPicture;
    /// <summary>True once a picture has arrived, until the slot stops.</summary>
    public bool HasPicture
    {
        get => hasPicture;
        private set { if (Set(ref hasPicture, value)) Changed(nameof(ShowsPicture)); }
    }

    private Size? videoSize;
    /// <summary>Picture size in pixels, for the tile's shape.</summary>
    public Size? VideoSize { get => videoSize; private set => Set(ref videoSize, value); }

    /// <summary>The last picture size seen, kept after the phone leaves, for sizing the OBS feed's
    /// standby picture like the phone's.</summary>
    public Size? LastPictureSize { get; private set; }

    /// <summary>The receiver's recent output, for the log window.</summary>
    public ObservableCollection<string> Log { get; } = new();

    private string? phoneName;
    /// <summary>The connected phone's name, as it introduced itself to uxplay.</summary>
    public string? PhoneName { get => phoneName; private set => Set(ref phoneName, value); }

    private DateTime? recordingSince;
    /// <summary>When recording started; null when not recording.</summary>
    public DateTime? RecordingSince { get => recordingSince; private set => Set(ref recordingSince, value); }

    private string? recordingError;
    /// <summary>The last recording error, shown in the tile until recording restarts.</summary>
    public string? RecordingError { get => recordingError; private set => Set(ref recordingError, value); }

    /// <summary>When the last screenshot was saved, for a moment's confirmation in the tile.</summary>
    public DateTime? ScreenshotSavedAt { get; private set; }

    public SlotRenderer Renderer { get; } = new();
    /// <summary>The slot's OBS feed, while it's on.</summary>
    private SpoutFeed? spoutFeed;
    /// <summary>The most frames a second phones are asked to send; takes effect when the receiver starts.</summary>
    public int MaxFrameRate { get; set; } = 30;
    /// <summary>Offers phones H.265 for a sharper picture; takes effect when the receiver starts.</summary>
    public bool SharpPicture { get; set; }
    /// <summary>Numbers for the Stats for Nerds overlay.</summary>
    public SlotStats Stats { get; } = new();
    /// <summary>Called when the config changes on its own (a new phone's name), so it can be saved.</summary>
    public Action? OnConfigChanged { get; set; }
    /// <summary>Only phones with these device IDs may connect, or any phone if null. Takes effect
    /// when the receiver starts.</summary>
    public IReadOnlyList<string>? AllowedDevices { get; set; }
    /// <summary>Called when a phone asks to connect, so the store can remember it for the allow-list.</summary>
    public Action<KnownPhone>? OnPhoneSeen { get; set; }
    /// <summary>Called when a mirroring phone drops unexpectedly (not when the slot is stopped).</summary>
    public Action? OnPhoneDropped { get; set; }

    private ReceiverProcess? process;
    /// <summary>Used on the UDP thread and the UI thread, so guarded by `recorderGate`.</summary>
    private SlotRecorder? recorder;
    private readonly object recorderGate = new();
    private UdpReceiver? receiver;
    /// <summary>Listens for Android phones (Mirror Wall Cast) while the slot runs.</summary>
    private CastServer? castServer;
    /// <summary>Lists the slot for the Android app. Kept across receiver restarts, so restarting
    /// doesn't withdraw the name and list it again.</summary>
    private DnsServiceAdvertiser? listing;
    private string? listingName;
    /// <summary>The Android phone that has the slot, if any. While one does, the slot's uxplay is
    /// stopped so iPhones don't list it.</summary>
    private CastConnection? castPhone;
    /// <summary>When the phone last paused its stream. A locked phone can still send a frame or two
    /// (its lock screen), so frames only count as a resume once they keep coming after this.</summary>
    private DateTime? pausedAt;
    private StreamWriter? logFile;
    /// <summary>When the phone last checked in or sent video. A phone on a charger, its screen off,
    /// can go quiet without ending the session, and uxplay never notices; the watchdog does.</summary>
    private DateTime? lastSignOfLifeAt;
    /// <summary>The uxplay this slot runs, kept for giving each new connection a fresh receiver.</summary>
    private string? uxplayPath;
    private DispatcherTimer? watchdog;
    private static readonly TimeSpan SilenceLimit = TimeSpan.FromSeconds(10);
    /// <summary>Bumped on every start and stop, so callbacks from an old uxplay process are ignored.</summary>
    private int generation;
    /// <summary>When the receiver last started, to tell a crash after running a while (start a
    /// fresh one) from one that can't run at all (show the error).</summary>
    private DateTime? processStartedAt;
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;

    // Touched only on the UDP thread or an Android phone's reading thread, under `streamGate`.
    // (Only one of them carries video at a time: uxplay is stopped while an Android phone has the
    // slot.)
    private readonly object streamGate = new();
    private readonly Depacketizer depacketizer = new();
    private readonly StreamMeter meter = new();
    private int lostPacketsCounted;
    private double lastNotified;
    private (int, int)? lastDimensions;
    /// <summary>The Android phone whose video goes to the screen; null until the slot takes one.</summary>
    private CastConnection? streamingPhone;
    /// <summary>The Android phone's codec, read from its keyframes.</summary>
    private VideoCodec castStreamCodec = VideoCodec.H264;
    private double lastLatencyReport;
    // Written on the UDP thread, read by the UI thread's callbacks; a stale read only delays one.
    private volatile bool receiving;

    public Slot(SlotConfig config)
    {
        Config = config;
        Renderer.OnPicture = picture =>
        {
            lock (recorderGate) recorder?.Append(picture, picture.RtpTimestamp, Clock.Now);
        };
    }

    /// <param name="freshLog">false when restarting after a disconnect, to keep what led up to it.</param>
    public void Start(string uxplay, bool freshLog = true)
    {
        if (process != null) return;
        int currentGeneration = ++generation;
        uxplayPath = uxplay;
        if (freshLog)
        {
            Log.Clear();
            OpenLogFile();
        }
        lock (streamGate)
        {
            depacketizer.Reset();
            meter.Reset();
            lostPacketsCounted = 0;
        }

        var newReceiver = new UdpReceiver(Config.RtpPort, Handle);
        try
        {
            newReceiver.Start();
        }
        catch (SocketException error)
        {
            Fail($"Couldn't listen on UDP port {Config.RtpPort} ({error.Message}).");
            return;
        }
        receiver = newReceiver;
        receiving = true;

        var arguments = Config.UxPlayArguments(MaxFrameRate, AllowedDevices, SharpPicture);
        var newProcess = new ReceiverProcess(uxplay, arguments,
            onLine: line => { if (generation == currentGeneration) Append(line); },
            onExit: status => { if (generation == currentGeneration) ProcessExited(status); });
        try
        {
            newProcess.Start();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            receiving = false;
            receiver.Stop();
            receiver = null;
            Fail($"Couldn't start uxplay: {error.Message}");
            return;
        }
        process = newProcess;
        processStartedAt = DateTime.Now;
        StartCastServer();
        StartWatchdog();
        Append("Started: uxplay " + string.Join(' ', arguments.Select(argument => argument.Contains(' ') ? $"\"{argument}\"" : argument)));
        FailureMessage = null;
        State = SlotState.Waiting;
    }

    public void Stop()
    {
        // A recording carries on into the next connection, in a new file.
        lock (recorderGate) recorder?.EndFile();
        generation++;
        watchdog?.Stop();
        watchdog = null;
        lastSignOfLifeAt = null;
        process?.Stop();
        process = null;
        castServer?.Stop();
        castServer = null;
        castPhone = null;
        // Once this returns, no more of the Android phone's video reaches the renderer.
        lock (streamGate) streamingPhone = null;
        receiving = false;
        receiver?.Stop();
        receiver = null;
        Renderer.Reset();
        Stats.ClearStream();
        LastFrameAt = null;
        HasPicture = false;
        VideoSize = null;
        PhoneName = null;
        ConnectedSince = null;
        State = SlotState.Stopped;
    }

    public void Restart(string uxplay)
    {
        Stop();
        Start(uxplay);
    }

    public void Rename(string name, string? uxplay)
    {
        Config.Name = name;
        Changed(nameof(Name));
        if (uxplay != null && process != null) Restart(uxplay);
    }

    private void Fail(string message)
    {
        if (castServer == null) listing?.SetRegistered(false);
        FailureMessage = message;
        Changed(nameof(FailureMessage));
        State = SlotState.Failed;
    }

    // MARK: OBS feed

    /// <summary>Sends the slot's picture to OBS through Spout, under <paramref name="name"/>, or
    /// stops. Returns false if the feed couldn't start (no Spout in this build).</summary>
    public bool SetObsFeed(bool on, string name)
    {
        if (on)
        {
            if (spoutFeed != null)
            {
                spoutFeed.Name = name;
            }
            else if (SpoutFeed.Create(name) is { } feed)
            {
                spoutFeed = feed;
                feed.PassesFrames = CarriesPhoneFrames;
                UpdateFeedBezel();
                Renderer.OnShow = feed.PublishFrame;
                if (Renderer.CurrentPicture() is { } picture)
                {
                    feed.PublishFrame(picture);
                    picture.Release();
                }
            }
            else
            {
                return false;
            }
        }
        else
        {
            Renderer.OnShow = null;
            spoutFeed?.Stop();
            spoutFeed = null;
        }
        Changed(nameof(SendsToObs));
        Changed(nameof(ObsFeedName));
        return true;
    }

    /// <summary>Remembers this slot's own OBS feed choice; null follows the setting for all slots.</summary>
    public void RememberObsFeed(bool? choice) => Config.ObsFeed = choice;

    private bool showsBezel;
    /// <summary>Whether the picture has a phone frame around it, on the wall and in its own window.
    /// Set by the store from the slot's own choice or the setting for all slots.</summary>
    public bool ShowsBezel { get => showsBezel; set => Set(ref showsBezel, value); }

    /// <summary>Remembers this slot's own bezel choice; null follows the setting for all slots.</summary>
    public void RememberBezel(bool? choice) => Config.Bezel = choice;

    /// <summary>The frame for a picture of this size (the phone's shape), styled after the last phone.</summary>
    public BezelGeometry Bezel(Size picture) => new(Config.LastPhoneModel, picture.Width, picture.Height, PhoneTurns);

    private int? phoneTurns;

    /// <summary>Which way up the Android phone says it's held (see <see cref="CastMessage.Orientation"/>);
    /// null for an iPhone or an older Android app, which don't say.</summary>
    public int? PhoneTurns
    {
        get => phoneTurns;
        private set
        {
            if (!Set(ref phoneTurns, value)) return;
            if (spoutFeed != null) spoutFeed.BezelTurns = value;
        }
    }

    /// <summary>Whether the OBS feed has the phone frame around the picture, with see-through corners.</summary>
    public bool FramesObsFeed => Config.FeedBezel ?? false;

    /// <summary>Puts the phone frame around the OBS feed's picture, or takes it off. The store
    /// re-sends the standby picture.</summary>
    public void SetFramesObsFeed(bool on)
    {
        Config.FeedBezel = on ? true : null;
        UpdateFeedBezel();
        if (ShowsPicture && Renderer.CurrentPicture() is { } picture)
        {
            spoutFeed?.PublishFrame(picture);
            picture.Release();
        }
        Changed(nameof(FramesObsFeed));
    }

    /// <summary>The feed's frame follows the last phone's model.</summary>
    private void UpdateFeedBezel()
    {
        if (spoutFeed == null) return;
        spoutFeed.Bezel = FramesObsFeed ? BezelGeometry.StyleFor(Config.LastPhoneModel) : null;
        spoutFeed.BezelTurns = PhoneTurns;
    }

    /// <summary>Whether the phone appears in the Stage window while it's mirroring. Off until it's
    /// put on the Stage (see <see cref="StagePhones"/>).</summary>
    public bool ShowsOnStage => Config.OnStage ?? false;

    public void SetShowsOnStage(bool on)
    {
        Config.OnStage = on ? true : null;
        Changed(nameof(ShowsOnStage));
    }

    /// <summary>True while the slot is sending its picture to OBS.</summary>
    public bool SendsToObs => spoutFeed != null;
    /// <summary>The name OBS lists the slot's feed under, while it's on.</summary>
    public string? ObsFeedName => spoutFeed?.Name;

    /// <summary>Sends a still picture (the standby picture) down the OBS feed, if it's on.</summary>
    public void SendToObs(Picture picture) => spoutFeed?.Publish(picture);

    public void SetStandby(StandbyPicture? standby)
    {
        Config.Standby = standby;
        Changed(nameof(Config));
    }

    /// <summary>True while there's a current picture: live, or paused on its last frame.</summary>
    public bool ShowsPicture => HasPicture && State is SlotState.Live or SlotState.Paused;

    // MARK: Screenshots

    /// <summary>Saves the picture on screen now, at the stream's full size, to the screenshots folder.</summary>
    public void TakeScreenshot()
    {
        if (!ShowsPicture || Renderer.CurrentPicture() is not { } picture) return;
        string baseName = PhoneName ?? Config.LastPhoneName ?? Name;
        Task.Run(() =>
        {
            try
            {
                string path = Screenshots.Save(picture, baseName);
                dispatcher.BeginInvoke(() =>
                {
                    ScreenshotSavedAt = DateTime.Now;
                    Changed(nameof(ScreenshotSavedAt));
                    Append($"Saved screenshot {Path.GetFileName(path)}");
                });
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                dispatcher.BeginInvoke(() => Append($"Screenshot failed: {error.Message}"));
            }
            finally
            {
                picture.Release();
            }
        });
    }

    // MARK: Recording

    public void StartRecording()
    {
        if (RecordingSince != null) return;
        var newRecorder = new SlotRecorder(SaveFolders.Recordings, PhoneName ?? Config.LastPhoneName ?? Name);
        newRecorder.OnError = message => dispatcher.BeginInvoke(() =>
        {
            RecordingError = message;
            Append($"Recording: {message}");
        });
        lock (recorderGate)
        {
            recorder = newRecorder;
            // Start with the picture on screen now: a still screen sends nothing until it changes.
            if (Renderer.CurrentPicture() is { } picture)
            {
                newRecorder.Append(picture, null, Clock.Now);
                picture.Release();
            }
        }
        RecordingError = null;
        RecordingSince = DateTime.Now;
        Append($"Recording to {SaveFolders.Recordings}");
    }

    /// <param name="wait">true when quitting, so the file is complete before the app exits.</param>
    public void StopRecording(bool wait = false)
    {
        if (RecordingSince == null) return;
        SlotRecorder? finished;
        lock (recorderGate)
        {
            finished = recorder;
            recorder = null;
        }
        if (finished != null)
        {
            if (wait) finished.Close();
            else Task.Run(finished.Close);
        }
        RecordingSince = null;
        Append("Recording stopped");
    }

    // MARK: UDP thread

    private void Handle(byte[] datagram, int count)
    {
        if (RtpPacket.Parse(datagram.AsSpan(0, count)) is not { } packet) return;
        lock (streamGate)
        {
            var frames = depacketizer.Push(packet);
            double arrivedAt = Clock.Now;
            meter.Packet(packet.Payload.Length, depacketizer.LostPackets - lostPacketsCounted, arrivedAt);
            lostPacketsCounted = depacketizer.LostPackets;
            Deliver(frames, arrivedAt);
        }
    }

    /// <summary>An Android phone's reading thread: one picture from the phone.</summary>
    private void HandleCastVideo(CastConnection phone, long captureMicros, byte[] accessUnit)
    {
        var nalUnits = CastProtocol.AnnexBNalUnits(accessUnit);
        if (nalUnits.Count == 0) return;
        lock (streamGate)
        {
            if (phone != streamingPhone) return;
            if (CastProtocol.Codec(nalUnits) is VideoCodec codec) castStreamCodec = codec;
            var frame = new VideoFrame(nalUnits, CastProtocol.RtpTimestamp(captureMicros), castStreamCodec);
            double arrivedAt = Clock.Now;
            meter.Packet(accessUnit.Length, 0, arrivedAt);
            Deliver(new[] { frame }, arrivedAt);
            // Arrival minus capture time, on clocks with an unknown offset: only its rise above the
            // best so far means anything, which is what Lag vs best shows.
            if (arrivedAt - lastLatencyReport >= 1)
            {
                lastLatencyReport = arrivedAt;
                double latency = arrivedAt - captureMicros / 1e6;
                dispatcher.BeginInvoke(() => Stats.RecordLatency(latency));
            }
        }
    }

    /// <summary>Under `streamGate`: decodes frames from either kind of phone and keeps the tile up to date.</summary>
    private void Deliver(IReadOnlyList<VideoFrame> frames, double arrivedAt)
    {
        bool rendered = false;
        foreach (var frame in frames)
        {
            bool shown;
            try
            {
                shown = Renderer.Render(frame, arrivedAt);
            }
            catch (Exception error) when (error is InvalidOperationException or DllNotFoundException or NotSupportedException)
            {
                // FFmpeg missing or unable to open a decoder: say so once rather than for every frame.
                string message = error.Message;
                dispatcher.BeginInvoke(() => { if (State != SlotState.Failed) { Append($"Can't decode the video: {message}"); Fail($"Can't decode the video: {message}"); } });
                return;
            }
            meter.Frame(arrivedAt, frame.IsKeyframe, shown ? Clock.Now - arrivedAt : null);
            rendered |= shown;
        }
        if (meter.SnapshotIfDue(arrivedAt) is { } snapshot)
        {
            string? codec = Renderer.CodecDescription;
            dispatcher.BeginInvoke(() =>
            {
                if (!receiving) return;
                Stats.Stream = snapshot;
                Stats.Codec = codec;
            });
        }
        if (!rendered) return;

        // Tell the UI at most a few times a second; the bitmap shows every frame by itself.
        double now = Clock.Now;
        var dimensions = Renderer.Dimensions;
        bool sizeChanged = dimensions != lastDimensions;
        if (!sizeChanged && now - lastNotified <= 0.5) return;
        lastNotified = now;
        lastDimensions = dimensions;

        dispatcher.BeginInvoke(() =>
        {
            if (!receiving) return;
            LastFrameAt = DateTime.Now;
            HasPicture = true;
            if (dimensions is var (width, height))
            {
                var size = new Size(width, height);
                VideoSize = size;
                LastPictureSize = size;
            }
            lastSignOfLifeAt = DateTime.Now;
            bool pauseSettled = pausedAt is not DateTime paused || (DateTime.Now - paused).TotalSeconds > 3;
            if (State is not (SlotState.Live or SlotState.Disconnected) && (State != SlotState.Paused || pauseSettled))
                State = SlotState.Live;
        });
    }

    // MARK: Android phones (Mirror Wall Cast)

    private void StartCastServer()
    {
        var server = new CastServer(Config.CastPort, CastPhoneConnected);
        try
        {
            server.Start();
            castServer = server;
        }
        catch (SocketException error)
        {
            listing?.SetRegistered(false);
            Append($"Android phones can't connect to this slot: couldn't listen on port {Config.CastPort} ({error.Message})");
        }
        UpdateListing();
    }

    /// <summary>A free slot is on the Android app's list; one in use drops off it until it's free
    /// again. Leaves the listing alone while the slot is between receivers (Stop, then Start).</summary>
    private void UpdateListing()
    {
        if (castServer == null) return;
        bool listed = !CarriesPhoneFrames;
        if (listed && (listing == null || listingName != Name))
        {
            listing?.Dispose();
            listing = DnsServiceAdvertiser.Create(Name, CastServer.ServiceType, Config.CastPort);
            listingName = Name;
        }
        listing?.SetRegistered(listed);
    }

    /// <summary>The server's thread: wires up a new connection. Nothing is decided until the phone
    /// says hello.</summary>
    private void CastPhoneConnected(CastConnection phone)
    {
        phone.OnMessage = message =>
        {
            if (message is CastMessage.Video video) HandleCastVideo(phone, video.CaptureMicros, video.AccessUnit);
            else dispatcher.BeginInvoke(() => CastMessageArrived(message, phone));
        };
        phone.OnClose = () => dispatcher.BeginInvoke(() => CastPhoneLeft(phone));
    }

    private void CastMessageArrived(CastMessage message, CastConnection phone)
    {
        if (message is CastMessage.Hello hello)
        {
            CastPhoneSaidHello(hello.Info, phone);
            return;
        }
        if (phone != castPhone) return;
        switch (message)
        {
            case CastMessage.Paused:
                Apply(new UxPlayEvent.StreamPaused());
                break;
            case CastMessage.Resumed:
                Apply(new UxPlayEvent.StreamStarted());
                break;
            case CastMessage.Heartbeat:
                Apply(new UxPlayEvent.Heartbeat());
                // A still screen sends no pictures; don't leave the last second's numbers up.
                if (LastFrameAt is DateTime last && (DateTime.Now - last).TotalSeconds > 1.5 &&
                    Stats.Stream is { } stream && stream.FramesPerSecond != 0)
                {
                    Stats.Stream = stream with { FramesPerSecond = 0, BitsPerSecond = 0 };
                }
                phone.Send(new CastMessage.Ping((ulong)Stopwatch.GetTimestamp()));
                break;
            case CastMessage.Pong pong:
                long now = Stopwatch.GetTimestamp();
                if (now > (long)pong.Value) Stats.RoundTrip = (now - (long)pong.Value) / (double)Stopwatch.Frequency;
                break;
            case CastMessage.Bye:
                Append($"{PhoneName ?? "The Android phone"} stopped sharing");
                break;
            case CastMessage.Orientation orientation:
                PhoneTurns = orientation.Turns;
                break;
        }
    }

    private void CastPhoneSaidHello(CastHello hello, CastConnection phone)
    {
        if (castServer == null || castPhone != null)
        {
            phone.Refuse($"{Name} is showing another phone.");
            return;
        }
        if (State is SlotState.Connecting or SlotState.Live or SlotState.Paused)
        {
            phone.Refuse($"{Name} is showing {PhoneName ?? "another phone"}.");
            return;
        }
        if (AllowedDevices is { } allowed && !allowed.Contains(hello.DeviceId))
        {
            OnPhoneSeen?.Invoke(new KnownPhone(hello.DeviceId, hello.Name, hello.Model, DateTime.Now));
            Append($"Turned away {hello.Name} ({hello.Model}): not on the allow-list");
            phone.Refuse($"This phone isn't allowed on {Name}. It can be allowed in Mirror Wall's Settings.");
            return;
        }
        castPhone = phone;
        PhoneTurns = null;
        Append($"Android phone connecting: {hello.Name} ({hello.Model}) from {phone.RemoteDescription}");
        // Take the slot off iPhones' Screen Mirroring list while the Android phone has it. The
        // generation bump keeps the stopping uxplay's exit, and any pending restart, from touching
        // the slot.
        generation++;
        process?.Stop();
        process = null;
        lock (streamGate)
        {
            depacketizer.Reset();
            castStreamCodec = VideoCodec.H264;
            streamingPhone = phone;
        }
        Apply(new UxPlayEvent.ClientConnecting(hello.Name, hello.Model, hello.DeviceId));
        lastSignOfLifeAt = DateTime.Now;
        phone.Accept(new CastWelcome(Name, MaxFrameRate, SharpPicture));
    }

    /// <summary>The Android phone hung up, or the connection broke. Ends like an iPhone
    /// disconnecting: Disconnected, then a fresh uxplay so iPhones can see the slot again.</summary>
    private void CastPhoneLeft(CastConnection phone)
    {
        if (phone != castPhone) return;
        castPhone = null;
        PhoneTurns = null;
        Append($"{PhoneName ?? "The Android phone"} disconnected");
        ConnectedSince = null;
        if (State is not (SlotState.Waiting or SlotState.Disconnected)) PhoneDropped();
        else RestartReceiverSoon();
    }

    // MARK: UI thread

    private void Append(string line)
    {
        var uxplayEvent = UxPlayEvent.Parse(line);
        // Latency reports come every second; they feed the stats overlay, not the log.
        if (uxplayEvent is not UxPlayEvent.VideoLatency)
        {
            logFile?.WriteLine(line);
            Log.Add(line);
            while (Log.Count > 300) Log.RemoveAt(0);
        }
        if (uxplayEvent != null) Apply(uxplayEvent);
    }

    private void Apply(UxPlayEvent uxplayEvent)
    {
        switch (uxplayEvent)
        {
            case UxPlayEvent.ClientConnecting(var name, var model, var deviceId):
                // The decoder needs no reset here: a new stream starts with new parameter sets.
                lastSignOfLifeAt = null;
                PhoneName = name;
                ConnectedSince = DateTime.Now;
                lock (recorderGate) { if (recorder != null) recorder.BaseName = name; }
                Stats.PhoneModel = model.Length == 0 ? null : PhoneModels.Name(model);
                Stats.Connections++;
                if (deviceId.Length > 0) OnPhoneSeen?.Invoke(new KnownPhone(deviceId, name, model, DateTime.Now));
                if (Config.LastPhoneName != name || (model.Length > 0 && Config.LastPhoneModel != model))
                {
                    Config.LastPhoneName = name;
                    if (model.Length > 0) Config.LastPhoneModel = model;
                    UpdateFeedBezel();
                    Changed(nameof(Config));
                    OnConfigChanged?.Invoke();
                }
                State = SlotState.Connecting;
                break;
            case UxPlayEvent.StreamStarted:
                if (State is SlotState.Connecting or SlotState.Paused or SlotState.Disconnected) State = SlotState.Live;
                break;
            case UxPlayEvent.StreamPaused:
                pausedAt = DateTime.Now;
                if (State is SlotState.Live or SlotState.Connecting) State = SlotState.Paused;
                break;
            case UxPlayEvent.OpenConnections(0):
            case UxPlayEvent.LostConnection:
                ConnectedSince = null;
                if (State is not (SlotState.Waiting or SlotState.Disconnected)) PhoneDropped();
                break;
            case UxPlayEvent.Heartbeat:
                lastSignOfLifeAt = DateTime.Now;
                Stats.Heartbeat();
                break;
            case UxPlayEvent.NetworkRoundTrip(var seconds):
                Stats.RoundTrip = seconds;
                break;
            case UxPlayEvent.VideoLatency(var seconds):
                Stats.RecordLatency(seconds);
                break;
        }
    }

    private void StartWatchdog()
    {
        watchdog?.Stop();
        watchdog = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        watchdog.Tick += (_, _) => CheckForSilence();
        watchdog.Start();
    }

    private void CheckForSilence()
    {
        if (lastSignOfLifeAt is not DateTime last || State is not (SlotState.Live or SlotState.Paused or SlotState.Connecting)
            || DateTime.Now - last <= SilenceLimit) return;
        Append($"No check-in or video from the phone for {SilenceLimit.TotalSeconds:0} seconds; treating it as disconnected");
        ConnectedSince = null;
        PhoneDropped();
    }

    private void PhoneDropped()
    {
        bool wasMirroring = State is SlotState.Live or SlotState.Paused or SlotState.Connecting;
        State = SlotState.Disconnected;
        RestartReceiverSoon();
        if (wasMirroring) OnPhoneDropped?.Invoke();
    }

    /// <summary>
    /// After a phone disconnects, uxplay sometimes fails to rebuild its video output, and the next
    /// connection then gets no video at all. So each disconnect gets a fresh uxplay. The tile keeps
    /// saying Disconnected, and the slot's name comes back on the phone within a second or two.
    /// This also clears the last picture, so a new connection never shows a stale frame.
    /// </summary>
    private void RestartReceiverSoon()
    {
        int currentGeneration = generation;
        // A moment for uxplay to finish logging the disconnect.
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (generation != currentGeneration || State != SlotState.Disconnected || uxplayPath == null) return;
            string? phone = PhoneName;
            Append("Restarting the receiver so the next connection starts fresh");
            Stop();
            Start(uxplayPath, freshLog: false);
            if (State == SlotState.Waiting)
            {
                PhoneName = phone;
                State = SlotState.Disconnected;
            }
        };
        timer.Start();
    }

    /// <summary>Mirrors the log to %LOCALAPPDATA%\Mirror Wall\Logs\slot-N.log (replaced on each
    /// start) for troubleshooting.</summary>
    private void OpenLogFile()
    {
        logFile?.Dispose();
        logFile = null;
        try
        {
            Directory.CreateDirectory(AppPaths.Logs);
            logFile = new StreamWriter(Path.Combine(AppPaths.Logs, $"slot-{Config.Id}.log"), append: false) { AutoFlush = true };
        }
        catch (IOException)
        {
        }
    }

    private void ProcessExited(int status)
    {
        Append($"uxplay exited with status {status}");
        process = null;
        receiving = false;
        receiver?.Stop();
        receiver = null;
        // A receiver that ran a while and quit by itself, most often crashing as a phone
        // disconnects, gets replaced like after any disconnect. One that quits within seconds of
        // starting is shown as failed rather than restarted over and over.
        bool ranAWhile = processStartedAt is DateTime started && (DateTime.Now - started).TotalSeconds > 5;
        if (!ranAWhile || uxplayPath == null)
        {
            Fail($"The receiver stopped (exit status {status}). Use Restart, or check the log.");
            return;
        }
        bool wasMirroring = State is SlotState.Live or SlotState.Paused or SlotState.Connecting;
        string? phone = PhoneName;
        Append("Starting a fresh receiver");
        Stop();
        Start(uxplayPath, freshLog: false);
        if ((wasMirroring || phone != null) && State == SlotState.Waiting)
        {
            PhoneName = phone;
            State = SlotState.Disconnected;
        }
        if (wasMirroring) OnPhoneDropped?.Invoke();
    }

    /// <summary>Stops everything for good, when the app quits.</summary>
    public void Shutdown()
    {
        StopRecording(wait: true);
        // Not SetObsFeed(false): the feed is still on in the saved settings, for next time.
        Renderer.OnShow = null;
        spoutFeed?.Stop();
        spoutFeed = null;
        Stop();
        listing?.Dispose();
        listing = null;
        Renderer.Dispose();
        logFile?.Dispose();
        logFile = null;
    }

    /// <summary>Starts the receiver quitting without waiting for it, so several can quit at once.</summary>
    public void AskReceiverToQuit() => process?.CloseInput();
}
