package com.justfortonks.mirrorwall.cast

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.Display
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue

/** What the app shows about sharing. Read and changed on the main thread. */
object CastStatus {
    var sharing = false
        private set
    var text = ""
        private set
    var listener: (() -> Unit)? = null

    fun set(sharing: Boolean, text: String) {
        this.sharing = sharing
        this.text = text
        listener?.invoke()
    }
}

/**
 * Shares the screen with one Mirror Wall slot: connects, says hello, and once welcomed sends the
 * screen until stopped, turned away, or Android ends the capture. If the connection drops (the
 * Mac restarted the slot, say), it keeps the capture and reconnects to the same slot for a while.
 */
class CastService : Service() {
    companion object {
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_SLOT = "slot"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val ACTION_STOP = "com.justfortonks.mirrorwall.cast.STOP"

        private const val CHANNEL = "sharing"
        private const val NOTIFICATION_ID = 1
        /** Longest side sent in H.264; matches what iPhones send. */
        private const val MAX_LONG_SIDE = 1920
        /** Longest side sent in H.265 (Sharper Picture); matches iPhones again. */
        private const val MAX_LONG_SIDE_HEVC = 2160
        /** Pictures waiting to go out before the oldest are dropped to stay live. */
        private const val MAX_QUEUED = 12
        /** How long to keep trying after the connection drops. */
        private const val RECONNECT_FOR_MS = 60_000L
        private const val RECONNECT_EVERY_MS = 2_000L
        /**
         * Mirror Wall answers each 2-second heartbeat with a ping. Once one has arrived, this long
         * with nothing from Mirror Wall means the connection is dead, even if Android hasn't noticed.
         */
        private const val SILENCE_MEANS_LOST_MS = 10_000
        /** After the network fell behind, how long it must keep up before the picture is sharpened again. */
        private const val RAISE_BIT_RATE_AFTER_MS = 10_000L
        private val END = ByteArray(0)
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var encoder: ScreenEncoder? = null
    /** The connection pictures go to; null between connections. Set on the main thread. */
    @Volatile private var link: Link? = null
    private var host = ""
    private var port = 0
    private var slotName = ""
    private var frameRate = 30
    private var sharpPicture = false
    /** When the connection dropped, while reconnecting. */
    private var lostAt: Long? = null
    private var stopped = false
    /** Holds the screen on while sharing, if the app's switch says to. */
    private var screenLock: PowerManager.WakeLock? = null
    /** Keep the processor and Wi-Fi awake while sharing, even with the screen off. */
    private var cpuLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    @Volatile private var screenOff = false
    @Volatile private var waitingForKeyframe = false
    /** What the encoder is asked for now; below its usual rate while the network can't keep up. */
    private var bitRate = 0
    /** When the network last fell behind, or the bit rate was last raised. */
    private var bitRateChangedAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            AppLog.write(if (intent == null) "Service restarted without a capture; stopping" else "Stop tapped")
            finish("Stopped sharing")
            return START_NOT_STICKY
        }
        if (projection != null) return START_NOT_STICKY // already sharing

