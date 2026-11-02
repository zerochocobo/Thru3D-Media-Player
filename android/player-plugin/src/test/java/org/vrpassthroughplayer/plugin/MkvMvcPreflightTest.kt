package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class MkvMvcPreflightTest {
    @Test fun sourceNamesOnlySelectInspection() {
        assertTrue(MkvMvcPreflight.candidate("cloud://mount/PIRANHA%203D.mkv"))
        assertTrue(MkvMvcPreflight.candidate("http://127.0.0.1/token/PIRANHA%203D.MKV?x=1"))
        assertTrue(MkvMvcPreflight.candidate("content://provider/123", "movie.mk3d"))
        assertFalse(MkvMvcPreflight.candidate("https://server/movie.mp4?name=3d.mkv"))
        assertFalse(MkvMvcPreflight.candidate("movie3D.iso", "movieSBS.mp4"))
    }
    @Test fun ordinaryMkvDoesNotSelectMvc() {
        assertNull(MkvMvcPreflight.parse("""{"mvc":false,"width":1920,"height":1080}"""))
        assertEquals(MkvMvcPreflight.Result(3840,1080),MkvMvcPreflight.parse("""{"mvc":true,"width":3840,"height":1080}"""))
    }
    @Test fun unsupportedOrMissingDimensionsAreRejected() {
        for ((w,h) in listOf(0 to 1080,3839 to 1080,7680 to 2160,3840 to 0)) {
            assertTrue(runCatching { MkvMvcPreflight.parse("""{"mvc":true,"width":$w,"height":$h}""") }.isFailure)
        }
        assertTrue(runCatching { MkvMvcPreflight.parse("""{"mvc":true}""") }.isFailure)
    }
}
