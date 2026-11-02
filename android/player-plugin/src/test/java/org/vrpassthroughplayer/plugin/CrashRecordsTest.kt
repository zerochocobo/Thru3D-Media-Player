package org.vrpassthroughplayer.plugin

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files

class CrashRecordsTest {
    private val directory: File = Files.createTempDirectory("crash-trail").toFile()

    @After fun cleanUp() { CrashTrail.detach(); directory.deleteRecursively() }

    @Test fun trailSurvivesIntoTheNextSessionAndWraps() {
        val file = File(directory, "trail.bin")
        assertNull(CrashTrail.open(file, pid = 100, nowMs = 1_000))
        repeat(CrashTrail.SLOTS + 5) { CrashTrail.mark("photo.decode", "idx=$it") }
        CrashTrail.mark("photo.texture", "x".repeat(400))
        CrashTrail.detach() // the process dies without a clean exit
        val previous = CrashTrail.open(file, pid = 200, nowMs = 2_000)!!
        assertEquals(100, previous.pid); assertEquals(1_000, previous.startedMs)
        assertFalse(previous.clean); assertTrue(previous.foreground)
        assertEquals(CrashTrail.SLOTS, previous.lines.size)
        assertTrue(previous.lines.first(), previous.lines.first().endsWith("photo.decode idx=6"))
        assertTrue(previous.lines.last().contains("photo.texture xxx"))
        // The new session starts empty.
        assertTrue(CrashTrail.current().isEmpty())
    }

    @Test fun cleanExitAndBackgroundAreRemembered() {
        val file = File(directory, "trail.bin")
        CrashTrail.open(file, pid = 1)
        CrashTrail.foreground(false); CrashTrail.cleanExit()
        CrashTrail.detach()
        val previous = CrashTrail.open(file, pid = 2)!!
        assertTrue(previous.clean); assertFalse(previous.foreground)
    }

    @Test fun crashDecision() {
        assertTrue(CrashRecords.decide(java = true, exitSaysCrash = false, foreground = false))
        assertTrue(CrashRecords.decide(java = false, exitSaysCrash = null, foreground = true)) // Android 10: unclean while in front
        assertFalse(CrashRecords.decide(java = false, exitSaysCrash = null, foreground = false)) // killed in the background
        assertFalse(CrashRecords.decide(java = false, exitSaysCrash = false, foreground = true)) // e.g. USER_REQUESTED
        val exit = { reason: Int -> CrashRecords.Exit(1, "p", reason, 0, 100, 0, 0, 0, "") { null } }
        assertTrue(exit(5).crash(foreground = false)) // CRASH_NATIVE
        assertTrue(exit(3).crash(foreground = true)) // LOW_MEMORY in front
        assertFalse(exit(3).crash(foreground = false))
        assertFalse(exit(10).crash(foreground = true)) // USER_REQUESTED
        assertEquals("CRASH_NATIVE", exit(5).name)
    }

    private class Proto {
        val out = ByteArrayOutputStream()
        private fun varint(value: Long) { var v = value; while (v and 0x7fL.inv() != 0L) { out.write(((v and 0x7f) or 0x80).toInt()); v = v ushr 7 }; out.write(v.toInt()) }
        fun int(field: Int, value: Long) = apply { varint((field shl 3).toLong()); varint(value) }
        fun bytes(field: Int, value: ByteArray) = apply { varint(((field shl 3) or 2).toLong()); varint(value.size.toLong()); out.write(value) }
        fun text(field: Int, value: String) = bytes(field, value.toByteArray())
        fun message(field: Int, value: Proto) = bytes(field, value.out.toByteArray())
    }

    @Test fun tombstoneBecomesReadableText() {
        fun frame(pc: Long, file: String, function: String) = Proto().int(1, pc).text(6, file).text(4, function).int(5, 12)
        val crashing = Proto().int(1, 4321).text(2, "PhotoWorker")
            .message(4, frame(0x1234, "/data/app/lib/arm64/libdepth.so", "processPhoto"))
            .message(4, frame(0x5678, "/system/lib64/libc.so", "start_thread"))
        val other = Proto().int(1, 4300).text(2, "GodotMain").message(4, frame(0x9, "libgodot_android.so", "main"))
        val log = Proto().text(1, "11-02 10:00:00.000").int(2, 4300).int(3, 4321).int(4, 6).text(5, "QuestPhoto").text(6, "decode 8000x4000")
        val tombstone = Proto().int(5, 4300).int(6, 4321)
            .message(10, Proto().int(1, 11).text(2, "SIGSEGV").int(3, 1).text(4, "SEGV_MAPERR").int(8, 1).int(9, 0x10))
            .text(14, "boom")
            .message(15, Proto().text(1, "null pointer dereference"))
            .message(16, Proto().int(1, 4300).message(2, other))
            .message(16, Proto().int(1, 4321).message(2, crashing))
            .message(18, Proto().text(1, "main").message(2, log))
        val text = NativeTombstone.describe(tombstone.out.toByteArray())
        assertTrue(text, text.contains("signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x10"))
        assertTrue(text, text.contains("Abort message: boom") && text.contains("Cause: null pointer dereference"))
        assertTrue(text, text.contains("Crashing thread 4321 \"PhotoWorker\"") && text.contains("libdepth.so (processPhoto+12)"))
        assertTrue(text, text.indexOf("processPhoto") < text.indexOf("Other threads"))
        assertTrue(text, text.contains("4300 \"GodotMain\""))
        assertTrue(text, text.contains("E QuestPhoto: decode 8000x4000"))
    }

    @Test(expected = Exception::class) fun notATombstone() { NativeTombstone.describe("plain ANR text".toByteArray()) }
}
