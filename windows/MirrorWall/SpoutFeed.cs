using System.Runtime.InteropServices;
using System.Text;

namespace MirrorWall;

/// <summary>
/// Publishes a slot's picture to OBS through Spout (the Windows counterpart of the Mac app's
/// Syphon feed), so an OBS "Spout2 Capture" source gets each frame directly instead of capturing
/// a window, even with Mirror Wall minimized. OBS needs the Spout2 plugin for OBS installed once.
///
/// Pictures arrive from the slot's renderer as they're shown. One thread per feed hands them to
/// Spout, which copies them into a texture on the graphics card that OBS shares. While one is
/// being sent, newer ones replace older ones waiting, so a busy PC drops frames rather than
/// falling behind.
/// </summary>
internal sealed class SpoutFeed
{
    /// <summary>False when the app was built without MirrorSpout.dll: the menu item is hidden.</summary>
    public static bool IsAvailable { get; } = NativeLibrary.TryLoad(Path.Combine(AppPaths.App, "MirrorSpout.dll"), out _);

    private readonly object gate = new();
    // Guarded by `gate`.
    private Picture? waiting;
    private bool framesOn = true;
    private string name;
    private bool renamed;
    private bool stopping;
    private readonly AutoResetEvent wake = new(false);
    private readonly Thread thread;

    /// <summary>Null when Spout can't start (no MirrorSpout.dll, or no Direct3D 11 graphics).</summary>
    public static SpoutFeed? Create(string name) => IsAvailable ? new SpoutFeed(name) : null;

    private SpoutFeed(string name)
    {
        this.name = name;
        thread = new Thread(Run) { Name = "Mirror Wall Spout", IsBackground = true, Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    /// <summary>The name OBS lists the feed under. It only changes when the slot's window title
    /// does, and OBS sources set to the old name then lose it, as a window capture would.</summary>
    public string Name
    {
        get { lock (gate) return name; }
        set
        {
            lock (gate)
            {
                if (value == name) return;
                name = value;
                renamed = true;
            }
            wake.Set();
        }
    }

    /// <summary>Whether the phone's frames get through. Turned off the moment the phone leaves,
    /// so its last few frames, still being decoded or held for Smoother Motion, can't land on top
    /// of the standby picture. Stills sent with <see cref="Publish"/> always get through.</summary>
    public bool PassesFrames
    {
        get { lock (gate) return framesOn; }
        set { lock (gate) framesOn = value; }
    }

    /// <summary>Hands one of the phone's frames to OBS, unless <see cref="PassesFrames"/> is off.
    /// The picture is only lent for the call.</summary>
    public void PublishFrame(Picture picture)
    {
        lock (gate)
        {
            if (!framesOn) return;
        }
        Publish(picture);
    }

    /// <summary>Hands a picture to OBS. Returns at once; the picture is only lent for the call.</summary>
    public void Publish(Picture picture)
    {
        lock (gate)
        {
            if (stopping) return;
            waiting?.Release();
            waiting = picture.Retain();
        }
        wake.Set();
    }

    public void Stop()
    {
        lock (gate) stopping = true;
        wake.Set();
        thread.Join(2000);
    }

    private void Run()
    {
        IntPtr sender = MirrorSpout.Create(Encoding.UTF8.GetBytes(Name + "\0"));
        Picture? last = null;
        try
        {
            while (true)
            {
                wake.WaitOne(TimeSpan.FromSeconds(1));
                Picture? picture;
                string? newName = null;
                lock (gate)
                {
                    if (stopping) break;
                    picture = waiting;
                    waiting = null;
                    if (renamed)
                    {
                        newName = name;
                        renamed = false;
                    }
                }
                if (sender == IntPtr.Zero) { picture?.Release(); continue; }
                if (newName != null) MirrorSpout.Rename(sender, Encoding.UTF8.GetBytes(newName + "\0"));
                if (picture != null)
                {
                    last?.Release();
                    last = picture;
                }
                // Sent again every second even when nothing changed: Spout keeps the latest
                // frame, but a source added in OBS later, or a renamed feed, shows it at once.
                if (last != null) MirrorSpout.Send(sender, last.Pixels, (uint)last.Width, (uint)last.Height, (uint)last.Stride);
            }
        }
        finally
        {
            last?.Release();
            lock (gate)
            {
                waiting?.Release();
                waiting = null;
            }
            if (sender != IntPtr.Zero) MirrorSpout.Destroy(sender);
        }
    }

    /// <summary>windows/MirrorSpout: a small wrapper around Spout's SpoutDX sender.</summary>
    private static class MirrorSpout
    {
        [DllImport("MirrorSpout.dll", EntryPoint = "mw_spout_create")]
        public static extern IntPtr Create(byte[] utf8Name);

        [DllImport("MirrorSpout.dll", EntryPoint = "mw_spout_rename")]
        public static extern void Rename(IntPtr sender, byte[] utf8Name);

        [DllImport("MirrorSpout.dll", EntryPoint = "mw_spout_send")]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool Send(IntPtr sender, byte[] bgra, uint width, uint height, uint stride);

        [DllImport("MirrorSpout.dll", EntryPoint = "mw_spout_destroy")]
        public static extern void Destroy(IntPtr sender);
    }
}
