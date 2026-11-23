package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

class DiagnosticLogsTest {
    @Test fun compactExportRetainsReadRoutesAndSuppressedFramesWithoutMediaNames() {
        val uri = "content://com.android.externalstorage.documents/tree/1234-ABCD%3A/document/1234-ABCD%3APrivateClip.mp4"
        val lines = listOf(
            "11-02 14:16:33.700 24905 28807 I ThruStorage: document_open stage=resolver_failed error=FileNotFoundException cause=none",
            "11-02 14:16:33.701 24905 28807 I ThruStorage: document_open stage=direct_start",
            "11-02 14:16:33.702 24905 28807 I ThruStorage: document_open stage=direct_failed error=FileNotFoundException cause=none",
            "11-02 14:16:33.703 24905 28807 W QuestPlayer: at StorageDocumentReader.open(StorageDocumentReader.kt:70)",
            "11-02 14:16:33.704 24905 28807 W QuestPlayer: Suppressed: java.io.FileNotFoundException: Failed opening content provider: $uri",
            "11-02 14:16:33.705 24905 28807 W QuestPlayer: at StorageDocumentReadPolicy.open(StorageDocumentReader.kt:24)"
        )
        val exported = DiagnosticLogs.redact(DiagnosticLogs.condense(lines.joinToString("\n")))
        for (stage in listOf("resolver_failed", "direct_start", "direct_failed")) assertTrue(exported.contains("stage=$stage"))
        assertTrue(exported.contains("StorageDocumentReader.open"))
        assertTrue(exported.contains("StorageDocumentReadPolicy.open"))
        assertTrue(exported.contains("Suppressed: java.io.FileNotFoundException"))
        assertFalse(exported.contains("PrivateClip"))
    }
    @Test fun otherProcessesKeepGeckoCodecLinesAndDropThisProcess() {
        val log = listOf(
            "11-23 19:42:37.101  7443  9359 W godot   : main process warning",
            "11-23 19:42:37.102 27511 27530 I MediaCodec: [OMX.qcom.video.decoder.hevc] setting surface generation to 1",
            "11-23 19:42:37.103 27511 27530 I MediaCodec: [OMX.qcom.video.decoder.hevc] setting surface generation to 1",
            "--------- beginning of main",
            "11-23 19:42:37.104 27602 27610 E GeckoRemoteCodec: codec error"
        ).joinToString("\n")
        val kept = DiagnosticLogs.otherProcessLines(log, 7443)
        assertFalse(kept.contains("main process warning"))
        assertFalse(kept.contains("beginning of main"))
        assertTrue(kept.contains("OMX.qcom.video.decoder.hevc"))
        assertTrue(kept.contains("(repeated 1 times)"))
        assertTrue(kept.contains("GeckoRemoteCodec: codec error"))
        assertEquals("(none in buffer)\n", DiagnosticLogs.otherProcessLines("11-23 19:42:37.101  7443  9359 W godot   : x", 7443))
    }
    @Test fun masksMediaNamesAccountsAndParameters() {
        val line = """I QuestPlayer: open smb://alice:secret@192.168.1.5/Movies/My Holiday 2025.mkv """ +
            """http://127.0.0.1:18889/stream.mp4?token=abc&sign=1 {"title":"Private clip","access_token":"xyz"} me@example.com"""
        val masked = DiagnosticLogs.redact(line)
        for (secret in listOf("alice", "secret", "My Holiday", "abc", "Private clip", "xyz", "me@example.com"))
            assertFalse(secret, masked.contains(secret))
        assertTrue(masked, masked.contains("smb://***@192.168.1.5/Movies/***.mkv"))
        assertTrue(masked, masked.contains("http://127.0.0.1:18889/***.mp4?***"))
    }

