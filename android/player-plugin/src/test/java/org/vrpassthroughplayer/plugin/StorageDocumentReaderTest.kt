package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.FileNotFoundException
import java.io.IOException

class StorageDocumentReaderTest {
    private val uri = StorageDocumentPolicy.document(StorageDocumentPolicy.id("1234-ABCD:Movies"),
        StorageDocumentPolicy.id("1234-ABCD:Movies/片+名%20 🎬.mp4"))
    private fun remote() = FileNotFoundException("Failed opening content provider: $uri")
    @Test fun normalOpenNeverCallsAlternateProvider() {
        val value = Any()
        assertSame(value, StorageDocumentReadPolicy.open(uri, { value }, { error("Unexpected alternate RPC") }))
    }
    @Test fun wrappedProviderFailureTriesTheSameDocumentOnce() {
        var normal = 0; var direct = 0
        val value = Any()
        val result = StorageDocumentReadPolicy.open(uri, { normal++; throw remote() }, { direct++; value })
        assertSame(value, result); assertEquals(1, normal); assertEquals(1, direct)
        assertEquals("1234-ABCD:Movies/片+名%20 🎬.mp4", StorageDocumentPolicy.parse(uri).document.text)
    }
    @Test fun realMissingPermissionAndOtherErrorsDoNotRetry() {
        for (failure in listOf(FileNotFoundException("No such file"), SecurityException("permission denied"), IOException("I/O"))) {
            val actual = assertThrows(failure.javaClass) {
                StorageDocumentReadPolicy.open(uri, { throw failure }, { error("Must not retry") })
            }
            assertSame(failure, actual)
        }
    }
    @Test fun otherProvidersPathsAndInvalidGrantsDoNotGetAnAlternateRpc() {
        for (other in listOf("content://other.provider/document/video", "file:///storage/movie.mp4",
            "content://com.android.externalstorage.documents/tree/1234-ABCD%3A/document/1234-ABCD%3A..%2Fmovie.mp4",
            StorageDocumentPolicy.tree(StorageDocumentPolicy.id("1234-ABCD:")))) {
            val failure = remote()
            assertSame(failure, assertThrows(FileNotFoundException::class.java) {
                StorageDocumentReadPolicy.open(other, { throw failure }, { error("Must not retry") })
            })
        }
    }
    @Test fun alternateFailureIsFinalAndKeepsTheOriginalCauseForDiagnostics() {
        val initial = remote(); val denied = SecurityException("revoked")
        assertSame(denied, assertThrows(SecurityException::class.java) {
            StorageDocumentReadPolicy.open(uri, { throw initial }, { throw denied })
        })
        assertEquals(listOf(initial), denied.suppressed.toList())
    }
    @Test fun providerLeaseOutlivesItsDescriptorAndClosesExactlyOnce() {
        val closed = mutableListOf<String>()
        val descriptor = Closeable { closed.add("fd") }
        val read = StorageDocumentRead(descriptor, Closeable { closed.add("provider") })
        assertTrue(closed.isEmpty()); assertSame(descriptor, read.descriptor)
        read.close(); read.close()
        assertEquals(listOf("fd", "provider"), closed)
    }
    @Test fun descriptorCloseFailureStillReleasesProviderExactlyOnce() {
        var released = 0
        val read = StorageDocumentRead(Closeable { throw IOException("closed") }, Closeable { released++ })
        assertThrows(IOException::class.java) { read.close() }; read.close()
        assertEquals(1, released)
    }
}
