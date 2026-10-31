package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class WebBrowserMediaPolicyTest {
    @Test fun boundBilibiliPartWinsOverPlayingOrLargerPreviews() {
        val main = JSONObject().put("bilibili_enabled", true).put("bilibili", JSONObject())
            .put("width", 852).put("height", 480).put("playing", false)
        val preview = JSONObject().put("width", 3840).put("height", 2160).put("playing", true).put("fullscreen", true)
        assertSame(main, WebBrowserMediaPolicy.extractionCandidate(listOf(preview, main)))
        main.remove("bilibili")
        assertSame(preview, WebBrowserMediaPolicy.extractionCandidate(listOf(preview, main)))
        assertNull(WebBrowserMediaPolicy.extractionCandidate(emptyList()))
    }
    @Test fun subscriptionPlaybackUsesOnlyItsOwnSecureOrigins() {
        for (host in listOf("www.netflix.com", "www.disneyplus.com", "www.primevideo.com", "www.max.com",
            "play.hbomax.com", "www.hulu.com", "www.paramountplus.com", "tv.apple.com")) {
            val origin = "https://$host"
            assertTrue(host, WebBrowserMediaPolicy.permitsKeys("$origin/watch/example", origin, null))
            for (bad in listOf("http://$host", "https://$host.evil.test", "https://user@$host", "https://$host:8443")) {
                assertFalse(bad, WebBrowserMediaPolicy.permitsKeys(origin, bad, null))
                assertFalse(bad, WebBrowserMediaPolicy.permitsKeys(bad, origin, null))
            }
            // Subscription sessions remain inside Gecko, never exported to the extractor.
            assertTrue(host, WebVideoSessionScope.domains(origin).isEmpty())
        }
        assertFalse(WebBrowserMediaPolicy.permitsKeys("https://www.netflix.com/watch/1", "https://www.disneyplus.com", null))
        assertFalse(WebBrowserMediaPolicy.permitsKeys("https://www.netflix.com/watch/1", "https://www.netflix.com", "https://other.test"))
    }
    @Test fun onlyLegacyFirstPartyNetflixDenialsCanBeReevaluated() {
        assertTrue(WebBrowserMediaPolicy.resetsLegacyDenial("https://www.netflix.com/watch/1", "https://www.netflix.com", null))
        assertFalse(WebBrowserMediaPolicy.resetsLegacyDenial("https://www.disneyplus.com", "https://www.disneyplus.com", null))
        assertFalse(WebBrowserMediaPolicy.resetsLegacyDenial("https://netflix.com.evil.test", "https://netflix.com.evil.test", null))
        assertFalse(WebBrowserMediaPolicy.resetsLegacyDenial("https://www.netflix.com", "https://other.test", null))
        assertFalse(WebBrowserMediaPolicy.resetsLegacyDenial("https://www.netflix.com", "https://www.netflix.com", "https://other.test"))
    }
    @Test fun emeStaysOnKnownHttpsFirstPartyOrigins() {
        assertTrue(WebBrowserMediaPolicy.permitsKeys("https://www.primevideo.com/detail/1", "https://www.primevideo.com", null))
        assertTrue(WebBrowserMediaPolicy.permitsKeys("https://tv.apple.com/", "https://tv.apple.com/", "https://tv.apple.com"))
        assertFalse(WebBrowserMediaPolicy.permitsKeys("https://disneyplus.com.evil/", "https://disneyplus.com.evil/", null))
        assertFalse(WebBrowserMediaPolicy.permitsKeys("https://www.hulu.com/", "https://other.test/", null))
        assertFalse(WebBrowserMediaPolicy.permitsKeys("http://www.hulu.com/", "https://www.hulu.com/", null))
        assertFalse(WebBrowserMediaPolicy.permitsKeys("https://www.hulu.com/", "https://www.hulu.com/", "https://unrelated.test"))
    }
    @Test fun cookieDomainGroupsAreExplicitAndDoNotMixAccounts() {
        assertEquals(listOf("weibo.com", "weibo.cn"), WebVideoSessionScope.domains("https://m.weibo.cn/detail/1"))
        assertEquals(listOf("douyin.com", "iesdouyin.com"), WebVideoSessionScope.domains("https://v.douyin.com/share"))
        assertEquals(listOf("twitter.com", "x.com"), WebVideoSessionScope.domains("https://x.com/i/status/12345"))
        assertEquals(listOf("facebook.com", "fb.watch"), WebVideoSessionScope.domains("https://fb.watch/example/"))
        assertEquals(listOf("instagram.com"), WebVideoSessionScope.domains("https://www.instagram.com/reel/example/"))
        assertEquals(listOf("nicovideo.jp", "nico.ms"), WebVideoSessionScope.domains("https://nico.ms/sm8628149"))
        for (url in listOf("https://weibo.com.evil/", "https://user@douyin.com/", "file:///youtube.com", "https://www.primevideo.com/"))
            assertTrue(WebVideoSessionScope.domains(url).isEmpty())
    }
}
