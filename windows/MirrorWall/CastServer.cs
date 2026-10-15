using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// Listens on a slot's cast port for Android phones running the Mirror Wall Cast app. The slot lists
/// itself on the network (<c>_mirrorwall._tcp</c>) with a <see cref="DnsServiceAdvertiser"/> of its
/// own, which outlives the server across receiver restarts. A port of the Mac app's CastServer.
///
/// Connections are accepted on the server's own thread and each one is read on a thread of its
/// own; their callbacks run there.
/// </summary>
internal sealed class CastServer
{
    public const string ServiceType = "_mirrorwall._tcp";

    public int Port { get; }
    private readonly Action<CastConnection> onConnection;
    private readonly object gate = new();
    // Guarded by `gate`.
    private TcpListener? listener;
    private readonly List<CastConnection> connections = new();
    private bool stopped;

    public CastServer(int port, Action<CastConnection> onConnection)
    {
        Port = port;
        this.onConnection = onConnection;
    }

    /// <exception cref="SocketException">The port couldn't be opened.</exception>
    public void Start()
    {
        // Both IPv4 and IPv6 where the PC has IPv6.
        var newListener = TcpListener.Create(Port);
        newListener.Start();
        lock (gate)
        {
            listener = newListener;
        }
        new Thread(() => AcceptLoop(newListener)) { Name = $"Mirror Wall cast {Port}", IsBackground = true }.Start();
    }

    /// <summary>Stops listening and drops any phone that's connected.</summary>
    public void Stop()
    {
        List<CastConnection> dropped;
        lock (gate)
        {
            if (stopped) return;
            stopped = true;
            listener?.Stop();
            listener = null;
            dropped = connections.ToList();
            connections.Clear();
        }
        foreach (var connection in dropped) connection.Close();
    }

    private void AcceptLoop(TcpListener listener)
    {
        while (true)
        {
            Socket socket;
            try
            {
                socket = listener.AcceptSocket();
            }
            catch (Exception error) when (error is SocketException or ObjectDisposedException or InvalidOperationException)
            {
                return; // stopped
            }
            socket.NoDelay = true;
            var connection = new CastConnection(socket);
            lock (gate)
            {
                if (stopped)
                {
                    socket.Dispose();
                    return;
                }
                connections.Add(connection);
            }
            connection.OnEnded = () => { lock (gate) connections.Remove(connection); };
            onConnection(connection);
            connection.Start();
        }
    }
}

/// <summary>One phone's connection. Set the callbacks before it starts; they run on its reading thread
/// (<see cref="OnClose"/> on whichever thread ends the connection).</summary>
internal sealed class CastConnection
{
    private readonly Socket socket;
    private readonly CastReader reader = new();
    private readonly object gate = new();
    // Guarded by `gate`.
    private bool ended;
    /// <summary>Sends, one after another, off the caller's thread.</summary>
    private Task sending = Task.CompletedTask;

    /// <summary>Each message from the phone.</summary>
    public Action<CastMessage>? OnMessage { get; set; }
    /// <summary>Once, when the connection ends for any reason.</summary>
    public Action? OnClose { get; set; }
    internal Action? OnEnded { get; set; }

    /// <summary>The phone's address, for the log.</summary>
    public string RemoteDescription { get; }

    public CastConnection(Socket socket)
    {
        this.socket = socket;
        RemoteDescription = socket.RemoteEndPoint is IPEndPoint endPoint
            ? (endPoint.Address.IsIPv4MappedToIPv6 ? endPoint.Address.MapToIPv4() : endPoint.Address).ToString()
            : "unknown address";
    }

    internal void Start()
    {
        lock (gate)
        {
            if (ended) return;
        }
        new Thread(ReceiveLoop) { Name = $"Mirror Wall cast phone {RemoteDescription}", IsBackground = true, Priority = ThreadPriority.AboveNormal }.Start();
    }

    /// <summary>Tells the phone it has the slot. Safe from any thread.</summary>
    public void Accept(CastWelcome welcome) => Send(new CastMessage.Welcome(welcome));

    /// <summary>Turns the phone away with a reason it shows, then hangs up. Safe from any thread.</summary>
    public void Refuse(string reason) => Enqueue(new CastMessage.Busy(new CastBusy(reason)).Encoded(), thenClose: true);

    /// <summary>Sends a message to the phone. Safe from any thread.</summary>
    public void Send(CastMessage message) => Enqueue(message.Encoded(), thenClose: false);

    private void Enqueue(byte[] bytes, bool thenClose)
    {
        lock (gate)
        {
            if (ended) return;
            sending = sending.ContinueWith(_ => Transmit(bytes, thenClose), TaskScheduler.Default);
        }
    }

