package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

/** Opt-in host check. Upstream signed URLs stay in private pipes and native objects. */
class WebVideoLiveProbeTest {
    @Test fun decodeAndSeekAnonymousSamples() {
        val python = System.getenv("WEB_VIDEO_PROBE_PYTHON")
        org.junit.Assume.assumeTrue(!python.isNullOrBlank())
        val root = File(System.getenv("WEB_VIDEO_PROBE_ROOT")!!)
        val ffmpeg = System.getenv("WEB_VIDEO_FFMPEG")!!
        val sink = File(if (System.getProperty("os.name").orEmpty().startsWith("Windows")) "NUL" else "/dev/null")
        val results = JSONArray()
        val names = System.getenv("WEB_VIDEO_PROBE_SITES")?.split(',') ?: listOf("weibo", "tencent", "mgtv", "youku")
        val sampleProcess = ProcessBuilder(python!!, File(root, "tools/Test-WebVideoSites.py").path, "--list-samples").redirectError(sink).start()
        val samples = try {
            check(sampleProcess.waitFor(10, TimeUnit.SECONDS) && sampleProcess.exitValue() == 0)
            JSONObject(sampleProcess.inputStream.bufferedReader().use { it.readText() })
        } finally { sampleProcess.destroyForcibly() }
        val sites = names.associateWith(samples::getString)
        fun decode(url: String, audio: String?, seek: Boolean, silent: Boolean, unknownAudio: Boolean): Boolean {
            val args = mutableListOf(ffmpeg, "-nostdin", "-v", "error")
            if (seek) args += listOf("-ss", "2")
            args += listOf("-i", url)
            if (audio != null) { if (seek) args += listOf("-ss", "2"); args += listOf("-i", audio) }
            args += listOf("-t", "2", "-map", "0:v:0")
            if (!silent) args += listOf("-map", (if (audio == null) "0:a:0" else "1:a:0") + if (unknownAudio) "?" else "")
            args += listOf("-f", "null", "-")
            val p = ProcessBuilder(args).redirectError(sink).redirectOutput(sink).start()
            return try { p.waitFor(50, TimeUnit.SECONDS) && p.exitValue() == 0 } finally { p.destroyForcibly() }
        }
        // Python honors the host's proxy environment; Java does not. Explicit opt-in
        // keeps the host probe on the same network route without changing app code.
        val previousProxy = java.net.ProxySelector.getDefault()
        val proxyEnabled = System.getenv("WEB_VIDEO_PROBE_USE_PROXY") == "1"
        if (proxyEnabled) java.net.ProxySelector.setDefault(object : java.net.ProxySelector() {
            override fun select(uri: java.net.URI): MutableList<java.net.Proxy> {
                if (uri.host in setOf("localhost", "127.0.0.1", "::1", "[::1]")) return mutableListOf(java.net.Proxy.NO_PROXY)
                val endpoint = System.getenv(if (uri.scheme == "https") "HTTPS_PROXY" else "HTTP_PROXY")
                if (endpoint.isNullOrBlank()) return mutableListOf(java.net.Proxy.NO_PROXY)
                val proxy = java.net.URI(endpoint)
                require(proxy.scheme == "http" && proxy.rawUserInfo == null) { "Unsupported host proxy configuration" }
                return mutableListOf(java.net.Proxy(java.net.Proxy.Type.HTTP, java.net.InetSocketAddress(proxy.host, if (proxy.port > 0) proxy.port else 80)))
            }
            override fun connectFailed(uri: java.net.URI, address: java.net.SocketAddress, error: java.io.IOException) {}
        })
        try { for ((site, page) in sites) {
            val result = JSONObject().put("site", site)
            var stage = "extraction"
            try {
                val process = ProcessBuilder(python, File(root, "tools/Test-WebVideoSites.py").path, "--site", site, "--pipe-formats")
                    .redirectError(sink).start()
                val reader = java.util.concurrent.Executors.newSingleThreadExecutor()
                val output = try {
                    val pending = reader.submit<String> { process.inputStream.bufferedReader().use { it.readText() } }
                    check(process.waitFor(80, TimeUnit.SECONDS) && process.exitValue() == 0)
                    pending.get(2, TimeUnit.SECONDS)
                } finally { process.destroyForcibly(); reader.shutdownNow() }
                val info = JSONObject(output)
                if (info.has("error_code")) { result.put("state", info.getString("error_code")); continue }
                stage = "selection"
                val descriptor = WebVideoFormats.select(WebVideoPage.parse(page), info) { track ->
                    minOf(track.height, track.width) <= 1080 && maxOf(track.height, track.width) <= 2160 && (track.videoCodec in setOf("unknown", "h264") || track.videoCodec.startsWith("avc"))
                }
                result.put("transport", descriptor.video.transport)
                LocalStreamServer().use { server -> WebVideoStreams { server }.use { streams ->
                    stage = "transport"
                    val url = streams.prepare(descriptor)
                    // Production proxy URLs are safe, random loopback capabilities.
                    val audio = streams.audio(descriptor.page.url).firstOrNull()?.location
                    val unknownAudio = (descriptor.audio ?: descriptor.video).audioCodec == "unknown"
                    val decoded = decode(url, audio, false, descriptor.silent, unknownAudio)
                    result.put("declared_silent", descriptor.silent).put("audio_metadata_unknown", unknownAudio)
                        .put("decoded", decoded).put("seeked", decoded && decode(url, audio, true, descriptor.silent, unknownAudio))
                    streams.release(url)
                } }
                result.put("state", "checked")
            } catch (error: Exception) {
                result.put("state", "probe_failed").put("stage", stage).put("type", error.javaClass.simpleName)
                // The transport's own error text is sanitized; no upstream address is emitted.
                if (error is MediaServerFailure) result.put("reason", error.code).put("http_status", error.httpStatus).put("transport_error", error.transportError)
                error.stackTrace.firstOrNull { it.className.endsWith("WebVideoHls") }?.let { result.put("hls_line", it.lineNumber) }
            }
            finally { results.put(result); println("Anonymous media check: " + result.toString()) }
        }
        val report = System.getenv("WEB_VIDEO_PROBE_REPORT")?.takeIf { it.matches(Regex("[a-z0-9-]+")) } ?: "playback-probe"
        File(root, "build/output/web-sites/$report.json").writeText(JSONObject().put("host_proxy", proxyEnabled).put("results", results).toString(2))
        } finally { if (proxyEnabled) java.net.ProxySelector.setDefault(previousProxy) }
    }
}
