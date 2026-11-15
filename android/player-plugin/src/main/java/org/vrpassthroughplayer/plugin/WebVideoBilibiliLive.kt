package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

internal object WebVideoBilibiliLive {
    fun descriptor(url: String, media: JSONObject, selection: String): WebVideoDescriptor? {
        if (selection.isEmpty() || media.optString("capture_identity") != selection ||
            !media.optBoolean("bilibili_enabled")) return null
        val requests = WebBrowserNetworkMedia.candidates(media)
        val live = WebBrowserBilibiliLive.metadata(media, url, requests) ?: return null
        val room = live.getString("room")
        val address = live.getString("url")
        val request = (0 until requests.length()).map(requests::getJSONObject).single {
            it.optString("kind") == "hls" && it.optString("url") == address
        }
        val sourceHeaders = request.getJSONObject("headers")
        val headers = sourceHeaders.keys().asSequence().associateWith(sourceHeaders::getString)
        val track = WebVideoTrack("live-${live.getInt("quality")}", URI(address), headers, "mp4", "unknown", "unknown",
            media.getInt("width"), media.getInt("height"), fps = 0.0, transport = "live_hls")
        return WebVideoDescriptor(WebVideoPage("bilibili_live", room, "https://live.bilibili.com/$room"),
            "Bilibili Live · $room", track, null, 0.0)
    }

    fun checkInitialization(track: WebVideoTrack, bytes: ByteArray,
                            accepts: (WebVideoTrack) -> Boolean = WebVideoCapabilities(maxHeight = 2160)::accepts) {
        val init = WebVideoContainer.liveInitialization(bytes) ?: error("Unsupported live initialization")
        require((init.width == track.width || init.displayWidth == track.width) && init.height == track.height)
        val decoded = WebVideoTrack(track.formatId, track.url, emptyMap(), "mp4", init.video, init.audio,
            init.width, init.height, track.fps)
        require(accepts(decoded)) { "Unsupported live rendition" }
    }
}
