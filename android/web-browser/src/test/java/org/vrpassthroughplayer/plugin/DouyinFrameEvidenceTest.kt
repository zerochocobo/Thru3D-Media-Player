package org.vrpassthroughplayer.plugin

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DouyinFrameEvidenceTest {
    private val pixels = IntArray(17 * 17) { 0x123456 }
    private val grid = "123456".repeat(pixels.size)
    private fun row(at: Long = 42, pts: Long = 0, rendered: String = grid, bt709: Int = 0) =
        "I Thru3DGeckoFrame: paired side=17 surface=7 generation=1 timestamp_ns=0 pts_us=$pts boot_ns=$at surface_rgb=$grid webrender_rgb=$rendered bt709=$bt709"

    private val systemLogcat = DouyinFrameEvidence.logcat

    @After fun reset() {
        DouyinFrameEvidence.drain()
        DouyinFrameEvidence.logcat = systemLogcat
        DouyinFrameEvidence.clear()
    }

    @Test fun keepsTheNativeLineAndDecoderFormatReadAtCaptureTime() {
        val format = "11-24 14:40:50.051  9909  9909 I Thru3DCodecFormat: surface=7 codec=c2.qti.avc.decoder stage=output width=1280 height=720 boot_ms=1"
        DouyinFrameEvidence.logcat = { filter -> if (filter.contains("Thru3DGeckoFrame:I")) row() else format }
        DouyinFrameEvidence.record("video=2", 40, 44, pixels)
        DouyinFrameEvidence.drain()
        // The small main log has since dropped both lines: the export still pairs the sample.
        assertTrue(DouyinFrameEvidence.export("").contains("video=2 paired"))
        assertEquals(format, DouyinFrameEvidence.codecLines())
    }

    @Test fun waitsForPreviousCaptureToFinishAcrossDisplayBindings() {
        val first = requireNotNull(DouyinFrameEvidence.beginRequest())
        try {
            assertNull(DouyinFrameEvidence.beginRequest())
        } finally {
            DouyinFrameEvidence.finishRequest(first)
        }
        val second = requireNotNull(DouyinFrameEvidence.beginRequest())
        try {
            DouyinFrameEvidence.finishRequest(first)
            assertNull(DouyinFrameEvidence.beginRequest())
        } finally {
            DouyinFrameEvidence.finishRequest(second)
        }
    }

    @Test fun acceptsFirstFrameWithZeroPts() {
        DouyinFrameEvidence.record("video=2", 40, 44, pixels)
        assertTrue(DouyinFrameEvidence.export(row()).contains("video=2 paired"))
    }

    @Test fun keepsWhichConversionWebRenderUsed() {
        DouyinFrameEvidence.record("video=2", 40, 44, pixels)
        assertTrue(DouyinFrameEvidence.export(row(bt709 = 1)).endsWith(" bt709=1"))
    }

    @Test fun rejectsWrongFrameAmbiguousDrawAndWrongDisplay() {
        DouyinFrameEvidence.logcat = { "" }
        DouyinFrameEvidence.record("video=2", 40, 44, pixels)
        DouyinFrameEvidence.drain()
        for (log in listOf(row(at = 45), row(pts = 1), row() + "\n" + row(at = 43),
                row(rendered = "654321".repeat(pixels.size)), row().dropLast(1), row().substringBefore(" bt709="))) {
            val report = DouyinFrameEvidence.export(log)
            assertTrue(report.contains("unpaired="))
            assertFalse(report.contains("surface_rgb="))
        }
    }
}
