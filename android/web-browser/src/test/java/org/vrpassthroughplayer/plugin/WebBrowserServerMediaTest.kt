package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserServerMediaTest {
    private val page = "http://192.0.2.10:8096/web/index.html#!/item?id=42&serverId=s"

    @Test fun embyDirectPlayKeepsItsOriginalFile() {
        val source = "http://192.0.2.10:8096/emby/videos/42/original.mp4?DeviceId=d&MediaSourceId=abc&PlaySessionId=p&api_key=token"
        assertEquals("http://192.0.2.10:8096/emby/videos/42/original.mp4?Static=true&MediaSourceId=abc&api_key=token",
            WebBrowserServerMedia.original(source, page))
    }

    @Test fun streamsAndTranscodesMapToTheStaticStream() {
        assertEquals("http://192.0.2.10:8096/emby/videos/42/stream?Static=true&MediaSourceId=abc&api_key=token",
            WebBrowserServerMedia.original("http://192.0.2.10:8096/emby/videos/42/master.m3u8?MediaSourceId=abc&api_key=token&VideoCodec=h264", page))
        assertEquals("http://192.0.2.10:8096/Videos/42/stream?Static=true&MediaSourceId=abc&ApiKey=token",
            WebBrowserServerMedia.original("http://192.0.2.10:8096/Videos/42/stream.mkv?static=true&mediaSourceId=abc&ApiKey=token", page))
    }

    @Test fun rejectsOtherOriginsLiveStreamsAndUnknownFiles() {
        assertNull(WebBrowserServerMedia.original("http://198.51.100.1:8096/emby/videos/42/original.mp4?MediaSourceId=abc&api_key=t", page))
        assertNull(WebBrowserServerMedia.original("http://192.0.2.10:8096/emby/videos/42/original.mp4?MediaSourceId=abc&api_key=t&LiveStreamId=x", page))
        assertNull(WebBrowserServerMedia.original("http://192.0.2.10:8096/emby/videos/42/download.mp4?MediaSourceId=abc&api_key=t", page))
        assertNull(WebBrowserServerMedia.original("http://192.0.2.10:8096/emby/videos/42/original.mp4?api_key=t", page))
    }
}
