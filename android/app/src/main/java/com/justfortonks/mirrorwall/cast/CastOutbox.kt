package com.justfortonks.mirrorwall.cast

import java.util.ArrayDeque
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Bounded outgoing work. Closing wakes an idle sender and rejects late encoder callbacks. */
internal class CastOutbox(private val capacity: Int = 32) {
    private val lock = ReentrantLock()
    private val available = lock.newCondition()
    private val messages = ArrayDeque<ByteArray>()
    private var closed = false
    val size: Int get() = lock.withLock { messages.size }

    fun offer(message: ByteArray): Boolean = lock.withLock {
        if (closed || messages.size >= capacity) return false
        messages.addLast(message)
        available.signal()
        true
    }

    fun clear() = lock.withLock { if (!closed) messages.clear() }

    fun take(): ByteArray? = lock.withLock {
        while (messages.isEmpty() && !closed) available.await()
        messages.pollFirst()
    }

    fun close(goodbye: ByteArray? = null) = lock.withLock {
        if (closed) return
        messages.clear()
        if (goodbye != null) messages.addLast(goodbye)
        closed = true
        available.signalAll()
    }
}
