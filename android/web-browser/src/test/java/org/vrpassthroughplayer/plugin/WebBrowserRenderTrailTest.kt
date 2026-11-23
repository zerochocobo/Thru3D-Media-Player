package org.vrpassthroughplayer.plugin

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class WebBrowserRenderTrailTest {
    private var now = 1_000_000L
    private val logged = mutableListOf<String>()

    @Before fun setUp() {
        WebBrowserTrail.clear(); WebBrowserTrail.hosts = true
        WebBrowserTrail.clock = { now }; WebBrowserTrail.sink = { logged.add(it) }
    }
    @After fun tearDown() {
        WebBrowserTrail.clear(); WebBrowserTrail.hosts = true
        WebBrowserTrail.clock = System::currentTimeMillis
        WebBrowserTrail.sink = { line -> runCatching { android.util.Log.i(WebBrowserTrail.TAG, line) } }
    }

    @Test fun changeRecordsOnlyNewStates() {
        assertTrue(WebBrowserTrail.change("media:1", "web.media", "videos=1 playing=0"))
        assertFalse(WebBrowserTrail.change("media:1", "web.media", "videos=1 playing=0"))
        assertTrue(WebBrowserTrail.change("media:2", "web.media", "videos=1 playing=0"))
        assertTrue(WebBrowserTrail.change("media:1", "web.media", "videos=1 playing=1"))
        assertEquals(listOf("web.media videos=1 playing=0", "web.media videos=1 playing=0", "web.media videos=1 playing=1"), logged)
    }

    @Test fun burstsAreCappedButVerdictsAndCrashesAreKept() {
        repeat(60) { WebBrowserTrail.mark("web.surface", "attach gen=$it") }
        WebBrowserTrail.mark("web.white_suspect", "reason=no_frame_since_surface", force = true)
        assertEquals(41, logged.size)
        assertEquals("web.white_suspect reason=no_frame_since_surface dropped=20", logged.last())
        now += 10_000
        WebBrowserTrail.mark("web.surface", "attach gen=next")
        assertEquals("web.surface attach gen=next", logged.last())
    }

    @Test fun ringKeepsTheNewestStepsAndLiveStateLast() {
        repeat(300) { now += 1_000; WebBrowserTrail.mark("web.load", "stop nav=$it") }
        WebBrowserTrail.publish(listOf("w=1 tab=1 draws=0"))
        val recent = WebBrowserTrail.recent()
        assertEquals(241, recent.size)
        assertTrue(recent.first().endsWith("web.load stop nav=60"))
        assertEquals("now w=1 tab=1 draws=0", recent.last())
        WebBrowserTrail.clear()
        assertTrue(WebBrowserTrail.recent().isEmpty())
    }

    @Test fun hostsOnlyAndMaskedWhenDiagnosticsArePrivate() {
        assertEquals("https://www.bilibili.com", WebBrowserTrail.host("https://user:pw@www.bilibili.com/video/BV1xx?spm=1#t"))
        assertEquals("blank", WebBrowserTrail.host("about:blank"))
        assertEquals("blank", WebBrowserTrail.host(""))
        WebBrowserTrail.hosts = false
        assertEquals("***", WebBrowserTrail.host("https://www.bilibili.com/video/BV1xx"))
        assertEquals("network", WebBrowserTrail.errorCategory(3))
        assertEquals("security", WebBrowserTrail.errorCategory(2))
        assertEquals("c99", WebBrowserTrail.errorCategory(99))
    }

    @Test fun surfaceWithoutAnyCompositeIsWhiteUntilAFrameArrives() {
        val watch = WebBrowserRenderWatch()
        assertTrue(watch.verdict(0).fresh.isEmpty()) // nothing bound
        watch.bind(1_000)
        assertTrue(watch.verdict(5_999).fresh.isEmpty())
        assertEquals(listOf(WebBrowserRenderWatch.NO_FRAME), watch.verdict(6_000).fresh)
        assertTrue(watch.verdict(9_000).fresh.isEmpty()) // reported once
        watch.draw(9_500)
        val recovered = watch.verdict(9_600)
        assertEquals(listOf(WebBrowserRenderWatch.NO_FRAME), recovered.recovered)
        watch.bind(20_000) // a new Surface starts a new episode
        assertEquals(0L, watch.lastDraw)
        assertEquals(listOf(WebBrowserRenderWatch.NO_FRAME), watch.verdict(25_000).fresh)
    }

    @Test fun firstCompositeWithoutDrawCallbacksDoesNotReportAStall() {
        val watch = WebBrowserRenderWatch()
        watch.bind(1_000)
        watch.firstComposite()
        watch.contentfulPaint()
        watch.media(10_000, isPlaying = true, WebBrowserVideoFrames.Interval(8_000, 240, 240, 0))
        assertTrue(watch.verdict(11_000).fresh.isEmpty())
        val perf = watch.perf(11_000)!!
        assertEquals(null, perf.composites)
        assertEquals(30.0, perf.presentedRate!!, 0.0)
        assertTrue(perf.toString().startsWith("fps=unknown max_gap_ms=unknown hitches=unknown"))
        watch.bind(12_000)
        assertEquals(listOf(WebBrowserRenderWatch.NO_FRAME), watch.verdict(17_000).fresh)
    }

    @Test fun loadedDocumentWithoutContentfulPaint() {
        val watch = WebBrowserRenderWatch()
        watch.bind(0); watch.draw(100); watch.pageStart(); watch.pageStop(2_000, ok = true); watch.firstComposite()
        assertTrue(watch.verdict(9_999).fresh.isEmpty())
        assertEquals(listOf(WebBrowserRenderWatch.NO_PAINT), watch.verdict(10_000).fresh)
        watch.contentfulPaint()
        assertEquals(listOf(WebBrowserRenderWatch.NO_PAINT), watch.verdict(10_500).recovered)
        // A reset (Surface recreated) recomposites; the document's contentful paint stands.
        watch.paintReset()
        assertFalse(watch.composite)
        assertTrue(watch.verdict(30_000).fresh.isEmpty())
    }

    @Test fun backgroundLoadCountsFromWhenThePageIsShown() {
        val watch = WebBrowserRenderWatch()
        watch.pageStart(); watch.pageStop(1_000, ok = true)
        watch.bind(50_000); watch.draw(50_010)
        assertTrue(watch.verdict(57_000).fresh.isEmpty())
        assertEquals(listOf(WebBrowserRenderWatch.NO_PAINT), watch.verdict(58_000).fresh)
    }

    @Test fun idleStaticPageIsNotWhite() {
        val watch = WebBrowserRenderWatch()
        watch.bind(0); watch.draw(200); watch.pageStart(); watch.pageStop(1_000, ok = true); watch.contentfulPaint()
        watch.media(1_000, isPlaying = false, WebBrowserVideoFrames.Interval())
        assertTrue(watch.verdict(600_000).fresh.isEmpty())
    }

    @Test fun failedLoadLeavesABlankDocumentUntilTheNextPage() {
        val watch = WebBrowserRenderWatch()
        watch.bind(0); watch.draw(10); watch.pageStart(); watch.loadFailed(500)
        assertEquals(listOf(WebBrowserRenderWatch.LOAD_ERROR), watch.verdict(600).fresh)
        assertTrue(watch.verdict(60_000).fresh.isEmpty())
        watch.pageStart()
        assertEquals(listOf(WebBrowserRenderWatch.LOAD_ERROR), watch.verdict(60_100).recovered)
    }

    @Test fun decodingVideoWithoutCompositesIsWhite() {
        val watch = WebBrowserRenderWatch()
        watch.bind(0); watch.draw(1_000); watch.pageStart(); watch.pageStop(1_000, ok = true); watch.contentfulPaint()
        watch.media(1_000, isPlaying = true, WebBrowserVideoFrames.Interval()) // first report: no advance known yet
        assertFalse(watch.decodingAt(1_000))
        watch.media(5_000, isPlaying = true, WebBrowserVideoFrames.Interval(4_000, 120))
        assertTrue(watch.verdict(5_500).fresh.isEmpty())
        watch.media(6_500, isPlaying = true, WebBrowserVideoFrames.Interval(1_500, 90))
        assertEquals(listOf(WebBrowserRenderWatch.MEDIA), watch.verdict(7_000).fresh)
        watch.draw(7_100)
        assertEquals(listOf(WebBrowserRenderWatch.MEDIA), watch.verdict(7_200).recovered)
        // Decoding stopped: a still frame is not a white page.
        assertTrue(watch.verdict(30_000).fresh.isEmpty())
    }

    @Test fun perfCountsCompositesHitchesAndVideoFrames() {
        val watch = WebBrowserRenderWatch()
        watch.bind(0)
        assertEquals(null, watch.perf(5_000)) // window not over
        // 30 fps video: decoded frames advance, composites every 33 ms, one 400 ms stall.
        var t = 0L
        var previous = WebBrowserVideoFrames(1, 1, 0, 0, 0, 0)
        while (t < 10_000) {
            t += 33
            if (t in 5_000..5_400) continue
            val decoded = t * 30 / 1000
            val dropped = 12L.coerceAtMost(decoded)
            val current = previous.copy(at = t, decoded = decoded, presented = decoded - dropped, dropped = dropped)
            watch.media(t, isPlaying = true, current.since(previous, watch.boundAt))
            previous = current
            watch.draw(t)
        }
        val perf = watch.perf(10_000)!!
        assertEquals(1, perf.hitches)
        assertTrue(perf.maxGapMs in 400..440)
        assertTrue(perf.composites!! in 28.0..31.0)
        assertTrue(perf.decodedRate!! in 29.0..31.0)
        assertTrue(perf.presentedRate!! in 27.0..30.0)
        assertEquals(12L, perf.dropped)
        assertTrue(perf.toString(), perf.toString().startsWith("fps=29."))
        assertTrue(watch.lastPerf.contains("hitches=1"))
    }

    @Test fun activeMediaCountersCannotCrossElementsLoadsOrDisplays() {
        val first = WebBrowserVideoFrames(8, 12, 1000, 500, 498, 2)
        val later = first.copy(at = 2000, decoded = 530, presented = 527, dropped = 3)
        val empty = WebBrowserVideoFrames.Interval()
        assertEquals(WebBrowserVideoFrames.Interval(1000, 30, 29, 1), later.since(first, 0))
        assertEquals(empty, later.since(null, 0))
        assertEquals(empty, later.copy(id = 10).since(first, 0))
        assertEquals(empty, later.copy(epoch = 13).since(first, 0))
        assertEquals(empty, later.copy(decoded = 50, presented = 48).since(first, 0))
        assertEquals(empty, later.since(first, 1500))
        assertEquals(WebBrowserVideoFrames.Interval(1000), first.copy(at = 2000).since(first, 0))
    }

    @Test fun idlePagePerfIsSilentAndGapsDoNotCount() {
        val watch = WebBrowserRenderWatch()
        watch.bind(0); watch.draw(100); watch.draw(9_000) // a static page repaints rarely
        val perf = watch.perf(10_000)!!
        assertEquals(0, perf.hitches); assertEquals(0L, perf.maxGapMs)
        assertEquals(null, watch.perf(20_000)) // nothing at all: no line
        val steady = WebBrowserRenderWatch.Perf(10.0, 60.0, 20, 0, 30.0, 30.0, 0, 10.0)
        assertEquals(steady.signature(), WebBrowserRenderWatch.Perf(10.0, 61.0, 25, 0, 29.0, 29.5, 0, 10.0).signature())
        assertFalse(steady.signature() == WebBrowserRenderWatch.Perf(10.0, 35.0, 300, 12, 30.0, 18.0, 90, 10.0).signature())
    }

    @Test fun changeCanCompareACoarseSignature() {
        assertTrue(WebBrowserTrail.change("perf:1", "web.perf", "fps=60.1", "12"))
        assertFalse(WebBrowserTrail.change("perf:1", "web.perf", "fps=59.4", "12"))
        assertTrue(WebBrowserTrail.change("perf:1", "web.perf", "fps=31.0", "6"))
        assertEquals(listOf("web.perf fps=60.1", "web.perf fps=31.0"), logged)
    }

    @Test fun pixelProbeReportsRatiosOnly() {
        val white = IntArray(100) { 0xFFFFFFFF.toInt() }
        assertEquals("samples=100 white=1.00 black=0.00 dominant=1.00 colors=1", WebBrowserPixelProbe.describe(white))
        val page = IntArray(100) { if (it < 60) 0xFFFFFFFF.toInt() else (0xFF000000.toInt() or (it * 0x020305)) }
        val text = WebBrowserPixelProbe.describe(page)
        assertTrue(text, text.startsWith("samples=100 white=0.60 "))
        assertTrue(text, text.endsWith("dominant=0.60 colors=" + (1 + page.drop(60).map {
            ((it shr 20 and 0xf) shl 8) or ((it shr 12 and 0xf) shl 4) or (it shr 4 and 0xf) }.toSet().size)))
        assertEquals("samples=0", WebBrowserPixelProbe.describe(IntArray(0)))
    }
}