    @Test fun compactLogThinsPeriodicLinesButKeepsTrouble() {
        fun vr(s: Int, fps: Int, stale: Int = 0, free: Int = 3378) =
            "10-27 18:38:%02d.643 19195 19485 I VrApi   : FPS=$fps/72,Prd=33ms,Stale=$stale,Mem=1555MHz,Free=${free}MB,App=$s.1ms".format(s)
        val log = (0 until 30).map { vr(it, 72) } + vr(31, 40) + vr(32, 72, stale = 9) + vr(33, 72, free = 800) +
            (0 until 5).map { "10-27 18:38:40.0%02d 19195 19300 W QuestPlayer: copy late".format(it) } +
            "10-27 18:38:41.000 19195 19300 E QuestVideoLayer: picture slot 2 image wait timed out (1 times)"
        val compact = DiagnosticLogs.condense(log.joinToString("\n")).lines()
        assertEquals(3, compact.count { it.contains("FPS=72/72,Prd=33ms,Stale=0") && it.contains("Free=3378MB") }) // 0, 10, 20 s
        assertTrue(compact.any { it.contains("FPS=40/72") } && compact.any { it.contains("Stale=9") } && compact.any { it.contains("Free=800MB") })
        assertEquals(1, compact.count { it.contains("copy late") })
        assertTrue(compact.contains("    (repeated 4 times)"))
        assertTrue(compact.any { it.contains("image wait timed out") })
    }

    @Test fun uploadsTheGzippedLogAndReturnsTheInboxCodeOrItsRefusal() {
        var received = ""
        var app = ""
        var category = ""
        var refuse = false
        // android.jar has no HTTP server: one request per connection is enough for the inbox's contract.
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            while (!server.isClosed) (runCatching { server.accept() }.getOrNull() ?: break).use { client ->
                val input = DataInputStream(client.getInputStream())
                val headers = generateSequence { input.readLine()?.takeIf { it.isNotEmpty() } }.toList()
                fun header(name: String) = headers.firstOrNull { it.startsWith("$name:", ignoreCase = true) }?.substringAfter(':')?.trim().orEmpty()
                val body = ByteArray(header("Content-Length").toInt()).also { input.readFully(it) }
                received = GZIPInputStream(body.inputStream()).bufferedReader().readText()
                app = header("X-Thru3D-App")
                category = header("X-Thru3D-Category")
                val reply = if (refuse) """{"error":"rate_limited"}""" else """{"code":"7F2K9QXM"}"""
                client.getOutputStream().write(("HTTP/1.1 ${if (refuse) "429 Too Many Requests" else "201 Created"}\r\n" +
                    "Content-Type: application/json\r\nContent-Length: ${reply.length}\r\nConnection: close\r\n\r\n$reply").toByteArray())
            }
        }
        try {
            val endpoint = "http://127.0.0.1:${server.localPort}/v1/logs"
            val text = "Thru3D diagnostic log 2026-11-16 10:00:00\nDevice: Oculus Quest 3\n"
            val header = """Report: {"category":"audio_subtitles","note":"字幕比声音慢 a@b.com"}""" + "\nPlayer: {}"
            assertEquals("audio_subtitles", DiagnosticLogs.reportCategory(header))
            assertEquals("", DiagnosticLogs.reportCategory("Report: {\"category\":\"../x\"}"))
            assertEquals("", DiagnosticLogs.reportCategory("Player: {}"))
            assertTrue(DiagnosticLogs.redact(header).contains("字幕比声音慢") && !DiagnosticLogs.redact(header).contains("a@b.com"))
            assertEquals("7F2K9QXM", DiagnosticLogs.upload(endpoint, text, "App: com.wapok.thru3d 0.17.9 (versionCode=93)", "audio_subtitles"))
            assertEquals("audio_subtitles", category)
            assertEquals(text, received)
            assertEquals("com.wapok.thru3d 0.17.9 (versionCode=93)", app)
            refuse = true
            assertEquals("rate_limited", runCatching { DiagnosticLogs.upload(endpoint, text, "") }.exceptionOrNull()?.message)
        } finally {
            server.close()
        }
    }

    @Test fun keepsDiagnosticText() {
        val line = "W QuestVideoLayer: picture slot 2 image wait timed out (1 times) FPS=72/72 MPV_RVM_FAILED"
        assertEquals(line, DiagnosticLogs.redact(line))
    }
}
