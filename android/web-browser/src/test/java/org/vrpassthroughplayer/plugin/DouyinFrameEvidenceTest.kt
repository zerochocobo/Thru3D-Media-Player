package org.vrpassthroughplayer.plugin

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DouyinFrameEvidenceTest {
    private val pixels = IntArray(17 * 17) { 0x123456 }
    private val grid = "123456".repeat(pixels.size)
    private fun row(at: Long = 42, pts: Long = 0, rendered: String = grid, bt709: Int = 0) =
        "I Thru3DGeckoFrame: paired side=17 surface=7 generation=1 timestamp_ns=0 pts_us=$pts boot_ns=$at surface_rgb=$grid webrender_rgb=$rendered bt709=$bt709"

    @After fun reset() = DouyinFrameEvidence.clear()

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
        DouyinFrameEvidence.record("video=2", 40, 44, pixels)
        for (log in listOf(row(at = 45), row(pts = 1), row() + "\n" + row(at = 43),
                row(rendered = "654321".repeat(pixels.size)), row().dropLast(1), row().substringBefore(" bt709="))) {
            val report = DouyinFrameEvidence.export(log)
            assertTrue(report.contains("unpaired="))
            assertFalse(report.contains("surface_rgb="))
        }
    }
}
