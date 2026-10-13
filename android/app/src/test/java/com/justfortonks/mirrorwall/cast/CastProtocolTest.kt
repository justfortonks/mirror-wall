package com.justfortonks.mirrorwall.cast

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.nio.ByteBuffer

/**
 * This app has to keep working with every Mirror Wall that speaks the protocol, older or newer
 * (see "Compatibility" in docs/mirror-wall-cast.md). These hold version 1 as Mirror Wall 0.90 sent
 * and expected it.
 */
class CastProtocolTest {
    private fun stream(vararg messages: ByteArray) =
        DataInputStream(ByteArrayInputStream(messages.fold(ByteArray(0)) { all, next -> all + next }))

    @Test
    fun framesMessagesAsVersionOne() {
        assertArrayEquals(byteArrayOf(0x05, 0, 0, 0, 0), CastProtocol.message(CastProtocol.HEARTBEAT))
        assertArrayEquals(byteArrayOf(0x07, 0, 0, 0, 2, 9, 8), CastProtocol.message(CastProtocol.PONG, byteArrayOf(9, 8)))
        val video = CastProtocol.video(1_000_000L, byteArrayOf(0, 0, 0, 1), ByteBuffer.wrap(byteArrayOf(0x65, 1)))
        assertArrayEquals(
            byteArrayOf(0x02, 0, 0, 0, 14, 0, 0, 0, 0, 0, 0x0F, 0x42, 0x40, 0, 0, 0, 1, 0x65, 1),
            video,
        )
    }

    @Test
    fun readsAnOlderMirrorWallsWelcome() {
        val payload = """{"slot":"Mirror Wall 1","maxFrameRate":30,"sharpPicture":false}""".toByteArray()
        val answer = CastProtocol.readAnswer(stream(CastProtocol.message(CastProtocol.WELCOME, payload)))
        assertEquals(CastProtocol.WELCOME, answer.type)
        val welcome = JSONObject(String(answer.payload))
        assertEquals(1, welcome.optInt("protocol", 1))
        assertEquals(30, welcome.optInt("maxFrameRate", 30))
    }

    @Test
    fun skipsMessagesANewerMirrorWallSendsBeforeItsAnswer() {
        val payload = """{"protocol":4,"slot":"S","maxFrameRate":60,"somethingNew":true}""".toByteArray()
        val answer = CastProtocol.readAnswer(
            stream(
                CastProtocol.message(0x90, byteArrayOf(1, 2, 3)),
                CastProtocol.message(CastProtocol.WELCOME, payload),
            ),
        )
        assertEquals(CastProtocol.WELCOME, answer.type)
        assertEquals(60, JSONObject(String(answer.payload)).optInt("maxFrameRate", 30))
    }
}