        host = intent.getStringExtra(EXTRA_HOST) ?: return START_NOT_STICKY
        port = intent.getIntExtra(EXTRA_PORT, 0)
        slotName = intent.getStringExtra(EXTRA_SLOT) ?: host
        AppLog.write("Sharing to $slotName at $host:$port")
        // Android requires the notification before the capture starts.
        startForeground(NOTIFICATION_ID, notification("Connecting to $slotName…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)

        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = data?.let { manager.getMediaProjection(intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED), it) }
        if (projection == null) {
            finish("Android didn't allow screen sharing")
            return START_NOT_STICKY
        }
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                AppLog.write("Android ended the screen capture")
                main.post { finish("Sharing stopped") }
            }
        }, main)
        this.projection = projection
        CastStatus.set(true, "Connecting to $slotName…")
        connect()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (!stopped) AppLog.write("Service destroyed by Android while sharing")
        finish(null)
        super.onDestroy()
    }

    /** Swiping the app away from Recents doesn't stop sharing; the notification's Stop does. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        AppLog.write("App swiped away from Recents; still sharing")
    }

    override fun onTrimMemory(level: Int) {
        AppLog.write("Android asked for memory back (level $level)")
    }

    private fun connect() {
        AppLog.write("Connecting to $host:$port")
        link = Link(host, port).also { it.start() }
    }

    /**
     * One connection to the slot: hello, the answer, then a sender thread for queued messages and
     * a reader for pings until the connection ends. Reports back on the main thread.
     */
    private inner class Link(private val host: String, private val port: Int) {
        val outbox = LinkedBlockingQueue<ByteArray>()
        @Volatile private var socket: Socket? = null
        @Volatile private var closed = false

        fun start() = Thread({ run() }, "Mirror Wall connection").start()

        /** Hangs up, after a goodbye if `bye`. Safe from any thread. */
        fun close(bye: Boolean) {
            if (closed) return
            closed = true
            outbox.clear()
            if (bye) outbox.offer(CastProtocol.message(CastProtocol.BYE))
            outbox.offer(END)
            main.postDelayed({ closeSocket() }, 1000)
        }

        private fun closeSocket() {
            try {
                socket?.close()
            } catch (_: IOException) {
            }
        }

        /**
         * Connects the usual way; if that fails and the phone is on a Wi-Fi network Android isn't
         * using for the internet (one without internet, such as a computer's hotspot, while mobile
         * data carries everything else), tries again through that Wi-Fi.
         */
        private fun open(): Socket {
            try {
                return open(null)
            } catch (error: IOException) {
                val wifi = if (closed) null else otherWifi()
                if (wifi == null) throw error
                AppLog.write("Couldn't connect the usual way (${error.message}); trying through Wi-Fi")
                return open(wifi)
            }
        }

        private fun open(network: Network?): Socket {
            val socket = network?.socketFactory?.createSocket() ?: Socket()
            this.socket = socket
            if (closed) throw IOException("Stopped")
            socket.tcpNoDelay = true
            socket.sendBufferSize = 256 * 1024
            try {
                socket.connect(InetSocketAddress(host, port), 5000)
            } catch (error: IOException) {
                closeSocket()
                throw error
            }
            return socket
        }

        private fun run() {
            var gotWelcome = false
            try {
                val socket = open()
                val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
                val input = DataInputStream(socket.getInputStream())
                val hello = JSONObject()
                    .put("protocol", CastProtocol.VERSION)
                    .put("name", Phone.name(this@CastService))
                    .put("model", Phone.model())
                    .put("deviceID", Phone.id(this@CastService))
                output.write(CastProtocol.message(CastProtocol.HELLO, hello.toString().toByteArray()))
                output.flush()

                socket.soTimeout = 8000
                val answer = CastProtocol.readAnswer(input)
                socket.soTimeout = 0
                when (answer.type) {
                    CastProtocol.BUSY -> {
                        val reason = JSONObject(String(answer.payload)).optString("reason", "$slotName is busy.")
                        AppLog.write("Turned away: $reason")
                        main.post { turnedAway(this, reason) }
                        closeSocket()
                        return
                    }
                    CastProtocol.WELCOME -> {
                        gotWelcome = true
                        val welcome = JSONObject(String(answer.payload))
                        main.post { welcomed(this, welcome) }
                    }
                    else -> throw IOException("Mirror Wall answered unexpectedly")
                }

                Thread({ send(output) }, "Mirror Wall sender").start()
                while (true) {
                    val message = CastProtocol.read(input)
                    if (message.type == CastProtocol.PING) {
                        outbox.offer(CastProtocol.message(CastProtocol.PONG, message.payload))
                        // This Mirror Wall pings (0.90 didn't), so silence from now on means it's gone.
                        if (socket.soTimeout == 0) socket.soTimeout = SILENCE_MEANS_LOST_MS
                    }
                }
            } catch (caught: Exception) {
                val error = if (caught is SocketTimeoutException && gotWelcome) {
                    IOException("nothing heard from Mirror Wall for ${SILENCE_MEANS_LOST_MS / 1000} s")
                } else {
                    caught
                }
                closeSocket()
                if (!closed) {
                    AppLog.error("Connection to $host:$port ended", error)
                    main.post { lost(this, gotWelcome, error.message) }
                }
            }
        }

        // Sender thread: writes queued messages in order, flushing whenever it catches up.
        private fun send(output: BufferedOutputStream) {
            try {
                while (true) {
                    val message = outbox.take()
                    if (message === END) break
                    output.write(message)
                    if (outbox.isEmpty()) output.flush()
                }
                output.flush()
            } catch (_: Exception) {
            } finally {
                closeSocket()
            }
        }
    }

    /** A Wi-Fi network the phone is on that isn't the one Android sends traffic through, if any. */
    private fun otherWifi(): Network? {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val active = connectivity.activeNetwork
        @Suppress("DEPRECATION")
        return connectivity.allNetworks.firstOrNull {
            it != active && connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    // Main thread from here on, except where noted.

    private fun welcomed(link: Link, welcome: JSONObject) {
        if (link !== this.link || stopped) return
        lostAt = null
        slotName = welcome.optString("slot", slotName)
        frameRate = welcome.optInt("maxFrameRate", 30).coerceIn(15, 60)
        sharpPicture = welcome.optBoolean("sharpPicture", false)
        AppLog.write("Welcomed by $slotName (protocol ${welcome.optInt("protocol", 1)}, up to $frameRate fps, Sharper Picture ${if (sharpPicture) "on" else "off"})")
        startCapture()
    }

    private fun turnedAway(link: Link, reason: String) {
        if (link !== this.link) return
        finish(reason)
    }

    /** The connection failed or dropped. Reconnect if it had been sharing; otherwise give up. */
    private fun lost(link: Link, wasWelcomed: Boolean, error: String?) {
        if (link !== this.link || stopped) return
        this.link = null
        val now = SystemClock.elapsedRealtime()
        if (lostAt == null && !wasWelcomed && encoder == null) {
            finish("Couldn't reach $slotName ($error)")
            return
        }
        val since = lostAt ?: now.also { lostAt = it }
        if (now - since > RECONNECT_FOR_MS) {
            AppLog.write("Gave up reconnecting after ${RECONNECT_FOR_MS / 1000} s")
            finish("Lost the connection to $slotName")
            return
        }
        update("Reconnecting to $slotName…")
        AppLog.write("Reconnecting in ${RECONNECT_EVERY_MS / 1000} s")
        main.postDelayed({ if (!stopped && this.link == null) connect() }, RECONNECT_EVERY_MS)
    }

    /** Starts capturing, or adapts the running capture to what the slot asked for now. */
    private fun startCapture() {
        val projection = projection ?: return
        val size = captureSize()
        val current = encoder
        if (current == null || current.mime != size.mime || current.width != size.width ||
            current.height != size.height || current.frameRate != frameRate
        ) {
            replaceEncoder(size)
        } else {
            waitingForKeyframe = true
            current.requestKeyframe()
        }
        val encoder = encoder ?: return
        if (display == null) {
            display = projection.createVirtualDisplay(
                "Mirror Wall", size.width, size.height, size.dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, encoder.inputSurface, null, main,
            )
            getSystemService(DisplayManager::class.java).registerDisplayListener(rotationListener, main)
            val screenEvents = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(screenReceiver, screenEvents, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(screenReceiver, screenEvents)
            }
            main.postDelayed(heartbeat, 2000)
            keepScreenOn()
            keepAwake()
        }
        if (screenOff) link?.outbox?.offer(CastProtocol.message(CastProtocol.PAUSED))
        sentTurns = -1
        sendOrientation()
        update(if (screenOff) "Screen off: $slotName shows it as paused" else "Sharing to $slotName")
    }

    /**
     * Keeps the screen from timing out while sharing, as a phone that locks pauses the slot. Only a
     * screen wake lock can do this from a service; it's deprecated but still honoured, and needs
     * no prompt. The power button still turns the screen off.
     */
    private fun keepScreenOn() {
        if (!Phone.keepsScreenOn(this) || screenLock != null) return
        @Suppress("DEPRECATION")
        screenLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ON_AFTER_RELEASE, "MirrorWallCast:sharing")
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    /**
     * Keeps the processor running and Wi-Fi out of power saving while sharing, so the phone keeps
     * sending with the screen off and Wi-Fi doesn't add delay between pictures.
     */
    private fun keepAwake() {
        if (cpuLock == null) {
            cpuLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MirrorWallCast:sending")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wifiLock == null) {
            wifiLock = getSystemService(WifiManager::class.java)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "MirrorWallCast:sending")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    /** A new encoder for `size`, drawn into by the virtual display (if there is one yet). */
    private fun replaceEncoder(size: CaptureSize) {
        val display = display
        display?.surface = null
        encoder?.stop()
        encoder = null
        AppLog.write("Encoding ${if (size.mime == MediaFormat.MIMETYPE_VIDEO_HEVC) "H.265" else "H.264"} ${size.width}×${size.height} at up to $frameRate fps")
        val encoder = try {
            ScreenEncoder(size.mime, size.width, size.height, frameRate, ::picture) { error ->
                AppLog.error("The video encoder stopped", error)
                main.post { finish("The video encoder stopped (${error.message})") }
            }
        } catch (error: Exception) {
            AppLog.error("Couldn't start the video encoder", error)
            finish("Couldn't start the video encoder (${error.message})")
            return
        }
        this.encoder = encoder
        bitRate = encoder.bitRate
        if (display != null) {
            display.resize(size.width, size.height, size.dpi)
            display.surface = encoder.inputSurface
        }
        waitingForKeyframe = true
    }

    /** Encoder thread: queues a picture, dropping the backlog if the network can't keep up. */
    private fun picture(captureMicros: Long, prefix: ByteArray?, data: ByteBuffer, isKeyframe: Boolean) {
        val outbox = link?.outbox
        if (screenOff || outbox == null) {
            waitingForKeyframe = true
            return
        }
        if (outbox.size > MAX_QUEUED) {
            // Only pictures are dropped: heartbeats, pongs, paused and orientation must still arrive.
            val before = outbox.size
            outbox.removeIf { it.isNotEmpty() && it[0] == CastProtocol.VIDEO.toByte() }
            AppLog.write("Network falling behind: dropped ${before - outbox.size} queued pictures")
            waitingForKeyframe = true
            main.post { networkFellBehind() }
        }
        if (waitingForKeyframe) {
            if (!isKeyframe) {
                encoder?.requestKeyframe()
                return
            }
            waitingForKeyframe = false
        }
        outbox.offer(CastProtocol.video(captureMicros, prefix, data))
    }

    /** Pictures had to be dropped: send smaller ones, down to a quarter of the usual bit rate. */
    private fun networkFellBehind() {
        val encoder = encoder ?: return
        bitRateChangedAt = SystemClock.elapsedRealtime()
        val lower = maxOf(encoder.bitRate / 4, bitRate * 6 / 10)
        if (lower == bitRate) return
        bitRate = lower
        encoder.changeBitRate(lower)
        AppLog.write("Lowered the picture's bit rate to ${lower / 1000} kbps")
    }

    /** Once the network has kept up for a while, works back up to the usual bit rate in steps. */
    private fun restoreBitRate() {
        val encoder = encoder ?: return
        if (bitRate >= encoder.bitRate || link == null) return
        val now = SystemClock.elapsedRealtime()
        if (now - bitRateChangedAt < RAISE_BIT_RATE_AFTER_MS) return
        bitRateChangedAt = now
        bitRate = minOf(encoder.bitRate, bitRate * 5 / 4)
        encoder.changeBitRate(bitRate)
        AppLog.write("Raised the picture's bit rate to ${bitRate / 1000} kbps")
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            link?.outbox?.offer(CastProtocol.message(CastProtocol.HEARTBEAT))
            restoreBitRate()
            // A turn the display listener missed is caught here.
            matchScreenShape()
            main.postDelayed(this, 2000)
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    AppLog.write("Screen off")
                    screenOff = true
                    link?.outbox?.offer(CastProtocol.message(CastProtocol.PAUSED))
                    if (lostAt == null) update("Screen off: $slotName shows it as paused")
                }
                Intent.ACTION_SCREEN_ON -> {
                    AppLog.write("Screen on")
                    screenOff = false
                    // The power button released the hold on the screen; take it again.
                    screenLock?.let { if (!it.isHeld) it.acquire() }
                    link?.outbox?.offer(CastProtocol.message(CastProtocol.RESUMED))
                    waitingForKeyframe = true
                    encoder?.requestKeyframe()
                    if (lostAt == null) update("Sharing to $slotName")
                }
            }
        }
    }

    /**
     * Turning the phone changes the screen's shape: a new encoder at the new size. The display
     * can report the change before its size has turned (pressing Home in landscape, when the
     * home screen turns the phone back to portrait), so the shape is checked again a moment later.
     */
    private val rotationListener = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY) return
            matchScreenShape()
            main.removeCallbacks(recheckShape)
            main.postDelayed(recheckShape, 300)
            main.postDelayed(recheckShape, 1000)
        }

        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
    }

    private val recheckShape = Runnable { matchScreenShape() }

    /** Quarter turns left last told to Mirror Wall; -1 when it hasn't been told on this connection. */
    private var sentTurns = -1

    /** Tells Mirror Wall which way up the phone is, so its frame can turn the same way. */
    private fun sendOrientation() {
        @Suppress("DEPRECATION")
        val turns = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: return
        val outbox = link?.outbox ?: return
        if (turns == sentTurns) return
        sentTurns = turns
        outbox.offer(CastProtocol.message(CastProtocol.ORIENTATION, byteArrayOf(turns.toByte())))
    }

    /** A new encoder if the screen is now a different size from what's being sent. */
    private fun matchScreenShape() {
        if (stopped) return
        sendOrientation()
        val old = encoder ?: return
        val size = captureSize()
        if (size.width == old.width && size.height == old.height) return
        AppLog.write("Screen turned: ${old.width}×${old.height} → ${size.width}×${size.height}")
        replaceEncoder(size)
    }

    private class CaptureSize(val mime: String, val width: Int, val height: Int, val dpi: Int)

    /**
     * The screen scaled to fit the codec's longest side, in multiples of 16 (encoders prefer it).
     * H.265 when Sharper Picture is on and the phone can encode it at that size.
     */
    private fun captureSize(): CaptureSize {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).getRealMetrics(metrics)
        fun fit(longSide: Int): Pair<Int, Int> {
            val scale = minOf(1.0, longSide.toDouble() / maxOf(metrics.widthPixels, metrics.heightPixels))
            fun side(pixels: Int) = maxOf(16, (pixels * scale).toInt() / 16 * 16)
            return side(metrics.widthPixels) to side(metrics.heightPixels)
        }
        if (sharpPicture) {
            val (width, height) = fit(MAX_LONG_SIDE_HEVC)
            if (ScreenEncoder.canEncodeHEVC(width, height)) {
                return CaptureSize(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height, metrics.densityDpi)
            }
        }
        val (width, height) = fit(MAX_LONG_SIDE)
        return CaptureSize(MediaFormat.MIMETYPE_VIDEO_AVC, width, height, metrics.densityDpi)
    }

    /** Ends sharing and the service. `reason` is shown in the app; null when nothing needs saying. */
    private fun finish(reason: String?) {
        if (stopped) return
        stopped = true
        AppLog.write("Stopped sharing${reason?.let { ": $it" } ?: ""}")
        main.removeCallbacks(heartbeat)
        main.removeCallbacks(recheckShape)
        if (display != null) {
            getSystemService(DisplayManager::class.java).unregisterDisplayListener(rotationListener)
            try {
                unregisterReceiver(screenReceiver)
            } catch (_: IllegalArgumentException) {
            }
        }
        screenLock?.let { if (it.isHeld) it.release() }
        screenLock = null
        cpuLock?.let { if (it.isHeld) it.release() }
        cpuLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        display?.release()
        display = null
        encoder?.stop()
        encoder = null
        projection?.stop()
        projection = null
        link?.close(bye = true)
        link = null
        CastStatus.set(false, reason ?: "")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun update(text: String) {
        CastStatus.set(true, text)
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, CastService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_cast)
            .setContentTitle("Mirror Wall Cast")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }
}
