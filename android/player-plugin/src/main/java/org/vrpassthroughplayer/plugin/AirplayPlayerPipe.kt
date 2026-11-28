package org.vrpassthroughplayer.plugin

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd

/**
 * One owned, bounded, non-seekable feed for the ordinary MPV player.
 *
 * The write end stays blocking: `Os.fcntlInt` is only public from API 30 and
 * Android 10 (iQIYI A091) denies it, which used to fail every expand. Instead
 * each write waits for POLLOUT with a short timeout and writes at most
 * PIPE_BUF bytes, which a pipe with free space always accepts without
 * blocking, so close() still stops the writer within one poll period.
 */
internal class AirplayPlayerPipe : AutoCloseable {
    private val ends = ParcelFileDescriptor.createPipe()
    private val queue = java.util.ArrayDeque<ByteArray>()
    private val lock = Object()
    private var queuedBytes = 0
    private var claimed = false
    @Volatile var closed = false; private set

    init {
        try { Thread({ write() }, "AirPlay-Player-Pipe").apply { isDaemon = true; start() } }
        catch (error: Throwable) { closed = true; ends.forEach { runCatching { it.close() } }; throw error }
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
                    if (!writable()) continue
                    try { offset += Os.write(ends[1].fileDescriptor, bytes, offset, minOf(PIPE_BUF, bytes.size - offset)) }
                    catch (error: ErrnoException) { if (error.errno != OsConstants.EINTR) throw error }
                }
            }
        } catch (_: Exception) { close() }
        finally { runCatching { ends[1].close() } }
    }

    private fun writable(): Boolean {
        val fd = StructPollfd().apply { fd = ends[1].fileDescriptor; events = OsConstants.POLLOUT.toShort() }
        try { if (Os.poll(arrayOf(fd), POLL_MS) == 0) return false }
        catch (error: ErrnoException) { if (error.errno == OsConstants.EINTR) return false; throw error }
        val bad = OsConstants.POLLERR or OsConstants.POLLHUP or OsConstants.POLLNVAL
        if (fd.revents.toInt() and bad != 0) throw ErrnoException("poll", OsConstants.EPIPE)
        return fd.revents.toInt() and OsConstants.POLLOUT != 0
    }

    override fun close() = synchronized(lock) {
        closed = true; queue.clear(); queuedBytes = 0; lock.notifyAll()
        if (!claimed) runCatching { ends[0].close() }
    }
}

private const val PIPE_BUF = 4096
private const val POLL_MS = 50
