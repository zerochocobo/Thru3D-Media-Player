package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Test-runtime entry point; private browser messages use stdin and never enter reports. */
object WebVideoDesktopProbe {
    @JvmStatic fun main(args: Array<String>) {
        val result = JSONObject().put("passed", false)
        try {
            val bytes = System.`in`.readNBytes(256 * 1024 + 1)
            require(bytes.size <= 256 * 1024)
            val media = JSONObject(bytes.toString(Charsets.UTF_8))
            val page = WebVideoDouyinCapture.page(media.getString("frame")) ?: error("Unsupported page")
            result.put("beta_default_enabled", WebBrowserDouyin.enabled(page.url))
            check(WebBrowserDouyin.enabled(page.url))
            val metadata = WebBrowserDouyin.metadata(media,page.url,media.optBoolean("douyin_enabled"))
            result.put("bridge_metadata",metadata != null)
            check(metadata != null)
            media.put("douyin",metadata)
            val bound = WebVideoDouyinCapture.candidate(page, media)
            result.put("candidate", bound != null).put("browser_source", if (media.optBoolean("blob")) "mse" else "file")
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            val network = WebVideoNetworkCapture({ uri, headers, prefix ->
                result.put("probe_calls", result.optInt("probe_calls") + 1)
                try {
                    RemoteMediaHttp().use { http ->
                        WebVideoBrowserResourceReader.read(uri, headers, prefix, http) {
                            check(System.nanoTime() < deadline)
                        }.also { (_, data) ->
                            val container = WebVideoContainer.parse(data)
                            result.put("prefix_bytes", data.size).put("container", container != null)
                                .put("container_duration", container?.duration ?: 0.0)
                        }
                    }
                } catch (error: Throwable) {
                    result.put("transport_error_type", error.javaClass.simpleName)
                    if (error is LinkageError) result.put("linkage", error.message?.take(200))
                    // RemoteMediaHttp messages are fixed categories and contain no addresses.
                    if (error is MediaServerFailure) result.put("transport_error", error.message)
                    throw error
                }
            }, { true }) // Desktop software decoding; this is not Android capability acceptance.
            val info = WebVideoDouyinCapture.resolve(page, media, network)
            result.put("inspected_files", network.inspectedFiles).put("video_files", network.videoFiles).put("audio_files", network.audioFiles)
            if (info != null) {
                val selected = WebVideoFormats.select(page, info) { true }
                result.put("width", selected.video.width).put("height", selected.video.height)
                    .put("video_codec", selected.video.videoCodec).put("audio_codec", selected.audio?.audioCodec ?: selected.video.audioCodec)
                    .put("has_audio", selected.video.hasAudio || selected.audio?.hasAudio == true).put("embedded_audio", selected.video.hasAudio)
                    .put("separate_audio", selected.audio != null).put("duration", selected.durationSeconds)
                    .put("current_file", selected.video.url.toString() == bound?.optString("source"))
                val expectedAudio = bound?.getJSONObject("douyin")?.optString("observed_audio").orEmpty()
                result.put("passed", (selected.video.hasAudio || selected.audio?.hasAudio == true) &&
                    selected.audio?.url?.toString().orEmpty() == expectedAudio &&
                    selected.video.url.toString() == bound?.optString("source") && WebVideoNetworkCapture.keepsQuality(selected.video, media))
            }
        } catch (error: Exception) {
            result.put("error_type", error.javaClass.simpleName)
        }
        println(result.toString())
    }
}
