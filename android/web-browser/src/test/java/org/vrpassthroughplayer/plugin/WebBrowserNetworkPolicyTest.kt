package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class WebBrowserNetworkPolicyTest {
    @Test fun unmarkedSitesDefaultOnAndExplicitChoiceSurvivesRestart() {
        var saved = "{}"
        val policy = WebBrowserNetworkPolicy(saved, { saved = it })
        assertFalse(policy.enabled("https://www.youtube.com/watch?v=fixture"))
        assertTrue(policy.enabled("https://unknown.test/another"))
        policy.set("https://unknown.test/private?token=private", false)
        assertFalse(policy.enabled("https://unknown.test/another"))
        assertTrue(policy.enabled("https://sub.unknown.test/"))
        assertTrue(policy.enabled("http://unknown.test/"))
        assertTrue(policy.enabled("https://unknown.test:8443/"))
        assertFalse(saved.contains("unknown.test")); assertFalse(saved.contains("private"))
        assertFalse(WebBrowserNetworkPolicy(saved, {}).enabled("https://unknown.test:443/new"))
        policy.set("https://unknown.test", true)
        assertTrue(WebBrowserNetworkPolicy(saved, {}).enabled("https://unknown.test:443/new"))
    }
    @Test fun hiddenSitesStayOffIncludingOldSavedOptInAndRespectHostBoundaries() {
        val key = MessageDigest.getInstance("SHA-256").digest("https://www.youtube.com".toByteArray())
            .joinToString("") { "%02x".format(it) }
        var writes = 0
        val policy = WebBrowserNetworkPolicy("{\"$key\":true}", { writes++ })
        for (host in WebBrowserNetworkPolicy.NATIVE_PLAYBACK_HOSTS.values.flatten()) {
            assertFalse(WebBrowserNetworkPolicy.available("https://$host/watch"))
            assertFalse(policy.enabled("http://m.$host:8080/watch"))
            assertTrue(WebBrowserNetworkPolicy.available("https://$host.example.org/"))
        }
        assertFalse(policy.enabled("https://www.youtube.com/watch"))
        policy.set("https://www.youtube.com/watch", true)
        assertEquals(0, writes)
        assertFalse(policy.enabled("https://www.youtube.com/watch"))
        assertTrue(policy.enabled("https://www.iqiyi.com/"))
        assertTrue(policy.enabled("https://www.douyin.com/"))
        assertTrue(policy.enabled("https://qq.com/")) // Only Tencent Video, not all QQ properties.
        assertFalse(WebBrowserNetworkPolicy.available("about:blank"))
        assertFalse(policy.enabled("file:///movie.mp4"))
        assertFalse(policy.enabled("https://user@unknown.test/"))
    }
    @Test fun failedWritesPreserveOldChoice() {
        val policy = WebBrowserNetworkPolicy("{}", { error("disk full") })
        assertThrows(Exception::class.java) { policy.set("https://unknown.test/", false) }
        assertTrue(policy.enabled("https://unknown.test/"))
        assertNull(WebBrowserNetworkPolicy.origin("about:blank"))
    }
    @Test fun hiddenSitesMatchExistingFeaturedNativePlaybackBadges() {
        val source = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .map { File(it, "app/godot/scripts/web_video_sites.gd") }.first { it.isFile }.readText()
        val names = Regex("\"([^\"]+)\"").findAll(source.substringAfter("const NATIVE_PLAYBACK := [").substringBefore(']'))
            .map { it.groupValues[1] }.toSet()
        assertEquals(names, WebBrowserNetworkPolicy.NATIVE_PLAYBACK_HOSTS.keys)
        val featured = Regex("\\{\"name\": \"([^\"]+)\", \"url\": \"([^\"]+)\"").findAll(source).toList()
        assertTrue(featured.isNotEmpty())
        for (entry in featured) assertEquals(entry.groupValues[1], entry.groupValues[1] !in names,
            WebBrowserNetworkPolicy.available(entry.groupValues[2]))
    }
}
