package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.system.Os
import java.io.IOException

/** Seekable SAF files, opened only with "r". Each HTTP reader owns an independent descriptor. */
internal class DocumentStreamSource(private val context: Context, private val uri: Uri) : StreamSource {
    private val readers = mutableSetOf<Reader>()
    private var closed = false
    override val size = descriptor().use { it.statSize.also { bytes -> if (bytes < 0) throw IOException("Storage file size unavailable") } }
    private fun descriptor() = context.contentResolver.openFileDescriptor(uri, "r") ?: throw IOException("Storage file unavailable")
    @Synchronized override fun open(): StreamSource.Reader {
        check(!closed) { "Storage access stopped" }
        return Reader(descriptor()).also { readers.add(it) }
    }
    private inner class Reader(private val descriptor: ParcelFileDescriptor) : StreamSource.Reader {
        private var released = false
        @Synchronized override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            check(!released) { "Storage access stopped" }
            require(offset >= 0 && length in 0..buffer.size)
            return Os.pread(descriptor.fileDescriptor, buffer, 0, length, offset)
        }
        override fun close() {
            synchronized(this) { if (released) return; released = true; descriptor.close() }
            synchronized(this@DocumentStreamSource) { readers.remove(this) }
        }
    }
    override fun close() {
        val pending = synchronized(this) { if (closed) return; closed = true; readers.toList() }
        pending.forEach { it.close() }
    }
}
