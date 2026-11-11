package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FixtureMediaBindingTest {
    private val twitchPage = "https://www.twitch.tv/public_channel/clip/PublicClip"
    private val file = "https://actual-related.test/current.mp4?sig=synthetic"
    private val tedPage = "https://www.ted.com/talks/current_talk"
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

    @Test fun readOnlyOrDifferentAdaptersCannotArmTheBridge() {
        assertNull(FixtureMediaBinding.adapter("https://www.iqiyi.com/v_public.html"))
        assertNull(FixtureMediaBinding.adapter("https://www.twitch.tv/public_channel"))
        assertNull(FixtureMediaBinding.metadata(twitch(), twitchPage, "ted"))
        assertNull(FixtureMediaBinding.metadata(ted(), tedPage, "twitch"))
        assertNull(FixtureMediaBinding.metadata(twitch(), tedPage, "twitch"))
        assertNull(FixtureMediaBinding.metadata(ted(), twitchPage, "ted"))
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
