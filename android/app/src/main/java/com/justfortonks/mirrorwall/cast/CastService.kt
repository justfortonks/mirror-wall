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
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Display
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
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
 * screen as H.264 until stopped, the connection drops, or Android ends the capture.
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
        /** Longest side sent; matches what iPhones send for H.264. */
        private const val MAX_LONG_SIDE = 1920
        /** Pictures waiting to go out before the oldest are dropped to stay live. */
        private const val MAX_QUEUED = 12
        private val END = ByteArray(0)
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var encoder: ScreenEncoder? = null
    private var socket: Socket? = null
    private val outbox = LinkedBlockingQueue<ByteArray>()
    private var slotName = ""
    private var frameRate = 30
    private var stopped = false
    @Volatile private var screenOff = false
    @Volatile private var waitingForKeyframe = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            finish("Stopped sharing")
            return START_NOT_STICKY
        }
        if (projection != null) return START_NOT_STICKY // already sharing

        val host = intent.getStringExtra(EXTRA_HOST) ?: return START_NOT_STICKY
        val port = intent.getIntExtra(EXTRA_PORT, 0)
        slotName = intent.getStringExtra(EXTRA_SLOT) ?: host
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
                main.post { finish("Sharing stopped") }
            }
        }, main)
        this.projection = projection
        CastStatus.set(true, "Connecting to $slotName…")
        Thread({ connect(host, port) }, "Mirror Wall connection").start()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        finish(null)
        super.onDestroy()
    }

    // Connection thread: hello, the answer, then reading until the connection ends.
    private fun connect(host: String, port: Int) {
        try {
            val socket = Socket()
            socket.tcpNoDelay = true
            socket.sendBufferSize = 256 * 1024
            socket.connect(InetSocketAddress(host, port), 5000)
            main.post { if (stopped) socket.close() else this.socket = socket }
            val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
            val input = DataInputStream(socket.getInputStream())
            val hello = JSONObject()
                .put("protocol", CastProtocol.VERSION)
                .put("name", Phone.name(this))
                .put("model", Phone.model())
                .put("deviceID", Phone.id(this))
            output.write(CastProtocol.message(CastProtocol.HELLO, hello.toString().toByteArray()))
            output.flush()

            socket.soTimeout = 8000
            val answer = CastProtocol.read(input)
            socket.soTimeout = 0
            when (answer.type) {
                CastProtocol.BUSY -> {
                    val reason = JSONObject(String(answer.payload)).optString("reason", "$slotName is busy.")
                    main.post { finish(reason) }
                    socket.close()
                    return
                }
                CastProtocol.WELCOME -> {
                    val welcome = JSONObject(String(answer.payload))
                    main.post {
                        slotName = welcome.optString("slot", slotName)
                        frameRate = welcome.optInt("maxFrameRate", 30).coerceIn(15, 60)
                        startCapture()
                    }
                }
                else -> throw IOException("Mirror Wall answered unexpectedly")
            }

            Thread({ send(output) }, "Mirror Wall sender").start()
            // Nothing else is expected from Mirror Wall yet; this notices when it hangs up.
            while (true) CastProtocol.read(input)
        } catch (error: Exception) {
            main.post {
                if (!stopped) finish(if (projection != null && encoder != null) "Mirror Wall ended the connection" else "Couldn't reach $slotName (${error.message})")
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
            main.post { if (!stopped) finish("Lost the connection to $slotName") }
        } finally {
            try {
                socket?.close()
            } catch (_: IOException) {
            }
        }
    }

    // Main thread from here on, except where noted.

    private fun startCapture() {
        if (stopped) return
        val projection = projection ?: return
        val (width, height, dpi) = captureSize()
        val encoder = makeEncoder(width, height) ?: return
        display = projection.createVirtualDisplay(
            "Mirror Wall", width, height, dpi,
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
        update("Sharing to $slotName")
    }

    private fun makeEncoder(width: Int, height: Int): ScreenEncoder? = try {
        ScreenEncoder(width, height, frameRate, ::picture) { error ->
            main.post { finish("The video encoder stopped (${error.message})") }
        }.also { encoder = it }
    } catch (error: Exception) {
        finish("Couldn't start the video encoder (${error.message})")
        null
    }

    /** Encoder thread: queues a picture, dropping the backlog if the network can't keep up. */
    private fun picture(captureMicros: Long, prefix: ByteArray?, data: ByteBuffer, isKeyframe: Boolean) {
        if (screenOff) return
        if (outbox.size > MAX_QUEUED) {
            outbox.clear()
            waitingForKeyframe = true
            encoder?.requestKeyframe()
        }
        if (waitingForKeyframe) {
            if (!isKeyframe) return
            waitingForKeyframe = false
        }
        outbox.offer(CastProtocol.video(captureMicros, prefix, data))
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            outbox.offer(CastProtocol.message(CastProtocol.HEARTBEAT))
            main.postDelayed(this, 2000)
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOff = true
                    outbox.offer(CastProtocol.message(CastProtocol.PAUSED))
                    update("Screen off: $slotName shows it as paused")
                }
                Intent.ACTION_SCREEN_ON -> {
                    screenOff = false
                    outbox.offer(CastProtocol.message(CastProtocol.RESUMED))
                    waitingForKeyframe = true
                    encoder?.requestKeyframe()
                    update("Sharing to $slotName")
                }
            }
        }
    }

    /** Turning the phone changes the screen's shape: a new encoder at the new size. */
    private val rotationListener = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY) return
            val old = encoder ?: return
            val (width, height, dpi) = captureSize()
            if (width == old.width && height == old.height) return
            val display = display ?: return
            display.surface = null
            old.stop()
            encoder = null
            val encoder = makeEncoder(width, height) ?: return
            display.resize(width, height, dpi)
            display.surface = encoder.inputSurface
            waitingForKeyframe = true
        }

        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
    }

    /** The screen's size scaled to fit [MAX_LONG_SIDE], in multiples of 16 (encoders prefer it). */
    private fun captureSize(): Triple<Int, Int, Int> {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).getRealMetrics(metrics)
        val scale = minOf(1.0, MAX_LONG_SIDE.toDouble() / maxOf(metrics.widthPixels, metrics.heightPixels))
        fun fit(side: Int) = maxOf(16, (side * scale).toInt() / 16 * 16)
        return Triple(fit(metrics.widthPixels), fit(metrics.heightPixels), metrics.densityDpi)
    }

    /** Ends sharing and the service. `reason` is shown in the app; null when nothing needs saying. */
    private fun finish(reason: String?) {
        if (stopped) return
        stopped = true
        main.removeCallbacks(heartbeat)
        if (encoder != null || display != null) {
            getSystemService(DisplayManager::class.java).unregisterDisplayListener(rotationListener)
            try {
                unregisterReceiver(screenReceiver)
            } catch (_: IllegalArgumentException) {
            }
        }
        display?.release()
        display = null
        encoder?.stop()
        encoder = null
        projection?.stop()
        projection = null
        // Say goodbye if connected; the sender closes the connection once it's out.
        outbox.clear()
        outbox.offer(CastProtocol.message(CastProtocol.BYE))
        outbox.offer(END)
        val socket = socket
        main.postDelayed({
            try {
                socket?.close()
            } catch (_: IOException) {
            }
        }, 1000)
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
