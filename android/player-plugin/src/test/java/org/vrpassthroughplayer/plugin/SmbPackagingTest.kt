package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.config.PropertyConfiguration
import org.codelibs.jcifs.smb.context.BaseContext
import org.codelibs.jcifs.smb.impl.NtlmPasswordAuthenticator
import org.codelibs.jcifs.smb.impl.SmbFile
import org.junit.Assert.*
import org.junit.Test

class SmbPackagingTest {
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

    @Test fun deprecatedHttpTlsAdaptersAreUnavailable() {
        for (prefix in listOf("org.codelibs.jcifs.smb", "org.codelibs.jcifs.smb1")) {
            for (adapter in listOf("http.NtlmHttpURLConnection", "http.Handler", "https.Handler")) {
                assertThrows(ClassNotFoundException::class.java) { Class.forName("$prefix.$adapter") }
            }
        }
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