    private void Transmit(byte[] bytes, bool thenClose)
    {
        try
        {
            int sent = 0;
            while (sent < bytes.Length) sent += socket.Send(bytes, sent, bytes.Length - sent, SocketFlags.None);
        }
        catch (Exception error) when (error is SocketException or ObjectDisposedException)
        {
            Close();
            return;
        }
        if (thenClose) Close();
    }

    /// <summary>Hangs up. Safe from any thread.</summary>
    public void Close()
    {
        Action? onClose, onEnded;
        lock (gate)
        {
            if (ended) return;
            ended = true;
            onClose = OnClose;
            onEnded = OnEnded;
            OnMessage = null;
            OnClose = null;
            OnEnded = null;
        }
        try { socket.Shutdown(SocketShutdown.Both); }
        catch (Exception error) when (error is SocketException or ObjectDisposedException) { }
        // Also ends a read waiting on the reading thread.
        socket.Close();
        onClose?.Invoke();
        onEnded?.Invoke();
    }

    private void ReceiveLoop()
    {
        var buffer = new byte[1 << 20];
        while (true)
        {
            int count;
            try
            {
                count = socket.Receive(buffer);
            }
            catch (Exception error) when (error is SocketException or ObjectDisposedException)
            {
                break;
            }
            if (count == 0) break; // the phone hung up
            List<CastMessage> messages;
            try
            {
                messages = reader.Push(buffer.AsSpan(0, count));
            }
            catch (CastStreamException)
            {
                break;
            }
            foreach (var message in messages)
            {
                Action<CastMessage>? onMessage;
                lock (gate) onMessage = OnMessage;
                onMessage?.Invoke(message);
            }
        }
        Close();
    }
}

/// <summary>
/// Lists a service on the local network with Windows' own mDNS (DNS-SD) responder, dnsapi's
/// DnsServiceRegister (Windows 10 1809 and later), the way the Mac lists it with Bonjour.
///
/// Registering and withdrawing finish in the background, so they're done one at a time: a
/// withdrawal sent while the registration is still going through is lost, which left the name
/// listed for good, and the next registration of the same name then came out as "Name (1)".
/// The native memory they use stays until the last of them has finished.
/// </summary>
internal sealed class DnsServiceAdvertiser : IDisposable
{
    private readonly object gate = new();
    // Guarded by `gate`.
    private IntPtr instance;
    private IntPtr request;
    private GCHandle self;
    /// <summary>Whether the service should be listed.</summary>
    private bool wanted;
    /// <summary>Whether it is listed (or may be), as far as finished calls go.</summary>
    private bool listed;
    /// <summary>What the call in progress will make <see cref="listed"/>, if one is.</summary>
    private bool? inProgress;
    private long inProgressSince;
    private bool disposed;

    /// <summary>Advertisers not yet let go of, so quitting can wait for their withdrawals.</summary>
    private static readonly HashSet<DnsServiceAdvertiser> live = new();

    private DnsServiceAdvertiser(IntPtr instance)
    {
        lock (live) live.Add(this);
        this.instance = instance;
        self = GCHandle.Alloc(this);
        request = Marshal.AllocHGlobal(Marshal.SizeOf<DNS_SERVICE_REGISTER_REQUEST>());
        Marshal.StructureToPtr(new DNS_SERVICE_REGISTER_REQUEST
        {
            Version = DNS_QUERY_REQUEST_VERSION1,
            InterfaceIndex = 0, // every network
            pServiceInstance = instance,
            pRegisterCompletionCallback = CompletionPointer,
            pQueryContext = GCHandle.ToIntPtr(self),
            hCredentials = IntPtr.Zero,
            unicastEnabled = 0,
        }, request, false);
    }

    /// <summary>An advertiser for "<paramref name="name"/>.<paramref name="type"/>.local" on this
    /// PC's <paramref name="port"/>, not yet registered; null if Windows can't do it.</summary>
    public static DnsServiceAdvertiser? Create(string name, string type, int port)
    {
        try
        {
            // The service name is dot-separated, so a dot in the slot's name becomes a look-alike.
            string serviceName = $"{name.Replace('.', '\u2024')}.{type}.local";
            string hostName = SlotStore.ComputerName is { Length: > 0 } computer ? computer + ".local" : Environment.MachineName + ".local";
            IntPtr instance = DnsServiceConstructInstance(serviceName, hostName, IntPtr.Zero, IntPtr.Zero,
                (ushort)port, 0, 0, 0, IntPtr.Zero, IntPtr.Zero);
            return instance == IntPtr.Zero ? null : new DnsServiceAdvertiser(instance);
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException)
        {
            return null; // older than Windows 10 1809
        }
    }

