package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class ReadingRenderPolicyTest {
    @Test fun originalEightKEdgeIsRejectedEvenForThinImages() {
        assertFalse(ReadingRenderPolicy.accepts(7680, 8))
        assertFalse(ReadingRenderPolicy.accepts(8, 8192))
        assertFalse(ReadingRenderPolicy.accepts(Int.MAX_VALUE, Int.MAX_VALUE))
    }
    @Test fun OrdinaryPdfPagesAndJoinedSpreadsFitWithoutDownscaling() {
        assertTrue(ReadingRenderPolicy.accepts(2048, 3072))
        assertTrue(ReadingRenderPolicy.accepts(4096, 3072))
        assertFalse(ReadingRenderPolicy.accepts(6000, 4000))
        assertFalse(ReadingRenderPolicy.accepts(0, 3072))
    }
}
