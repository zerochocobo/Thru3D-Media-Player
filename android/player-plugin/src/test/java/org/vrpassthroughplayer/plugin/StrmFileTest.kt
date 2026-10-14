package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException

class StrmFileTest {
    private fun failure(code: String, action: () -> Any?) {
        assertEquals(code, assertThrows(StrmFailure::class.java) { action() }.code)
    }
    private fun target(origin: String, text: String) = StrmFile.target(origin, StrmFile.parse(text.toByteArray()))

    @Test fun textEncodingsBlankLinesAndComments() {
        val url = "https://nas/video.mkv?sign=a%2Bb%3D&x=%2520#part"
        assertEquals(url, StrmFile.parse("\uFEFF\r\n# comment\r\n $url \r\n".toByteArray()))
        assertEquals(url, StrmFile.parse(byteArrayOf(0xff.toByte(), 0xfe.toByte()) + url.toByteArray(Charsets.UTF_16LE)))
        assertEquals(url, StrmFile.parse(byteArrayOf(0xfe.toByte(), 0xff.toByte()) + url.toByteArray(Charsets.UTF_16BE)))
        assertEquals(url, target("file:///storage/movie.strm", url))
    }
    @Test fun rejectsEmptyBinaryOversizedAndMultipleTargets() {
        failure("STRM_EMPTY") { StrmFile.parse("\n#empty\r\n".toByteArray()) }
        failure("STRM_MULTIPLE_TARGETS") { StrmFile.parse("https://nas/a\nhttps://nas/b".toByteArray()) }
        failure("STRM_INVALID_TEXT") { StrmFile.parse(byteArrayOf(0, 1, 2)) }
        failure("STRM_INVALID_TEXT") { StrmFile.parse(byteArrayOf(0xc3.toByte(), 0x28)) }
        failure("STRM_TOO_LARGE") { StrmFile.parse(ByteArray(StrmFile.MAX_BYTES + 1)) }
        failure("STRM_TOO_LARGE") { StrmFile.read(ByteArrayInputStream(ByteArray(StrmFile.MAX_BYTES + 1))) }
        assertEquals(StrmFile.MAX_BYTES, StrmFile.read(ByteArrayInputStream(ByteArray(StrmFile.MAX_BYTES))).size)
    }
    @Test fun localPathsPreserveLiteralCharactersAndResolveParents() {
        assertEquals("/storage/Movies/中文 #1.mkv", java.net.URI(target("file:///storage/Index/a.strm", "../Movies/中文 #1.mkv")).path)
        assertEquals("file:///storage/a.mkv", target("file:///storage/Movies/a.strm", "../a.mkv"))
        assertEquals("file:///storage/a.mkv", target("file:///storage/Movies/a.strm", "/storage/a.mkv"))
        assertEquals("file:///storage/Movies/a.mkv", target("file:///storage/Movies/a.strm", ".\\a.mkv"))
    }
    @Test fun httpRelativeAndExtensionlessSignedAddresses() {
        assertEquals("https://nas/media/movie%20one.mkv", target("https://nas/media/a.strm?key=old", "movie one.mkv"))
        assertEquals("https://nas/download?id=7&sign=a%2Fb%3D", target("file:///a.strm", "https://nas/download?id=7&sign=a%2Fb%3D"))
        assertEquals("https://nas/video.mkv", target("https://nas/index/a.strm", "/video.mkv"))
    }
    @Test fun remoteRelativePathsRemainWithinTheShareOrMount() {
        assertEquals("smb://nas/share/video.mkv", target("smb://nas/share/index/a.strm", "../video.mkv"))
        assertEquals("smb://nas/share/video.mkv", target("smb://nas/share/index/a.strm", "/video.mkv"))
        assertEquals("cloud://mount-id/video.mkv", target("cloud://mount-id/index/a.strm", "../video.mkv"))
        assertEquals("cloud://mount-id/video.mkv", target("cloud://mount-id/index/a.strm", "/video.mkv"))
        val encoded = target("smb://nas/share/Movie%20Collection/a.strm", "video #1.mkv")
        assertEquals("smb://id-1/share/Movie Collection/video #1.mkv", StrmFile.smbTarget(encoded, listOf("id-1" to "nas"), "id-1"))
        failure("STRM_INVALID_ADDRESS") { target("smb://nas/share/a.strm", "../outside.mkv") }
        failure("STRM_INVALID_ADDRESS") { target("cloud://mount-id/a.strm", "../outside.mkv") }
        failure("STRM_RELATIVE_PATH_UNAVAILABLE") { target("content://documents/opaque-id", "a.mkv") }
    }
    @Test fun rejectsForeignProtocolsHeaderSyntaxAndWindowsDrivePaths() {
        for (path in listOf("C:\\Movies\\a.mkv", "D:/Movies/a.mkv", "file:///D:/Movies/a.mkv"))
            failure("STRM_WINDOWS_PATH") { target("file:///a.strm", path) }
        for (path in listOf("plugin://addon/video", "javascript:alert(1)", "ftp://nas/video.mkv", "https://nas/a|User-Agent=test"))
            failure("STRM_UNSUPPORTED_ADDRESS") { target("file:///a.strm", path) }
        for (path in listOf("https:///video.mkv", "file://nas/share/a", "smb://user:pass@nas/share/a", "smb://nas/share/../a"))
            failure("STRM_INVALID_ADDRESS") { target("file:///a.strm", path) }
    }
    @Test fun uncAndSmbAddressesReuseSavedCredentials() {
        val uri = target("file:///a.strm", "\\\\NAS\\Movies\\中文 3D.mkv")
        assertEquals("smb://id-1/Movies/中文 3D.mkv", StrmFile.smbTarget(uri, listOf("id-1" to "nas"), ""))
        assertEquals("smb://id-1/中文 3D.mkv", StrmFile.smbTarget(uri, listOf("id-1" to "nas/Movies"), ""))
        failure("STRM_SMB_CONNECTION_REQUIRED") { StrmFile.smbTarget(uri, emptyList(), "") }
        failure("STRM_SMB_CONNECTION_REQUIRED") { StrmFile.smbTarget(uri, listOf("a" to "nas", "b" to "nas"), "") }
        assertEquals("smb://b/Movies/中文 3D.mkv", StrmFile.smbTarget(uri, listOf("a" to "nas", "b" to "nas"), "b"))
    }
    @Test fun resolvesOnlyOnPlaybackAndPreservesTheOriginalIdentity() {
        val original = "file:///index/Movie.SBS.STRM"
        val calls = ArrayList<String>()
        val resolver = StrmResolver({ uri -> calls.add(uri); StrmDocument("https://nas/download?key=private".toByteArray(), uri) })
        assertEquals("file:///ordinary.mkv", resolver.resolve("file:///ordinary.mkv"))
        assertTrue(calls.isEmpty())
        assertEquals("https://nas/download?key=private", resolver.resolve(original))
        assertEquals(listOf(original), calls)
    }
    @Test fun nestedFilesCyclesDepthAndReadFailures() {
        val files = mapOf("file:///a.strm" to "b.strm", "file:///b.strm" to "video.mkv")
        val resolver = StrmResolver({ StrmDocument(files.getValue(it).toByteArray(), it) })
        assertEquals("file:///video.mkv", resolver.resolve("file:///a.strm"))
        failure("STRM_RECURSIVE") { StrmResolver({ StrmDocument("a.strm".toByteArray(), it) }).resolve("file:///a.strm") }
        var calls = 0
        failure("STRM_RECURSIVE") { StrmResolver({ StrmDocument("${++calls}.strm".toByteArray(), it) }).resolve("file:///start.strm") }
        assertEquals(StrmFile.MAX_DEPTH, calls)
        failure("STRM_READ_FAILED") { StrmResolver({ throw IOException("secret token must not appear") }).resolve("file:///a.strm") }
        failure("STRM_READ_TIMEOUT") { StrmResolver({ throw java.net.SocketTimeoutException() }).resolve("file:///a.strm") }
    }
    @Test fun randomAccessReadsAreBoundedAndCloseBothHandles() {
        var sourceClosed = false; var readerClosed = false
        val data = "https://nas/video.mkv".toByteArray()
        val source = object : StreamSource {
            override val size = data.size.toLong()
            override fun open() = object : StreamSource.Reader {
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    val count = minOf(length, 3, data.size - offset.toInt())
                    data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count); return count
                }
                override fun close() { readerClosed = true }
            }
            override fun close() { sourceClosed = true }
        }
        assertArrayEquals(data, StrmFile.read(source))
        assertTrue(sourceClosed && readerClosed)
    }
    @Test fun libraryScanningAndFileActionsRecognizeTheShortcut() {
        assertTrue(MediaKinds.supported("Movie.SBS.STRM"))
        assertTrue(MediaKinds.supportedFileName("Movie#1?.strm"))
        assertEquals("video", MediaKinds.kind("Movie.strm"))
        assertEquals("share/Movie.strm", MediaDeletePolicy.smbPath("share/Movie.strm"))
        assertTrue(StrmFile.location("https://nas/movie.STRM?token=secret"))
        assertFalse(StrmFile.location("https://nas/movie.mkv?name=a.strm"))
    }
}
