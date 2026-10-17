package com.justfortonks.mirrorwall.cast

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CastOutboxTest {
    @Test fun closeReleasesIdleSenderAndRejectsLateFrames() {
        val outbox = CastOutbox()
        val entered = CountDownLatch(1)
        val done = CountDownLatch(1)
        val sender = Thread {
            entered.countDown()
            assertNull(outbox.take())
            done.countDown()
        }
        sender.isDaemon = true
        sender.start()
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        outbox.close()
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertFalse(outbox.offer(byteArrayOf(1)))
    }

    @Test fun queueIsBoundedAndGoodbyeSurvivesLateClear() {
        val outbox = CastOutbox(2)
        assertTrue(outbox.offer(byteArrayOf(1)))
        assertTrue(outbox.offer(byteArrayOf(2)))
        assertFalse(outbox.offer(byteArrayOf(3)))
        val goodbye = CastProtocol.message(CastProtocol.BYE)
        outbox.close(goodbye)
        outbox.clear() // racing encoder must not remove the terminal message
        assertArrayEquals(goodbye, outbox.take())
        assertNull(outbox.take())
    }
}
