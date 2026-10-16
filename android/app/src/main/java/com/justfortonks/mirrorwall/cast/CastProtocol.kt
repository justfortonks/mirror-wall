package com.justfortonks.mirrorwall.cast

import java.io.DataInputStream
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Mirror Wall Cast, as the Mac and Windows apps speak it (docs/mirror-wall-cast.md).
 *
 * Every message is a one-byte type, a four-byte big-endian payload length, then the payload.
 */
object CastProtocol {
    /**
     * The newest protocol version this app speaks. Read "Compatibility" in docs/mirror-wall-cast.md
     * before changing anything an older or newer Mirror Wall relies on.
     */
    const val VERSION = 1

    // Phone to Mirror Wall.
    const val HELLO = 0x01
    const val VIDEO = 0x02
    const val PAUSED = 0x03
    const val RESUMED = 0x04
    const val HEARTBEAT = 0x05
    const val BYE = 0x06
    const val PONG = 0x07
    /** One byte: quarter turns left from upright (Display.getRotation()), sent when it changes. */
    const val ORIENTATION = 0x08

    // Mirror Wall to phone.
    const val WELCOME = 0x81
    const val BUSY = 0x82
    const val PING = 0x84

    const val SERVICE_TYPE = "_mirrorwall._tcp"
    private const val MAX_PAYLOAD = 16 shl 20

    fun message(type: Int, payload: ByteArray = ByteArray(0)): ByteArray =
        ByteBuffer.allocate(5 + payload.size)
            .put(type.toByte())
            .putInt(payload.size)
            .put(payload)
            .array()

    /** One encoded picture: capture time in microseconds, then the H.264 or H.265 access unit (Annex B). */
    fun video(captureMicros: Long, prefix: ByteArray?, data: ByteBuffer): ByteArray {
        val prefixSize = prefix?.size ?: 0
        val length = 8 + prefixSize + data.remaining()
        val buffer = ByteBuffer.allocate(5 + length)
            .put(VIDEO.toByte())
            .putInt(length)
            .putLong(captureMicros)
        if (prefix != null) buffer.put(prefix)
        buffer.put(data)
        return buffer.array()
    }

    class Message(val type: Int, val payload: ByteArray)

    @Throws(IOException::class)
    fun read(input: DataInputStream): Message {
        val type = input.readUnsignedByte()
        val length = input.readInt()
        if (length < 0 || length > MAX_PAYLOAD) throw IOException("Mirror Wall sent something unexpected")
        val payload = ByteArray(length)
        input.readFully(payload)
        return Message(type, payload)
    }

    /** Mirror Wall's answer to hello: welcome or busy. Messages a newer Mirror Wall might send first are skipped. */
    @Throws(IOException::class)
    fun readAnswer(input: DataInputStream): Message {
        while (true) {
            val message = read(input)
            if (message.type == WELCOME || message.type == BUSY) return message
        }
    }
}
