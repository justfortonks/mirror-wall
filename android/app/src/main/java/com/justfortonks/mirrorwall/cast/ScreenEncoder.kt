package com.justfortonks.mirrorwall.cast

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.view.Surface
import java.nio.ByteBuffer

/**
 * The phone's hardware H.264 or H.265 encoder, fed by a surface the screen is drawn into.
 *
 * Each picture comes out on the encoder's own thread through [onPicture], keyframes with the
 * stream's parameter sets in front so Mirror Wall can start decoding at any of them.
 */
class ScreenEncoder(
    val mime: String,
    val width: Int,
    val height: Int,
    val frameRate: Int,
    private val onPicture: (captureMicros: Long, prefix: ByteArray?, data: ByteBuffer, isKeyframe: Boolean) -> Unit,
    private val onError: (Exception) -> Unit,
) {
    private val codec = MediaCodec.createEncoderByType(mime)
    val inputSurface: Surface
    @Volatile private var running = true
    private var parameterSets: ByteArray? = null
    private val thread: Thread

    init {
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate(width, height, frameRate, mime))
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, frameRate.toFloat())
            // A keyframe every few seconds; more are asked for when frames have to be dropped.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5)
            // A still screen draws nothing; repeat the last picture so Mirror Wall keeps hearing
            // from the phone and a newly opened decoder gets something to show.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 250_000)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // real time
            if (android.os.Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LATENCY, 1)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()
        thread = Thread({ drain() }, "Mirror Wall encoder").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    /** Asks for a keyframe now, e.g. after frames were dropped or the screen came back on. */
    fun requestKeyframe() {
        if (!running) return
        try {
            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: IllegalStateException) {
        }
    }

    fun stop() {
        running = false
        thread.join(1000)
        try {
            codec.stop()
        } catch (_: IllegalStateException) {
        }
        codec.release()
        inputSurface.release()
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = codec.dequeueOutputBuffer(info, 100_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // Some encoders give the parameter sets only here, not as a config buffer.
                    val format = codec.outputFormat
                    val sets = listOf("csd-0", "csd-1", "csd-2").mapNotNull { key ->
                        format.getByteBuffer(key)?.let { ByteArray(it.remaining()).also { bytes -> it.get(bytes) } }
                    }
                    if (sets.isNotEmpty()) parameterSets = sets.reduce { a, b -> a + b }
                }
                if (index < 0) continue
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        parameterSets = ByteArray(info.size).also { buffer.get(it) }
                    } else {
                        val isKeyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        onPicture(info.presentationTimeUs, if (isKeyframe) parameterSets else null, buffer, isKeyframe)
                    }
                }
                codec.releaseOutputBuffer(index, false)
            }
        } catch (error: Exception) {
            if (running) onError(error)
        }
    }

    companion object {
        /**
         * About 0.15 bits a pixel for H.264, which keeps text sharp, between 4 and 16 Mbps; H.265
         * gets the same budget (iPhones send it at about 20 Mbps), so its larger picture is as clean.
         */
        fun bitRate(width: Int, height: Int, frameRate: Int, mime: String): Int {
            val max = if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) 20_000_000 else 16_000_000
            return (width.toLong() * height * frameRate * 15 / 100).coerceIn(4_000_000, max.toLong()).toInt()
        }

        /** True if the phone has an H.265 encoder that takes a picture this size. */
        fun canEncodeHEVC(width: Int, height: Int): Boolean =
            android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) } &&
                    info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC).videoCapabilities.isSizeSupported(width, height)
            }
    }
}
