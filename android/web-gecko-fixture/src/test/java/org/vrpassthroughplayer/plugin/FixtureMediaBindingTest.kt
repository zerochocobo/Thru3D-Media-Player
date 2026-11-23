package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FixtureMediaBindingTest {
    @Test fun miguSamplesAreExactObservationOnlyPages() {
        val page="https://www.miguvideo.com/p/vertical/968096380"
        assertEquals("968096380",FixtureMediaBinding.miguSample(page))
        assertEquals("966398567",FixtureMediaBinding.miguSample(page.replace("968096380","966398567")))
        assertNull(FixtureMediaBinding.adapter(page))
        assertNull(FixtureMediaBinding.metadata(JSONObject(),page,"migu"))
        for (other in listOf("$page?extra=1",page.replace("www.miguvideo.com","www.miguvideo.com.example"),page.replace("968096380","123"))) {
            assertNull(FixtureMediaBinding.miguSample(other))
        }
    }

    private val twitchPage = "https://www.twitch.tv/public_channel/clip/PublicClip"
    private val file = "https://actual-related.test/current.mp4?sig=synthetic"
    private val tedPage = "https://www.ted.com/talks/current_talk"
    private val youkuPage = "https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html"
    private val root = "https://actual-related.test/current.m3u8?sig=synthetic"
    private fun twitch() = JSONObject().put("id", "1").put("frame", twitchPage).put("source", file)
        .put("network_epoch", 3).put("width", 1920).put("height", 1080).put("duration", 15.78)
        .put("twitch", JSONObject().put("id", "PublicClip").put("page", twitchPage).put("source", file)
            .put("revision", "ab12").put("width", 1920).put("height", 1080).put("duration", 15.78).put("expected_duration", 15))
        .put("network", JSONArray().put(JSONObject().put("kind", "file").put("url", file).put("headers", JSONObject())))
    private fun ted() = JSONObject().put("id", "1").put("frame", tedPage).put("source", "").put("blob", true)
        .put("ted_source", "blob:https://www.ted.com/original").put("network_epoch", 4)
        .put("width", 1280).put("height", 720).put("duration", 679.973)
        .put("ted", JSONObject().put("id", "current_talk").put("talk_id", "86532").put("player_id", "416668")
            .put("page", tedPage).put("root", root).put("revision", "ab12").put("width", 1280).put("height", 720)
            .put("duration", 679.973).put("expected_duration", 679))
        .put("network", JSONArray().put(JSONObject().put("kind", "hls").put("url", root).put("headers", JSONObject())))

    @Test fun pausedPositionChangesKeepTheOriginalBinding() {
        for ((kind, page, original) in listOf(Triple("twitch", twitchPage, twitch()), Triple("ted", tedPage, ted()))) {
            val current = JSONObject(original.toString()).put("playing", false).put("time", 10.0)
            assertNotNull(FixtureMediaBinding.metadata(current, page, kind))
            assertTrue(FixtureMediaBinding.same(original, current, page, kind))
            for ((key, value) in listOf("id" to "2", "network_epoch" to 9, "frame" to "$page?next=1")) {
                val changed = JSONObject(current.toString()).put(key, value)
                assertFalse(key, FixtureMediaBinding.same(original, changed, page, kind))
            }
            val changed = JSONObject(current.toString())
            changed.getJSONObject(kind).put("revision", "ab13")
            assertFalse(FixtureMediaBinding.same(original, changed, page, kind))
            assertFalse(FixtureMediaBinding.same(original, current.put("protected", true), page, kind))
        }
    }

    @Test fun twitchListRangePreservesTheOriginalFileAndEpoch() {
        val updatedPage = "$twitchPage?range=7d"
        val fresh = twitch().put("frame", updatedPage)
        fresh.getJSONObject("twitch").put("page", updatedPage)
        assertTrue(FixtureMediaBinding.same(twitch(), fresh, updatedPage, "twitch"))
        assertFalse(FixtureMediaBinding.same(twitch(), fresh.put("network_epoch", 4), updatedPage, "twitch"))
    }

    @Test fun aNewValidSourceCannotReplaceTheSuspendedOriginal() {
        val original = twitch()
        val changed = twitch().put("source", file + "&next=1")
        changed.getJSONObject("twitch").put("source", file + "&next=1")
        changed.getJSONArray("network").getJSONObject(0).put("url", file + "&next=1")
        assertNotNull(FixtureMediaBinding.metadata(changed, twitchPage))
        assertFalse(FixtureMediaBinding.same(original, changed, twitchPage, "twitch"))
        val talk = ted()
        val otherBlob = ted().put("ted_source", "blob:https://www.ted.com/replaced")
        assertNotNull(FixtureMediaBinding.metadata(otherBlob, tedPage))
        assertFalse(FixtureMediaBinding.same(talk, otherBlob, tedPage, "ted"))
    }

    @Test fun youkuFixtureKeepsOnlyTheProductionValidatedCurrentPlaylist() {
        fun media(url: String) = JSONObject().put("id", "1").put("frame", youkuPage).put("source", "").put("blob", true)
            .put("network_epoch", 4).put("width", 1280).put("height", 720).put("duration", 702.079)
            .put("youku", JSONObject().put("id", "XOTUxMzg4NDMy").put("page", youkuPage).put("revision", "ab12")
                .put("declared_drm", "default").put("width", 1280).put("height", 720).put("duration", 702.079)
                .put("expected_duration", 702.08).put("manifests", JSONArray().put(url))
                .put("declarations", JSONArray().put(JSONObject().put("url", root).put("width", 1280).put("height", 720).put("duration", 702.08))))
            .put("network", JSONArray().put(JSONObject().put("kind", "hls").put("url", url).put("original_url", root).put("headers", JSONObject())))
        val original = media(root)
        val redirected = media("https://related.test/redirected.m3u8?sig=actual")
        assertNotNull(FixtureMediaBinding.metadata(redirected, youkuPage, "youku"))
        assertTrue(FixtureMediaBinding.same(original, JSONObject(original.toString()).put("time", 351.04), youkuPage, "youku"))
        assertFalse(FixtureMediaBinding.same(original, redirected, youkuPage, "youku"))
        assertNull(FixtureMediaBinding.metadata(original.put("protected", true), youkuPage, "youku"))
    }

    @Test fun readOnlyOrDifferentAdaptersCannotArmTheBridge() {
        assertNull(FixtureMediaBinding.adapter("https://www.iqiyi.com/v_public.html"))
        assertNull(FixtureMediaBinding.adapter("https://www.twitch.tv/public_channel"))
        assertNull(FixtureMediaBinding.metadata(twitch(), twitchPage, "ted"))
        assertNull(FixtureMediaBinding.metadata(ted(), tedPage, "twitch"))
        assertNull(FixtureMediaBinding.metadata(twitch(), tedPage, "twitch"))
        assertNull(FixtureMediaBinding.metadata(ted(), twitchPage, "ted"))
    }

    @Test fun redBullResearchKeepsTheOriginalBlobRootAndMediaEpoch() {
        val id = "rrn:content:films:f9d7a128-fd11-4e0c-9049-77de0f9515bd"
        val page = "https://www.redbull.tv/en/page/$id/anytime"
        val original = JSONObject().put("id", "1").put("frame", page).put("source", "").put("blob", true)
            .put("redbull_source", "blob:https://www.redbull.tv/original").put("network_epoch", 4)
            .put("width", 1920).put("height", 1080).put("duration", 3945.0661)
            .put("redbull", JSONObject().put("id", id).put("page", page).put("root", root)
                .put("revision", "ab12").put("width", 1920).put("height", 1080)
                .put("duration", 3945.0661).put("expected_duration", 3945))
            .put("network", JSONArray().put(JSONObject().put("kind", "hls").put("url", root)))
        assertTrue(FixtureMediaBinding.same(original, JSONObject(original.toString()).put("time", 30.0), page, "redbull"))
        for ((key, value) in listOf("redbull_source" to "blob:https://www.redbull.tv/replaced", "network_epoch" to 5)) {
            val changed = JSONObject(original.toString()).put(key, value)
            assertNotNull(FixtureMediaBinding.metadata(changed, page))
            assertFalse(FixtureMediaBinding.same(original, changed, page, "redbull"))
        }
        val changedRoot = JSONObject(original.toString())
        changedRoot.getJSONObject("redbull").put("root", "$root&variant=other")
        changedRoot.getJSONArray("network").getJSONObject(0).put("url", "$root&variant=other")
        assertNotNull(FixtureMediaBinding.metadata(changedRoot, page))
        assertFalse(FixtureMediaBinding.same(original, changedRoot, page, "redbull"))

        val seeking = JSONObject(original.toString()).put("redbull", JSONObject.NULL).put("redbull_source", "")
        assertTrue(FixtureMediaBinding.waitingForSeek(original, seeking, page, "redbull"))
        assertFalse(FixtureMediaBinding.sameReturned(original, seeking, page, "redbull"))
        for ((key, value) in listOf("redbull_source" to "blob:https://www.redbull.tv/replaced", "network_epoch" to 5,
            "id" to "2", "width" to 426, "protected" to true, "redbull_ready" to true)) {
            val changed = JSONObject(seeking.toString()).put(key, value)
            assertFalse(key, FixtureMediaBinding.waitingForSeek(original, changed, page, "redbull"))
        }
    }

    @Test fun aSeekCanWaitForMetadataButCannotQualifyOrReplaceTheOriginalMedia() {
        for ((kind, page, original) in listOf(Triple("twitch", twitchPage, twitch()), Triple("ted", tedPage, ted()))) {
            val pending = JSONObject(original.toString()).put(kind, JSONObject.NULL).put("${kind}_ready", false)
            if (kind == "ted") pending.put("ted_source", "")
            assertTrue(FixtureMediaBinding.waitingForSeek(original, pending, page, kind))
            assertFalse(FixtureMediaBinding.same(original, pending, page, kind))
            assertNull(FixtureMediaBinding.metadata(pending, page, kind))
            for ((key, value) in listOf("id" to "2", "frame" to "$page?new=1", "source" to "https://other.test/next.mp4",
                "network_epoch" to 9, "protected" to true, "blob" to !original.optBoolean("blob"), "${kind}_ready" to true)) {
                assertFalse(key, FixtureMediaBinding.waitingForSeek(original, JSONObject(pending.toString()).put(key, value), page, kind))
            }
            val changed = JSONObject(pending.toString()).put(kind, JSONObject(original.getJSONObject(kind).toString()).put("revision", "ab13"))
            assertFalse(FixtureMediaBinding.waitingForSeek(original, changed, page, kind))
            assertFalse(FixtureMediaBinding.waitingForSeek(original, pending, "$page?new=1", kind))
            assertEquals(kind=="ted",FixtureMediaBinding.waitingForSeek(original,JSONObject(pending.toString()).put("width",640),page,kind))
        }
        assertFalse(FixtureMediaBinding.waitingForSeek(ted(), ted().put("ted", JSONObject.NULL).put("ted_source", "blob:https://www.ted.com/replaced"), tedPage, "ted"))
    }

    @Test fun returnedTedMayChangeResolutionOnlyInsideTheOriginalContentAndMseEpoch() {
        val original=ted()
        val changed=ted().put("width",1920).put("height",1080)
        changed.getJSONObject("ted").put("width",1920).put("height",1080).put("revision","ab13")
        assertFalse(FixtureMediaBinding.same(original,changed,tedPage,"ted"))
        assertTrue(FixtureMediaBinding.sameReturned(original,changed,tedPage,"ted"))
        for ((key,value) in listOf("id" to "2","frame" to "$tedPage?next=1","network_epoch" to 9,
            "ted_source" to "blob:https://www.ted.com/replaced","protected" to true))
            assertFalse(key,FixtureMediaBinding.sameReturned(original,JSONObject(changed.toString()).put(key,value),tedPage,"ted"))
        for ((key,value) in listOf("id" to "next_talk","talk_id" to "86533","player_id" to "416669","root" to "$root&next=1","expected_duration" to 680)) {
            val next=JSONObject(changed.toString());next.getJSONObject("ted").put(key,value)
            assertFalse(key,FixtureMediaBinding.sameReturned(original,next,tedPage,"ted"))
        }
        val file=twitch().put("width",1280).put("height",720)
        file.getJSONObject("twitch").put("width",1280).put("height",720).put("revision","ab13")
        assertFalse(FixtureMediaBinding.sameReturned(twitch(),file,twitchPage,"twitch"))
    }
}
