using System.Net;
using System.Net.Sockets;

namespace MirrorWall;

/// <summary>Receives UDP datagrams on 127.0.0.1:port on a dedicated thread.</summary>
internal sealed class UdpReceiver
{
    public int Port { get; }
    private readonly Action<byte[], int> onDatagram;
    private Socket? socket;
    private Thread? thread;
    private volatile bool running;

    /// <summary><paramref name="onDatagram"/> is called on the receiver's own thread with a buffer
    /// it reuses, so it must be done with the bytes when it returns.</summary>
    public UdpReceiver(int port, Action<byte[], int> onDatagram)
    {
        Port = port;
        this.onDatagram = onDatagram;
    }

    /// <exception cref="SocketException">The port couldn't be opened.</exception>
    public void Start()
    {
        var newSocket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
        {
            ReceiveBufferSize = 4 << 20,
            // Wake up regularly so Stop takes effect even when nothing is arriving.
            ReceiveTimeout = 250,
        };
        try
        {
            newSocket.Bind(new IPEndPoint(IPAddress.Loopback, Port));
        }
        catch
        {
            newSocket.Dispose();
            throw;
        }
        socket = newSocket;
        running = true;
        thread = new Thread(ReceiveLoop) { Name = $"Mirror Wall UDP {Port}", IsBackground = true, Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    /// <summary>Stops receiving and waits for the receive thread to finish, so no callback runs after this returns.</summary>
    public void Stop()
    {
        if (!running) return;
        running = false;
        thread?.Join(1000);
        thread = null;
    }

    private void ReceiveLoop()
    {
        var buffer = new byte[65_536];
        var socket = this.socket!;
        while (running)
        {
            int count;
            try
            {
                count = socket.Receive(buffer);
            }
            catch (SocketException)
            {
                continue; // the timeout, or a reset from an earlier send; keep listening
            }
            if (count > 0) onDatagram(buffer, count);
        }
        socket.Dispose();
    }
}
