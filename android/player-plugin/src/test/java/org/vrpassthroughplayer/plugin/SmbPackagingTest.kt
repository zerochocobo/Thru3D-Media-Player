package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.config.PropertyConfiguration
import org.codelibs.jcifs.smb.context.BaseContext
import org.codelibs.jcifs.smb.impl.NtlmPasswordAuthenticator
import org.codelibs.jcifs.smb.impl.SmbFile
import org.codelibs.jcifs.smb.internal.fscc.FileRenameInformation2
import org.codelibs.jcifs.smb.internal.smb2.create.Smb2CreateRequest
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class SmbPackagingTest {
    @Test fun photoNamesKeepTheFullExtensionAndPathWithAHash() {
        val name = "照片 [Album] EXC#95_P01_0.01_1.0_LRF_Full_SBS.jpg"
        assertTrue(MediaKinds.supportedFileName(name))
        assertEquals("image", MediaKinds.fileNameKind(name))
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        try {
            SmbFile("smb://127.0.0.1/fixture/$name", base).use { file ->
                assertEquals(name, file.name)
                assertEquals("\\$name", file.locator.uncPath)
            }
        } finally { base.close() }
    }

    @Test fun subtitleNamesKeepUnicodeSpacesAndHashesThroughTheActualSmbHandler() {
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        try {
            val selected = java.net.URI("smb", "saved", "/fixture/字幕 #1.srt", null)
            assertEquals("字幕 #1.srt", SidecarSubtitles.sourceName(selected.toASCIIString()))
            // MediaSources resolves the saved account first, then hands its decoded path to JCIFS.
            SmbFile("smb://127.0.0.1${selected.path}", base).use { file ->
                assertEquals("字幕 #1.srt", file.name)
            }
        } finally { base.close() }
    }

    @Test fun questionMarkInLiteralSmbPathsNeverBecomesAQuery() {
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        try {
            val folder = "Season?server=other#1+%25"
            for (extension in listOf("mp4", "iso", "jpg", "m4a", "srt", "pdf", "cbz", "strm")) {
                val name = "e\u0301 & [片]?#.$extension"
                SmbClientPolicy.file("smb://127.0.0.1:1445/fixture/$folder/$name", base).use { file ->
                    assertEquals(name, file.name)
                    assertEquals("\\$folder\\$name", file.locator.uncPath)
                    assertEquals("127.0.0.1", file.url.host)
                    assertEquals(1445, file.url.port)
                    assertNull(file.url.query)
                    assertNull(file.url.ref)
                }
            }
        } finally { base.close() }
    }

    @Test fun deprecatedHttpTlsAdaptersAreUnavailable() {
        for (prefix in listOf("org.codelibs.jcifs.smb", "org.codelibs.jcifs.smb1")) {
            for (adapter in listOf("http.NtlmHttpURLConnection", "http.Handler", "https.Handler")) {
                assertThrows(ClassNotFoundException::class.java) { Class.forName("$prefix.$adapter") }
            }
        }
    }

    @Test fun smbMutationPathsKeepLiteralPercentSequencesInTheWireNames() {
        val config = PropertyConfiguration(SmbClientPolicy.properties(false))
        val base = BaseContext(config)
        try {
            val targets = linkedMapOf(
                "fixture/目录#/A%2FB#1.mp4" to "目录#\\A%2FB#1.mp4",
                "fixture/目录#/A%252FB#1.mp4" to "目录#\\A%252FB#1.mp4",
                "fixture/目录#/A/B#1.mp4" to "目录#\\A\\B#1.mp4"
            )
            for ((path, expected) in targets) {
                val literal = MediaDeletePolicy.smbPath(path)
                SmbClientPolicy.file("smb://127.0.0.1/$literal", base).use { file ->
                    assertEquals("/$literal", file.url.path)
                    assertNull(file.url.query)
                    assertNull(file.url.ref)
                    val relative = file.locator.uncPath.removePrefix("\\")
                    assertEquals(expected, relative)
                    val create = Smb2CreateRequest(config, relative)
                    val createPacket = ByteArray(create.size())
                    create.encode(createPacket, 0)
                    val createFields = ByteBuffer.wrap(createPacket).order(ByteOrder.LITTLE_ENDIAN)
                    val nameOffset = createFields.getShort(64 + 44).toInt() and 0xffff
                    val nameLength = createFields.getShort(64 + 46).toInt() and 0xffff
                    assertEquals(expected, String(createPacket, nameOffset, nameLength, Charsets.UTF_16LE))

                    val rename = FileRenameInformation2(relative, false)
                    val renamePacket = ByteArray(rename.size())
                    rename.encode(renamePacket, 0)
                    val renameLength = ByteBuffer.wrap(renamePacket).order(ByteOrder.LITTLE_ENDIAN).getInt(16)
                    assertEquals(0.toByte(), renamePacket[0]) // ReplaceIfExists
                    assertEquals(expected, String(renamePacket, 20, renameLength, Charsets.UTF_16LE))
                }
            }
        } finally { base.close() }
    }

    @Test fun smbContextAndUrlHandlerStillWorkWithTheFilteredJar() {
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        val context = base.withCredentials(NtlmPasswordAuthenticator("", "fixture", "fixture-only"))
        try {
            SmbFile("smb://127.0.0.1/fixture/sample.mp4", context).use { file ->
                assertEquals("sample.mp4", file.name)
                assertEquals("fixture", file.share)
                assertEquals("smb://127.0.0.1/fixture/sample.mp4", file.url.toString())
            }
        } finally {
            context.close()
            base.close()
        }
    }
}
