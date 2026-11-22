package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.config.PropertyConfiguration
import org.codelibs.jcifs.smb.context.BaseContext
import org.codelibs.jcifs.smb.impl.NtlmPasswordAuthenticator
import org.codelibs.jcifs.smb.impl.SmbFile
import org.codelibs.jcifs.smb.impl.SmbRandomAccessFile
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.URI

/** Optional local fixture server; no real account or media is accessed. */
class SmbLoopbackTest {
    @Test fun reloadsEachEpisodeSubtitleFromTheCorrectSmbFolder() {
        val host = System.getenv("VRPP_SMB_EPISODE_FIXTURE_HOST").orEmpty()
        assumeTrue(host.isNotEmpty())
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        val connection = SmbConnection(
            create = { base.withCredentials(NtlmPasswordAuthenticator("", "vrtest", "fixture-only")) },
            dispose = { it.close() })
        try {
            val names = listOf("2_Korean.srt", "3_English.srt", "4_Chinese.srt", "5_Japanese.srt")
            LocalStreamServer().use { streams ->
                for (episode in listOf(1, 2, 1)) {
                    val stem = "剧集 #1 S01Ep0$episode"
                    val tracks = smbSubtitleTracks("$stem.mp4", "smb://$host/fixture/", connection) { source, name ->
                        streams.publish(source, name)
                    }
                    assertEquals(listOf("$stem.srt") + names, tracks.map { it.title })
                    val expected = listOf("same-directory $episode") + names.map { "episode $episode $it" }
                    SubtitleTextSources(SubtitleCharsetDetector::detect).use { text ->
                        val prepared = tracks.map(text::prepare)
                        assertEquals(tracks.map { it.title }, prepared.map { it.title })
                        assertEquals(expected, prepared.map { URI(it.location).toURL().readText().trim().lineSequence().last() })
                    }
                    tracks.forEach { streams.revoke(it.location) }
                }
            }
        } finally {
            connection.close()
            base.close()
        }
    }

    @Test fun enumeratesSharesAndSeeksWithoutChangingStoredUriFormat() {
        val host = System.getenv("VRPP_SMB_FIXTURE_HOST") ?: ""
        assumeTrue(host.isNotEmpty())
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        val context = base.withCredentials(NtlmPasswordAuthenticator("", "vrtest", "fixture-only"))
        try {
            SmbFile("smb://$host/", context).use { root ->
                val files = root.listFiles()
                try { assertTrue(files.any { it.name.trimEnd('/') == "fixture" }) }
                finally { files.forEach { it.close() } }
            }
            SmbFile("smb://$host/fixture/", context).use { root ->
                assertTrue(root.list().contains("sample.mp4"))
                assertTrue(root.list().contains("sample.srt"))
            }
            SmbFile("smb://$host/fixture/sample.mp4", context).use { file ->
                assertEquals(262144L, file.length())
                SmbRandomAccessFile(file, "r").use { reader ->
                    for (offset in listOf(0L, 131071L, 7L, 260000L)) {
                        reader.seek(offset)
                        val actual = ByteArray(1024)
                        reader.readFully(actual)
                        assertArrayEquals(ByteArray(1024) { ((offset + it) * 31).toByte() }, actual)
                    }
                }
            }
        } finally { context.close() }
    }
}
