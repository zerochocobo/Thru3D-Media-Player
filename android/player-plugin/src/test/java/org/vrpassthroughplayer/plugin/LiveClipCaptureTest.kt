package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LiveClipCaptureTest {
    @Test fun onlyStoppedLiveJobsAcceptCancellationAndKeepZeroProgressDuringDrain() {
        val capture=LiveClipCapture({null},{0L},{},{null},{},{_,_->})
        capture.prepare(1,JSONObject().put("start_us",0).put("mode",JSONObject().put("geometry",0)))
        assertEquals(-1,capture.progress(1))
        assertFalse(capture.cancel(1))
        assertTrue(capture.stop(1,4_000_000))
        assertFalse(capture.stop(1,5_000_000))
        assertEquals(0,capture.progress(1))
        assertTrue(capture.cancel(1))
        assertFalse(capture.cancel(1))
        assertEquals(0,capture.progress(1))
        assertFalse(capture.cancel(999))
        assertEquals(-1,capture.progress(999))
    }
}
