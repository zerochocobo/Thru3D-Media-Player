package org.vrpassthroughplayer.plugin

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants

/** One owned, bounded, non-seekable feed for the ordinary MPV player. */
internal class AirplayPlayerPipe : AutoCloseable {
    private val ends = ParcelFileDescriptor.createPipe()
    private val queue = java.util.ArrayDeque<ByteArray>()
    private val lock = Object()
    private var queuedBytes = 0
    private var claimed = false
    @Volatile var closed = false; private set

    init {
        Os.fcntlInt(ends[1].fileDescriptor, OsConstants.F_SETFL, OsConstants.O_NONBLOCK)
        Thread({ write() }, "AirPlay-Player-Pipe").apply { isDaemon = true; start() }
    }

    fun claim(): ParcelFileDescriptor? = synchronized(lock) {
        if (closed || claimed) null else ParcelFileDescriptor.dup(ends[0].fileDescriptor).also {
            claimed = true; ends[0].close()
        }
    }

    fun offer(bytes: ByteArray) = synchronized(lock) {
        if (closed || bytes.isEmpty()) return
        if (queuedBytes + bytes.size > 4 * 1024 * 1024) { close(); return }
        queue.addLast(bytes); queuedBytes += bytes.size; lock.notifyAll()
    }

    private fun write() {
        try {
            while (!closed) {
                val bytes = synchronized(lock) {
                    while (queue.isEmpty() && !closed) lock.wait()
                    queue.pollFirst()?.also { queuedBytes -= it.size }
                } ?: continue
                var offset = 0
                while (offset < bytes.size && !closed) {
                    try { offset += Os.write(ends[1].fileDescriptor, bytes, offset, bytes.size - offset) }
                    catch (error: ErrnoException) {
                        if (error.errno != OsConstants.EAGAIN && error.errno != OsConstants.EINTR) throw error
                        Thread.sleep(4)
                    }
                }
            }
        } catch (_: Exception) { close() }
        finally { runCatching { ends[1].close() } }
    }

    override fun close() = synchronized(lock) {
        closed = true; queue.clear(); queuedBytes = 0; lock.notifyAll()
        if (!claimed) runCatching { ends[0].close() }
    }
}
