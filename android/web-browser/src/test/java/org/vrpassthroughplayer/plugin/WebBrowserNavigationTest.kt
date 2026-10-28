package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserNavigationTest {
    private fun reuse(destination: String, page: String = "https://www.bilibili.com/",
        trigger: String? = page, newWindow: Boolean = true, gesture: Boolean = true,
        direct: Boolean = false, redirect: Boolean = false) =
        WebBrowserNavigation.reusePage(page, trigger, destination, newWindow, gesture, direct, redirect)

    @Test fun personalMenuAndContentLinksReuseTheExistingPage() {
        for (url in listOf("https://space.bilibili.com/123", "https://space.bilibili.com/123/favlist?fid=456",
            "https://space.bilibili.com/123/dynamic", "https://t.bilibili.com/", "https://t.bilibili.com/123456",
            "https://www.bilibili.com/account/history", "https://www.bilibili.com/history",
            "https://account.bilibili.com/account/home", "https://account.bilibili.com/account/big",
            "https://www.bilibili.com/video/BV1xx411c7mD/?spm_id_from=333.1007",
            "https://www.bilibili.com/bangumi/play/ep123", "https://www.bilibili.com/list/123?sid=456",
            "https://www.bilibili.com/medialist/play/123", "https://search.bilibili.com/all?keyword=test",
            "https://m.bilibili.com/video/BV1xx411c7mD")) assertTrue(url, reuse(url))
    }

    @Test fun repeatedVisitsAndPlayerReturnsDoNotRequireAnotherPopupSlot() {
        // Playback keeps the browser sessions alive in 0.15.0. Returning must not
        // require an app restart or another child for every ordinary content link.
        var page = "https://www.bilibili.com/"
        val route = listOf("https://t.bilibili.com/", "https://space.bilibili.com/123/favlist",
            "https://www.bilibili.com/video/BV1xx411c7mD", "https://www.bilibili.com/account/history",
            "https://www.bilibili.com/", "https://account.bilibili.com/account/home")
        repeat(50) { for (next in route) { assertTrue("$page -> $next", reuse(next, page)); page = next } }
    }

    @Test fun normalNavigationAndNonUserPopupsAreNotReissued() {
        val video = "https://www.bilibili.com/video/BV1xx411c7mD"
        assertFalse(reuse(video, newWindow = false))
        assertFalse(reuse(video, gesture = false))
        assertFalse(reuse(video, direct = true))
        assertFalse(reuse(video, redirect = true))
        assertFalse(reuse(video, trigger = null))
    }

    @Test fun authenticationPaymentsAndScriptPopupsKeepTheirOriginalBehavior() {
        for (url in listOf("about:blank", "https://passport.bilibili.com/login",
            "https://account.bilibili.com/login", "https://account.bilibili.com/account/security",
            "https://pay.bilibili.com/", "https://www.bilibili.com/blackboard/payment.html",
            "https://www.bilibili.com/video/BV1xx411c7mD?code=oauth",
            "https://account.bilibili.com/account/home?%74icket=secret",
            "https://account.bilibili.com/account/home#access_token=secret")) assertFalse(url, reuse(url))
        assertFalse(reuse("https://www.bilibili.com/", page = "https://passport.bilibili.com/login"))
    }

    @Test fun videoSiteCardsOpenInTheCurrentPageWithinTheirOwnSite() {
        for ((page, url) in listOf("https://www.iqiyi.com/" to "https://www.iqiyi.com/v_19rrok4nt0.html",
            "https://www.iqiyi.com/" to "https://www.iqiyi.com/a_19rrhb3xvl.html",
            "https://www.youku.com/" to "https://v.youku.com/v_show/id_XNTk4MjQ5NjI0MA==.html",
            "https://www.youku.com/" to "https://v.youku.com/video?vid=XNTk4MjQ5NjI0MA%3D%3D&s=abc",
            "https://v.qq.com/" to "https://v.qq.com/x/cover/mzc00200abc/q326831cny0.html",
            "https://www.mgtv.com/" to "https://www.mgtv.com/b/427837/15588271.html",
            "https://www.youtube.com/" to "https://www.youtube.com/watch?v=aqz-KE-bpKQ")) assertTrue(url, reuse(url, page))
        // Cross-site and sign-in destinations keep Gecko's popup.
        assertFalse(reuse("https://www.youku.com/", "https://www.iqiyi.com/"))
        assertFalse(reuse("https://passport.iqiyi.com/apis/reglogin/login.action", "https://www.iqiyi.com/"))
        assertFalse(reuse("https://www.iqiyi.com/login", "https://www.iqiyi.com/"))
        assertFalse(reuse("https://accounts.google.com/ServiceLogin", "https://www.youtube.com/"))
    }

    @Test fun unrelatedSitesAndUntrustedFramesAreUnaffected() {
        val video = "https://www.bilibili.com/video/BV1xx411c7mD"
        for (url in listOf("https://example.com/", "https://www.bilibili.com.attacker.test/",
            "https://attackerbilibili.com/", "https://evil@www.bilibili.com/", "https://www.bilibili.com:444/",
            "javascript:alert(1)", "file:///sdcard/test", "intent://video")) {
            assertFalse(url, reuse(url))
            assertFalse(url, reuse(video, page = url))
            assertFalse(url, reuse(video, trigger = url))
        }
    }
}
