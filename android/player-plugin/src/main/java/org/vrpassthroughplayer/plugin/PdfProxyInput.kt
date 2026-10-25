package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.system.ErrnoException
import android.system.OsConstants
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

/** API 26 seekable FD adapter. Callback thread must differ from the PdfRenderer thread. */
internal class PdfProxyInput(context: Context, private val cache: PdfReadCache,
    private val released: () -> Unit) : Closeable {
    private val thread = HandlerThread("PdfNetworkIO").apply { start() }
    private val finished = AtomicBoolean()
    @Volatile private var failure: Exception? = null
    val descriptor: ParcelFileDescriptor

    init {
        try {
            descriptor = context.getSystemService(StorageManager::class.java).openProxyFileDescriptor(
                ParcelFileDescriptor.MODE_READ_ONLY, object : ProxyFileDescriptorCallback() {
                    override fun onGetSize(): Long = io { cache.validate(); cache.size }
                    override fun onRead(offset: Long, size: Int, data: ByteArray): Int = io { cache.read(offset, data, size) }
                    override fun onRelease() = finish()
                }, Handler(thread.looper))
        } catch (error: Exception) { finish(); throw error }
    }

    private fun <T> io(action: () -> T): T = try { action() } catch (error: Exception) {
        failure = error
        throw ErrnoException("PDF read", OsConstants.EIO)
    }
    fun throwFailure() { failure?.let { throw it } }
    fun check() { throwFailure(); cache.validate() }
    private fun finish() {
        if (!finished.compareAndSet(false, true)) return
        try { cache.close() } finally { try { released() } finally { thread.quitSafely() } }
    }
    override fun close() = descriptor.close() // onRelease runs after in-flight callback reads.
}
