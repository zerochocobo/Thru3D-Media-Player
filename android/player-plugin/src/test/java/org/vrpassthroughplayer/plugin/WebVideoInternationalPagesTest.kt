package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebVideoInternationalPagesTest {
    @Test fun declaredPlayerIdentityIsRestrictedToIndividualVideoPages() {
        assertEquals("https://astalavr.com/videos/example/demo/", WebVideoPage.parse("https://astalavr.com/videos/example/demo/?tracking=discard").url)
        for (url in listOf("https://astalavr.com/", "https://astalavr.com/account", "https://astalavr.com.evil/videos/example/demo/"))
            assertThrows(Exception::class.java) { WebVideoPage.parse(url) }
    }
    @Test fun explicitSilentReelsDoNotRelaxMissingSplitAudioValidation() {
        val f = org.json.JSONObject().put("format_id", "0").put("url", "https://cdn.test/movie.mp4")
            .put("protocol", "https").put("ext", "mp4").put("acodec", "none")
        val info = org.json.JSONObject().put("formats", org.json.JSONArray().put(f))
        val reel = WebVideoPage.parse("https://www.instagram.com/reel/Chunk8-jurw/")
        assertTrue(WebVideoFormats.select(reel, info) { true }.silent)
        assertThrows(Exception::class.java) { WebVideoFormats.select(WebVideoPage.parse("https://youtube.com/watch?v=jNQXAC9IVRw"), info) { true } }
        f.put("format_id", "dash-video")
        assertThrows(Exception::class.java) { WebVideoFormats.select(reel, info) { true } }
    }
    @Test fun overseasPagesKeepVideoIdentityAndDropTracking() {
        val samples = mapOf(
            "https://www.tiktok.com/@patroxofficial/video/6742501081818877190?lang=en" to "https://www.tiktok.com/@patroxofficial/video/6742501081818877190",
            "分享 https://vm.tiktok.com/ZM123abcd/ 复制打开" to "https://vm.tiktok.com/ZM123abcd/",
            "https://www.tiktok.com/t/ZM123abcd/?tracking=private" to "https://www.tiktok.com/t/ZM123abcd/",
            "https://instagram.com/reels/Chunk8-jurw/?igsh=private" to "https://www.instagram.com/reel/Chunk8-jurw/",
            "https://www.facebook.com/radiokicksfm/videos/3676516585958356/?tracking=private" to "https://www.facebook.com/watch/?v=3676516585958356",
            "https://m.facebook.com/reel/1195289147628387" to "https://www.facebook.com/watch/?v=1195289147628387",
            "https://www.facebook.com/video.php?v=637842556329505&token=private" to "https://www.facebook.com/watch/?v=637842556329505",
            "https://fb.watch/Abc_123/?token=private" to "https://fb.watch/Abc_123/",
            "https://twitter.com/starwars/status/665052190608723968/video/2?s=private" to "https://x.com/i/status/665052190608723968/video/2",
            "https://www.reddit.com/r/aww/comments/90bu6w/title/?share_id=private" to "https://www.reddit.com/comments/90bu6w/",
            "https://redd.it/90bu6w" to "https://www.reddit.com/comments/90bu6w/",
            "https://streamable.com/e/dnd1?token=private" to "https://streamable.com/dnd1",
            "https://embed.ted.com/talks/a_public_talk?tracking=private" to "https://www.ted.com/talks/a_public_talk",
            "https://archive.org/details/Cops1922/file.mp4?tracking=private" to "https://archive.org/details/Cops1922/file.mp4",
            "https://www.rumble.com/vdmum1-demo.html?token=private" to "https://rumble.com/vdmum1-demo.html",
            "https://odysee.com/@Example:1/demo:2?signature=private" to "https://odysee.com/@Example:1/demo:2",
            "https://nico.ms/sm8628149?from=private" to "https://www.nicovideo.jp/watch/sm8628149",
            "https://m.tv.naver.com/embed/81652?tracking=private" to "https://tv.naver.com/v/81652",
            "https://tv.kakao.com/channel/2671005/cliplink/301965083?tracking=private" to "https://tv.kakao.com/embed/player/cliplink/301965083",
            "https://geo.dailymotion.com/player.html?video=x89eyek&mute=true" to "https://www.dailymotion.com/video/x89eyek",
            "https://clips.twitch.tv/embed?clip=InquisitiveBreakableYogurtJebaited" to "https://clips.twitch.tv/InquisitiveBreakableYogurtJebaited"
        )
        samples.forEach { (input, expected) -> assertEquals(input, expected, WebVideoPage.parse(input).url) }
        assertNotEquals(WebVideoPage.parse("https://x.com/i/status/665052190608723968/video/1").id,
            WebVideoPage.parse("https://x.com/i/status/665052190608723968/video/2").id)
    }

    @Test fun rejectsProfileFeedsCrossSiteSuffixesAndNonPublicAccessPaths() {
        val invalid = listOf("https://instagram.com/example", "https://www.tiktok.com/@example", "https://www.facebook.com/profile.php?id=12345",
            "https://www.reddit.com/r/videos/", "https://x.com/home", "https://x.com/i/status/665052190608723968/video/0",
            "https://ted.com/playlists/171/popular", "https://www.nicovideo.jp/mylist/123", "https://tv.naver.com/l/127062",
            "https://rumble.com/c/channel", "https://odysee.com/@Example:1", "https://archive.org/details/../secret",
            "https://instagram.com.evil/reel/Chunk8-jurw/", "https://user:secret@streamable.com/dnd1")
        invalid.forEach { url -> assertThrows(url, Exception::class.java) { WebVideoPage.parse(url) } }
    }
}
