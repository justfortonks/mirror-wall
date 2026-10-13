package com.justfortonks.mirrorwall.cast

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The app's log, kept on the phone for troubleshooting: connections, what the slot asked for,
 * encoder changes, the screen turning off and on, and why sharing ended. Shared from the app's
 * "Share Log" button. Two files of up to 512 KB each, so it never grows past about a megabyte.
 */
object AppLog {
    private const val TAG = "MirrorWallCast"
    private const val MAX_BYTES = 512 * 1024
    private val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    private var folder: File? = null

    /** Call once at startup, before logging. Also logs crashes, then lets Android handle them. */
    @Synchronized
    fun start(context: Context) {
        if (folder != null) return
        folder = File(context.filesDir, "logs").apply { mkdirs() }
        val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName
        write("Mirror Wall Cast $version on ${Phone.model()}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            write("Crashed on ${thread.name}: ${Log.getStackTraceString(error)}")
            previous?.uncaughtException(thread, error)
        }
    }

    fun write(line: String) {
        Log.i(TAG, line)
        append(line)
    }

    fun error(line: String, error: Throwable? = null) {
        Log.w(TAG, line, error)
        append(line + (error?.let { ": ${it.javaClass.simpleName} ${it.message}" } ?: ""))
    }

    /** The current log file, for sharing; the older one is put in front of it first. */
    @Synchronized
    fun snapshot(context: Context): File {
        val folder = folder ?: File(context.filesDir, "logs").apply { mkdirs() }
        val out = File(folder, "MirrorWallCast-log.txt")
        out.writeText("")
        for (name in listOf("log.1.txt", "log.txt")) {
            val file = File(folder, name)
            if (file.exists()) out.appendBytes(file.readBytes())
        }
        return out
    }

    /** The last lines, newest last, to show in the app. */
    @Synchronized
    fun tail(lines: Int): String {
        val file = folder?.let { File(it, "log.txt") } ?: return ""
        if (!file.exists()) return ""
        return file.readLines().takeLast(lines).joinToString("\n")
    }

    @Synchronized
    private fun append(line: String) {
        val folder = folder ?: return
        val text = "${time.format(Date())}  $line\n"
        try {
            val file = File(folder, "log.txt")
            if (file.length() > MAX_BYTES) {
                File(folder, "log.1.txt").delete()
                file.renameTo(File(folder, "log.1.txt"))
            }
            FileWriter(file, true).use { it.write(text) }
        } catch (_: Exception) {
        }
    }
}
