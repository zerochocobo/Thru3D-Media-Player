package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoDepthProfilesTest {
    @Test fun everyHeadsetUsesCompatibleZipDepth() {
        for (model in listOf("Quest 3", "Quest 3S", "Meta Quest 3", "PICO 4 Ultra", "  QUEST  3  ",
                "Quest 2", "PICO Neo3", "PICO 4", "PICO 4 Pro", "Unknown", "")) {
            assertEquals("384x224", VideoDepthProfiles.forModel(model).shape)
            assertEquals("depth-mnn/depth_compat.mnn", VideoDepthProfiles.forModel(model).asset)
        }
    }
}
