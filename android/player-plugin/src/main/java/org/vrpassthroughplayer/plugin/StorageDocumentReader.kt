package org.vrpassthroughplayer.plugin

import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import java.io.Closeable
import java.io.FileNotFoundException
import java.io.IOException

internal class StorageProviderUnavailable(cause: Throwable? = null) :
    IOException("System storage provider could not open the file", cause)

/** Android 10 wraps a provider RPC failure in FileNotFoundException; it is not ENOENT. */
internal object StorageDocumentReadPolicy {
    fun providerFailure(error: Throwable): Boolean = error is StorageProviderUnavailable ||
        error is FileNotFoundException && error.message.orEmpty().startsWith("Failed opening content provider:")

    fun <T> open(uri: String, normal: () -> T, direct: () -> T): T {
        try { return normal() }
        catch (initial: FileNotFoundException) {
            if (!providerFailure(initial) || !runCatching {
                    StorageDocumentPolicy.parse(uri).document.path.isNotEmpty()
                }.getOrDefault(false)) throw initial
            // One alternate read-only RPC, same URI/grant. Never guess a filesystem path.
            try { return direct() }
            catch (error: Exception) {
                if (error !== initial) error.addSuppressed(initial)
                throw error
            }
        }
    }
}

/** The direct provider client stays alive until its file descriptor is no longer read. */
internal class StorageDocumentRead<T : Closeable>(val descriptor: T, private val provider: AutoCloseable? = null) : Closeable {
    private var closed = false
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        try { descriptor.close() } finally { provider?.close() }
    }
}

internal object StorageDocumentReader {
    const val IMPLEMENTATION = "provider_openfile_trace_v1"

    /** Fixed route and exception class only; never a URI, label, media name or exception message. */
    private fun trace(stage: String, error: Exception? = null) {
        if (PlaybackPrivacy.diagnostics) android.util.Log.i("ThruStorage", "document_open stage=$stage" +
            (error?.let { " error=${it.javaClass.simpleName} cause=${it.cause?.javaClass?.simpleName ?: "none"}" } ?: ""))
    }
    private fun <T> observed(route: String, action: () -> T): T {
        if (route == "direct") trace("direct_start")
        try {
            return action().also { if (route == "direct") trace("direct_succeeded") }
        } catch (error: Exception) {
            trace("${route}_failed", error)
            throw error
        }
    }
    fun open(resolver: ContentResolver, uri: Uri, cancellation: CancellationSignal? = null): StorageDocumentRead<ParcelFileDescriptor> =
        StorageDocumentReadPolicy.open(uri.toString(), normal = { observed("resolver") {
            StorageDocumentRead(resolver.openFileDescriptor(uri, "r", cancellation) ?: throw FileNotFoundException())
        } }, direct = { observed("direct") {
            cancellation?.throwIfCanceled()
            val client = resolver.acquireContentProviderClient(uri) ?: throw StorageProviderUnavailable()
            try {
                val fd = client.openFile(uri, "r", cancellation) ?: throw StorageProviderUnavailable()
                StorageDocumentRead(fd, client)
            } catch (error: Exception) {
                client.close()
                if (error is RemoteException) throw StorageProviderUnavailable(error)
                throw error
            }
        } })
}
