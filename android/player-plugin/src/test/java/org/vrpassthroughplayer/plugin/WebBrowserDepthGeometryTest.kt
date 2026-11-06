package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserDepthGeometryTest {
    private val identity = floatArrayOf(1f,0f,0f,0f, 0f,1f,0f,0f, 0f,0f,1f,0f, 0f,0f,0f,1f)
    @Test fun focusedTopLeftCornersSurviveProducerTransform() {
        // SurfaceTexture's producer flip is composed with the top-left focus crop.
        val producer = identity.copyOf().apply { this[5] = -1f; this[13] = 1f }
        val out = FloatArray(16)
        WebBrowserDepthGeometry.transform(producer, floatArrayOf(.2f,.1f,.3f,.6f), out)
        fun point(x: Float, y: Float) = floatArrayOf(out[0]*x+out[4]*y+out[12], out[1]*x+out[5]*y+out[13])
        assertArrayEquals(floatArrayOf(.2f,.1f), point(0f,1f), .00001f)
        assertArrayEquals(floatArrayOf(.5f,.7f), point(1f,0f), .00001f)
    }
    @Test fun fullPageDoesNotAlterProducerTransform() {
        val producer = identity.copyOf().apply { this[0] = .9f; this[12] = .04f; this[13] = .08f }
        val out = FloatArray(16)
        WebBrowserDepthGeometry.transform(producer, floatArrayOf(0f,0f,1f,1f), out)
        assertArrayEquals(producer, out, .000001f)
    }
    @Test fun malformedRegionsNeverReachGpu() {
        for (c in listOf(floatArrayOf(0f,0f,1f), floatArrayOf(Float.NaN,0f,1f,1f),
            floatArrayOf(0f,0f,Float.POSITIVE_INFINITY,1f), floatArrayOf(-.1f,0f,.5f,.5f),
            floatArrayOf(.8f,0f,.3f,.5f), floatArrayOf(0f,0f,0f,.5f))) assertFalse(WebBrowserDepthGeometry.valid(c))
        assertTrue(WebBrowserDepthGeometry.valid(floatArrayOf(.8f,.8f,.2f,.2f)))
    }
}
