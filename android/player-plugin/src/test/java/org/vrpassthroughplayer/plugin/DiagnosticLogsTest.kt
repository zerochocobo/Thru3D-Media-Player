package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticLogsTest {
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

    @Test fun keepsDiagnosticText() {
        val line = "W QuestVideoLayer: picture slot 2 image wait timed out (1 times) FPS=72/72 MPV_RVM_FAILED"
        assertEquals(line, DiagnosticLogs.redact(line))
    }
}