    /// <summary>Lists the service, or withdraws it. A listing withdrawn while a phone is connected
    /// doesn't affect that phone, which already has the address. Safe from any thread.</summary>
    public void SetRegistered(bool on)
    {
        lock (gate)
        {
            if (disposed) return;
            wanted = on;
            Advance();
        }
    }

    /// <summary>Withdraws the service, and lets go of everything once Windows has.</summary>
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            wanted = false;
            Advance();
        }
    }

    /// <summary>Waits, up to <paramref name="limit"/>, for every disposed advertiser's withdrawal to
    /// finish. Windows' responder runs outside the app, so a name still listed as the app quits can
    /// stay listed, and the next start's listing would come out as "Name (1)".</summary>
    public static void WaitForWithdrawals(TimeSpan limit)
    {
        var deadline = Stopwatch.GetTimestamp() + (long)(limit.TotalSeconds * Stopwatch.Frequency);
        lock (live)
        {
            while (live.Count > 0)
            {
                long left = deadline - Stopwatch.GetTimestamp();
                if (left <= 0) return;
                Monitor.Wait(live, TimeSpan.FromSeconds((double)left / Stopwatch.Frequency));
            }
        }
    }

    /// <summary>Starts the next call, if one is needed and none is in progress, and lets go once
    /// a disposed advertiser has nothing left listed. Call with `gate` held.</summary>
    private void Advance()
    {
        // Don't wait forever on a call Windows never reports back on.
        if (inProgress is bool stuck && Stopwatch.GetElapsedTime(inProgressSince) > TimeSpan.FromSeconds(10))
        {
            inProgress = null;
            listed = stuck;
        }
        if (inProgress != null) return;
        if (wanted != listed && instance != IntPtr.Zero)
        {
            uint status = wanted ? DnsServiceRegister(request, IntPtr.Zero) : DnsServiceDeRegister(request, IntPtr.Zero);
            if (status == DNS_REQUEST_PENDING)
            {
                inProgress = wanted;
                inProgressSince = Stopwatch.GetTimestamp();
                return;
            }
            // Refused outright: a registration that didn't happen, or nothing left to withdraw.
            listed = false;
            if (wanted) wanted = false;
        }
        if (disposed && !listed) Free();
    }

    /// <summary>Call with `gate` held.</summary>
    private void Free()
    {
        lock (live)
        {
            live.Remove(this);
            Monitor.PulseAll(live);
        }
        if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
        instance = IntPtr.Zero;
        if (request != IntPtr.Zero) Marshal.FreeHGlobal(request);
        request = IntPtr.Zero;
        if (self.IsAllocated) self.Free();
    }

    /// <summary>Windows' thread: a registration or withdrawal finished.</summary>
    private static void Completed(uint status, IntPtr context, IntPtr completedInstance)
    {
        DnsServiceAdvertiser? advertiser;
        try
        {
            advertiser = context == IntPtr.Zero ? null : GCHandle.FromIntPtr(context).Target as DnsServiceAdvertiser;
        }
        catch (InvalidOperationException)
        {
            return; // already let go of: nothing to do, and throwing here would end the app
        }
        if (advertiser == null) return;
        // `completedInstance` isn't freed: the documentation doesn't say whose it is, and a few
        // hundred bytes per phone connection is a better risk than freeing Windows' own.
        // The next call is made off Windows' thread rather than from inside its callback.
        ThreadPool.QueueUserWorkItem(_ =>
        {
            lock (advertiser.gate)
            {
                if (advertiser.inProgress is not bool done) return;
                advertiser.inProgress = null;
                // A failed registration isn't listed; a failed withdrawal is treated as done,
                // since there's nothing better to try.
                advertiser.listed = done && status == 0;
                // Not retried over and over; the next change of the slot's state tries again.
                if (done && status != 0) advertiser.wanted = false;
                advertiser.Advance();
            }
        });
    }

    // Kept for as long as the app runs, so Windows can always call it back.
    private static readonly DnsServiceRegisterComplete Completion = Completed;
    private static readonly IntPtr CompletionPointer = Marshal.GetFunctionPointerForDelegate(Completion);

    private const uint DNS_QUERY_REQUEST_VERSION1 = 1;
    private const uint DNS_REQUEST_PENDING = 9506;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DnsServiceRegisterComplete(uint status, IntPtr queryContext, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr DnsServiceConstructInstance(string pServiceName, string pHostName, IntPtr pIp4, IntPtr pIp6,
        ushort wPort, ushort wPriority, ushort wWeight, uint dwPropertiesCount, IntPtr keys, IntPtr values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr pInstance);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(IntPtr pRequest, IntPtr pCancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(IntPtr pRequest, IntPtr pCancel);
}
