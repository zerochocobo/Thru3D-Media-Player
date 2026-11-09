package org.vrpassthroughplayer.plugin

import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.CancellationException
import org.codelibs.jcifs.smb.impl.SmbAuthException
import org.codelibs.jcifs.smb.impl.SmbException
import org.codelibs.jcifs.smb.util.transport.TransportException

/** Replace a failed server's pool, never a newer pool published by another reader. */
internal class SmbConnection<T : Any>(private val create: () -> T, private val dispose: (T) -> Unit) {
    private var value: T? = null
    private var closed = false
    @Synchronized fun get(): T {
        if (closed) throw IOException("SMB connection retired")
        return value ?: create().also { value = it }
    }
    @Synchronized fun isCurrent(expected: T) = !closed && value === expected
    fun invalidate(expected: T) {
        val removed = synchronized(this) {
            if (value !== expected) false else { value = null; true }
        }
        if (removed) runCatching { dispose(expected) }
    }
    fun close() {
        val previous = synchronized(this) { closed = true; value.also { value = null } }
        previous?.let { runCatching { dispose(it) } }
    }
    /** Only read-only operations may be replayed. Also evict after the final failed attempt. */
    fun <R> read(action: (T) -> R): R {
        repeat(2) { attempt ->
            if (Thread.currentThread().isInterrupted) throw InterruptedIOException("SMB read cancelled")
            val current = get()
            try { return action(current) } catch (error: Exception) {
                if (!SmbRecovery.retryable(error)) throw error
                invalidate(current)
                if (attempt == 1) throw error
            }
        }
        error("Unreachable")
    }
}

internal object SmbRecovery {
    private val statuses = setOf(0xC0000008.toInt(), /* INVALID_HANDLE */
        0xC00000B5.toInt(), /* IO_TIMEOUT */ 0xC00000C9.toInt(), /* NETWORK_NAME_DELETED */
        0xC0000203.toInt(), /* USER_SESSION_DELETED */ 0xC000020C.toInt(), /* CONNECTION_DISCONNECTED */
        0xC000020D.toInt(), /* CONNECTION_RESET */ 0xC0000128.toInt()) /* FILE_CLOSED */

    fun retryable(error: Throwable): Boolean {
        if (Thread.currentThread().isInterrupted) return false
        val chain = generateSequence(error) { it.cause }.take(16).toList()
        if (chain.any { it is CancellationException || it is InterruptedException || it is SmbAuthException ||
                it is InterruptedIOException && it !is SocketTimeoutException }) return false
        // Unknown errors, permissions, missing files and protocol/security failures are not retried.
        val smb = chain.filterIsInstance<SmbException>()
        if (smb.any { it.ntStatus !in statuses && it.ntStatus != 0xC0000001.toInt() }) return false
        return smb.any { it.ntStatus in statuses } || chain.any {
            it is SocketException || it is SocketTimeoutException || it is EOFException ||
                it is TransportException
        }
    }
}

/** A retry always reopens read-only and seeks to the exact original byte offset. */
internal class SmbRecoveringReader<T : Any>(private val connection: SmbConnection<T>,
    private val open: (T) -> StreamSource.Reader) : StreamSource.Reader {
    private var active: Pair<T, StreamSource.Reader>? = null
    @Volatile private var closed = false

    private fun checkOpen() {
        if (closed || Thread.currentThread().isInterrupted) throw InterruptedIOException("SMB read cancelled")
    }
    private fun release() {
        val previous = synchronized(this) { active.also { active = null } }
        previous?.let { runCatching { it.second.close() } }
    }
    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
        repeat(2) { attempt ->
            checkOpen()
            val current = connection.get()
            try {
                val previous = synchronized(this) { active }
                if (previous != null && (previous.first !== current || !connection.isCurrent(previous.first))) release()
                val reader = synchronized(this) { active?.second } ?: open(current).also { opened ->
                    val accepted = synchronized(this) {
                        if (closed) false else { active = current to opened; true }
                    }
                    if (!accepted) { runCatching { opened.close() }; checkOpen() }
                }
                checkOpen()
                return reader.read(offset, buffer, length)
            } catch (error: Exception) {
                release()
                checkOpen() // Cancelling an old seek must not reset a healthy pool.
                if (!SmbRecovery.retryable(error)) throw error
                connection.invalidate(current)
                if (attempt == 1) throw error
            }
        }
        error("Unreachable")
    }
    override fun close() { synchronized(this) { closed = true }; release() }
}
