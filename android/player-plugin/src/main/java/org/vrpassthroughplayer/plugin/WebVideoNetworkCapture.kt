package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.util.Locale
import org.w3c.dom.Element

/** Resolve only the resources already associated with the selected browser video. No site
 * API scraping, POST replay, DRM extraction or Python startup on the successful path. */
internal class WebVideoNetworkCapture(
    private val fetch: (URI, Map<String, String>, Boolean) -> Pair<URI, ByteArray>,
    private val accepts: (WebVideoTrack) -> Boolean,
) {
    private class Resource(val uri: URI, val kind: String, val headers: Map<String, String>)
    private class Probed(val resource: Resource, val info: WebVideoContainer.Info, val format: JSONObject)
    private val resources = LinkedHashMap<URI, Resource>()
    private val bodies = HashMap<URI, Pair<URI, ByteArray>>()
    private val cookieJar = JSONArray()
    val projections = HashMap<URI, JSONObject?>()
    private var reads = 0
    private var formatSequence = 0

    companion object {
        fun keepsQuality(track: WebVideoTrack, media: JSONObject): Boolean {
            val width = media.optInt("width"); val height = media.optInt("height")
            return width <= 0 || height <= 0 || track.width >= width && track.height >= height
        }
        fun page(url: String, media: JSONObject): WebVideoPage? = runCatching {
            require(media.optBoolean("network_enabled") && !media.optBoolean("protected") && WebBrowserNetworkMedia.address(url.substringBefore('#')) != null)
            require(WebBrowserNetworkMedia.address(media.optString("source")) != null || WebBrowserNetworkMedia.candidates(media).length() > 0)
            // Generic pages may put an access token in any part of the URL. Keep their identity
            // opaque; the existing handoff context retains the actual originating browser tab.
            val key = "$url\n${media.optString("frame")}\n${media.optString("id")}\n${media.optLong("network_epoch")}"
            val id = java.security.MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
            WebVideoPage("browser", id, "webvideo://capture/$id")
        }.getOrNull()

        private fun query(uri: URI): Map<String, String> = uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        /** Only known byte-range-in-query endpoints can drop that range, and only when the
         * signature explicitly does not cover it. Never remove an arbitrary signed parameter. */
        internal fun wholeFile(uri: URI): URI? = runCatching {
            if (!uri.host.lowercase(Locale.ROOT).endsWith(".googlevideo.com") || uri.path != "/videoplayback") return uri
            val args = query(uri)
            require(args["sq"] == null && args["sabr"] == null && args["live"] != "1" && args["source"] != "yt_live_broadcast")
            if (!args.containsKey("range")) return uri
            require(args.containsKey("sparams") && listOf("sparams", "lsparams").none { args[it].orEmpty().split(',').contains("range") })
            URI("${uri.scheme}://${uri.rawAuthority}${uri.rawPath}?" + uri.rawQuery.split('&').filterNot {
                URLDecoder.decode(it.substringBefore('='), "UTF-8") == "range"
            }.joinToString("&"))
        }.getOrNull()

        internal fun group(uri: URI): String? = runCatching {
            val host = uri.host.lowercase(Locale.ROOT)
            if (host.endsWith(".googlevideo.com") && uri.path == "/videoplayback") {
                val args = query(uri)
                val id = args["id"]?.takeIf { it.matches(Regex("[A-Za-z0-9._-]{8,128}")) } ?: return null
                require(args["source"] == "youtube" && args["sq"] == null && args["live"] != "1")
                // Audio/video IDs can differ in their trailing representation suffix.
                return "youtube:${id.substringBefore('.')}"
            }
            if (Regex("(?:^|.*\\.)bilivideo\\.(com|cn)").matches(host)) {
                val directory = Regex("^/(?:v1/resource/)?upgcxcode/\\d{1,3}/\\d{1,3}/([1-9][0-9]{0,19})/[A-Za-z0-9_-]{1,160}\\.m4s$")
                    .find(uri.rawPath)?.groupValues?.get(1)
                val filename = Regex("/([1-9][0-9]{0,19})-[^/]+\\.m4s$").find(uri.rawPath)?.groupValues?.get(1)
                if (directory != null && filename != null && directory != filename) return null
                return (directory ?: filename)?.let { "bilibili:$it" }
            }
            null
        }.getOrNull()
    }

    private fun headers(json: JSONObject): Map<String, String> = json.keys().asSequence().associateWith { json.getString(it) }
    private fun scoped(from: Resource, target: URI): Resource {
        resources[target]?.let { return it }
        // Captured credentials describe one request, not every resource on that host. Do not
        // expand a path-scoped Cookie or per-request authorization to an unobserved child.
        return Resource(target, "file", WebVideoRequestHeaders(emptyMap(), cookieJar).forUrl(target, from.headers))
    }
    private fun read(resource: Resource, prefix: Boolean): Pair<URI, ByteArray> = bodies.getOrPut(resource.uri) {
        require(++reads <= 12) { "Browser probe budget" }
        fetch(resource.uri, resource.headers, prefix)
    }
    private fun format(resource: Resource, video: String, audio: String, width: Int = 0, height: Int = 0): JSONObject = JSONObject()
        .put("format_id", "network-${++formatSequence}")
        .put("url", resource.uri.toString()).put("http_headers", JSONObject(resource.headers))
        .put("protocol", if (resource.kind == "hls") "m3u8_native" else resource.uri.scheme)
        .put("ext", if (resource.uri.path.endsWith(".webm", true)) "webm" else if (video == "none") "m4a" else "mp4")
        .put("vcodec", video).put("acodec", audio).put("width", width).put("height", height)
        .also { if (resource.kind == "hls") it.put("browser_headers", JSONObject(resources.values.associate { entry -> entry.uri.toString() to JSONObject(entry.headers) }))
            .put("browser_cookies", cookieJar) }
    private fun info(media: JSONObject, list: List<JSONObject>): JSONObject = JSONObject()
        .put("title", media.optString("title").take(1024)).put("duration", media.optDouble("duration", 0.0).takeIf { it.isFinite() && it >= 0 } ?: 0.0)
        .put("formats", JSONArray(list))

    fun resolve(page: WebVideoPage, media: JSONObject): JSONObject? {
        if (media.optBoolean("protected")) return null
        val candidates = WebBrowserNetworkMedia.candidates(media)
        val scopedCookies = LinkedHashMap<String, JSONObject>()
        for (i in 0 until candidates.length()) {
            val c = candidates.getJSONObject(i); val uri = URI(c.getString("url"))
            resources[uri] = Resource(uri, c.getString("kind"), headers(c.getJSONObject("headers")))
            val cookies = c.optJSONArray("cookies") ?: continue
            for (j in 0 until cookies.length()) {
                val cookie = cookies.optJSONObject(j) ?: continue
                // Verify the declared scope matches the request that supplied this cookie.
                if (runCatching { WebVideoBrowserCapture.cookieHeader(JSONArray().put(cookie), uri) }.getOrNull() == null) continue
                val key = "${cookie.optString("domain")}\n${cookie.optString("path")}\n${cookie.optString("name")}"
                scopedCookies[key] = cookie
                while (scopedCookies.size > 256) scopedCookies.remove(scopedCookies.keys.first())
            }
        }
        scopedCookies.values.forEach(cookieJar::put)
        if (cookieJar.toString().length > 65536) return null
        var direct = WebBrowserNetworkMedia.address(media.optString("source"))
        if (direct != null) for (i in 0 until candidates.length()) {
            val c = candidates.getJSONObject(i)
            if (c.optString("original_url") == direct.toString()) { direct = URI(c.getString("url")); break }
        }
        if (direct != null && !resources.containsKey(direct)) {
            val frame = WebBrowserNetworkMedia.address(media.optString("frame").substringBefore('#')) ?: return null
            val kind = when { direct.path.endsWith(".m3u8", true) -> "hls"; direct.path.endsWith(".mpd", true) -> "dash"; else -> "file" }
            val agent = media.optString("agent").takeIf { it.length in 1..2048 && it.none { c -> c < ' ' || c == '\u007f' } }
            val fallback = mapOf("referer" to frame.toString()) + (agent?.let { mapOf("user-agent" to it) } ?: emptyMap())
            resources[direct] = Resource(direct, kind, WebVideoRequestHeaders(emptyMap(), cookieJar).forUrl(direct, fallback))
        }
        // Master+variant requests form one graph. Do not pick a leaf playlist which would
        // lose its external audio, or guess between unrelated players/ads in the same frame.
        val manifests = resources.values.filter { it.kind in setOf("hls", "dash") && (direct == null || direct == it.uri) }
        if (manifests.isNotEmpty()) return runCatching { manifestInfo(page, media, manifests) }.getOrNull()
        val files = resources.values.filter { it.kind == "file" && (direct == null || direct == it.uri) }
        if (files.isEmpty() || files.size > 8) return null
        val probes = files.mapNotNull { resource -> runCatching { probe(resource, media) }.getOrNull() }
        val muxed = probes.filter { it.info.video != "none" && it.info.audio != "none" }
        if (muxed.size == 1 && (direct != null || files.size == 1)) return info(media, listOf(muxed.single().format))
        // Only pair whole representations with a site-supplied common content identity.
        // Same host/time proximity alone is insufficient (ads and preload commonly overlap).
        val groups = probes.groupBy { group(it.resource.uri) }
        if (groups.size != 1 || groups.keys.single() == null) return null
        val videos = probes.filter { it.info.video != "none" && it.info.audio == "none" }
        val audios = probes.filter { it.info.video == "none" && it.info.audio != "none" }
        if (videos.isEmpty() || audios.isEmpty()) return null
        val expected = media.optDouble("duration", 0.0)
        if (expected <= 0 || probes.any { !durationMatches(it.info.duration, expected) }) return null
        return info(media, probes.map { it.format })
    }

    private fun durationMatches(actual: Double, expected: Double) = actual > 0 && kotlin.math.abs(actual - expected) <= maxOf(2.0, expected * .01)
    private fun probe(source: Resource, media: JSONObject, manifestDuration: Double = 0.0): Probed {
        val uri = wholeFile(source.uri) ?: error("Segmented request")
        val resource = Resource(uri, "file", source.headers)
        val (_, bytes) = read(resource, true)
        val container = WebVideoContainer.parse(bytes) ?: error("Not a complete media header")
        val duration = container.duration.takeIf { it > 0 } ?: manifestDuration.takeIf { it > 0 }
            ?: query(uri)["dur"]?.toDoubleOrNull()?.takeIf { group(uri)?.startsWith("youtube:") == true && it.isFinite() && it > 0 }
            ?: 0.0
        // A standalone init segment typically has zero duration. An MPD/known file endpoint
        // may provide it, but arbitrary chunks must never inherit the DOM duration.
        require(duration > 0)
        val expected = media.optDouble("duration", 0.0)
        require(expected <= 0 || durationMatches(duration, expected))
        val checked = WebVideoContainer.Info(container.video, container.audio, container.width, container.height, duration)
        projections[uri] = SphericalVideoMetadata.parse(bytes)
        val f = format(resource, checked.video, checked.audio, checked.width, checked.height)
            .put("web_layout", media.optString("layout").take(64))
        projections[uri]?.let { f.put("format_note", it.optString("kind")) }
        return Probed(resource, checked, f)
    }

    private fun text(resource: Resource): Pair<Resource, String> {
        val (uri, bytes) = read(resource, false)
        require(bytes.size <= 2 * 1024 * 1024)
        return scoped(resource, uri).let { Resource(it.uri, resource.kind, it.headers) } to bytes.toString(Charsets.UTF_8).removePrefix("\uFEFF")
    }
    private fun attrs(value: String): Map<String, String> = Regex("([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)").findAll(value.substringAfter(':')).associate {
        it.groupValues[1] to it.groupValues[2].removeSurrounding("\"")
    }
    private fun target(base: Resource, value: String, kind: String = "hls"): Resource {
        val uri = WebBrowserNetworkMedia.address(base.uri.resolve(value).toString()) ?: error("Invalid manifest address")
        val scoped = scoped(base, uri)
        return Resource(uri, kind, scoped.headers)
    }
    private fun validateHls(resource: Resource) {
        val (_, body) = text(resource); val lines = body.lineSequence().map(String::trim).toList()
        require(lines.firstOrNull() == "#EXTM3U" && lines.contains("#EXT-X-ENDLIST"))
        require(lines.any { it.startsWith("#EXTINF:") })
        require(lines.none { it.startsWith("#EXT-X-DEFINE:") || it.startsWith("#EXT-X-STREAM-INF:") })
        for (line in lines.filter { it.startsWith("#EXT-X-KEY:") || it.startsWith("#EXT-X-SESSION-KEY:") }) {
            val a = attrs(line)
            require(a["METHOD"] in setOf("NONE", "AES-128") && a["KEYFORMAT"] in setOf(null, "identity"))
        }
    }
    private fun manifestInfo(page: WebVideoPage, media: JSONObject, manifests: List<Resource>): JSONObject {
        require(manifests.size <= 6)
        if (manifests.any { it.kind == "dash" }) { require(manifests.size == 1); return dash(media, manifests.single()) }
        val loaded = manifests.associateWith { text(it) }
        val referenced = HashSet<URI>()
        loaded.values.forEach { (base, body) -> body.lineSequence().map(String::trim).forEach { line ->
            if (line.isNotEmpty() && !line.startsWith('#')) referenced.add(base.uri.resolve(line))
            attrs(line)["URI"]?.let { referenced.add(base.uri.resolve(it)) }
        } }
        val roots = manifests.filter { it.uri !in referenced }
        require(roots.size == 1)
        val (base, body) = loaded.getValue(roots.single())
        val lines = body.lineSequence().map(String::trim).toList()
        require(lines.firstOrNull() == "#EXTM3U")
        if (lines.none { it.startsWith("#EXT-X-STREAM-INF:") }) {
            validateHls(base)
            val first = lines.firstOrNull { it.isNotEmpty() && !it.startsWith('#') } ?: error("Empty playlist")
            val init = lines.firstOrNull { it.startsWith("#EXT-X-MAP:") }?.let { attrs(it)["URI"] }
            val sample = read(target(base, init ?: first, "file"), true).second
            val container = WebVideoContainer.parse(sample) ?: WebVideoContainer.transportStream(sample) ?: error("Unknown HLS tracks")
            require(container.video != "none" && container.audio != "none") // A leaf may be just one half of a master.
            return info(media, listOf(format(base, container.video, container.audio, media.optInt("width"), media.optInt("height"))))
        }
        require(lines.none { it.startsWith("#EXT-X-SESSION-KEY:") || it.startsWith("#EXT-X-DEFINE:") })
        val audios = lines.filter { it.startsWith("#EXT-X-MEDIA:") }.map(::attrs).filter { it["TYPE"] == "AUDIO" }
        val choices = ArrayList<Pair<JSONObject, List<Resource>>>()
        for (i in lines.indices) if (lines[i].startsWith("#EXT-X-STREAM-INF:")) {
            val a = attrs(lines[i]); val next = lines.getOrNull(i + 1) ?: continue
            if (next.isEmpty() || next.startsWith('#')) continue
            val video = target(base, next)
            val resolution = a["RESOLUTION"].orEmpty().split('x')
            val codecs = a["CODECS"].orEmpty().split(',')
            val vc = codecs.firstOrNull { Regex("^(avc[13]|hvc1|hev1|vp09|av01).*", RegexOption.IGNORE_CASE).matches(it) } ?: "unknown"
            val ac = codecs.firstOrNull { it.startsWith("mp4a") || it == "opus" || it.startsWith("ac-3") || it.startsWith("ec-3") } ?: "unknown"
            val audioGroup = a["AUDIO"]?.let { group -> audios.filter { it["GROUP-ID"] == group }.sortedByDescending { it["DEFAULT"] == "YES" }.firstOrNull() }
            if (a.containsKey("AUDIO") && audioGroup == null) continue
            val audio = audioGroup?.get("URI")?.let { target(base, it) }
            val vf = format(video, vc, if (audio != null) "none" else ac, resolution.getOrNull(0)?.toIntOrNull() ?: 0,
                resolution.getOrNull(1)?.toIntOrNull() ?: 0).put("fps", a["FRAME-RATE"]?.toDoubleOrNull() ?: 0.0)
                .put("tbr", (a["BANDWIDTH"]?.toDoubleOrNull() ?: 0.0) / 1000).put("web_layout", media.optString("layout").take(64))
            if (a["VIDEO-RANGE"] !in setOf(null, "SDR")) continue
            val candidate = info(media, listOfNotNull(vf, audio?.let { format(it, "none", ac) }))
            if (runCatching { WebVideoFormats.select(page, candidate, accepts) }.isSuccess) choices.add(candidate to listOfNotNull(video, audio))
        }
        val observed = choices.filter { it.second.first().uri in resources }
        val currentSize = choices.filter {
            val v = it.first.getJSONArray("formats").getJSONObject(0)
            v.optInt("width") == media.optInt("width") && v.optInt("height") == media.optInt("height")
        }
        val pool = observed.ifEmpty { currentSize.ifEmpty { choices } }
        val chosen = pool.maxWithOrNull(compareBy<Pair<JSONObject, List<Resource>>> {
            val v = it.first.getJSONArray("formats").getJSONObject(0); v.optLong("width") * v.optLong("height")
        }.thenBy { it.first.getJSONArray("formats").getJSONObject(0).optDouble("tbr") }) ?: error("No compatible HLS variant")
        chosen.second.forEach(::validateHls)
        return chosen.first
    }

    /** Static single-period DASH with complete BaseURL/SegmentBase representations. Segment
     * templates/lists remain discovered but require the existing extractor/website path. */
    private fun dash(media: JSONObject, resource: Resource): JSONObject {
        val (base, xml) = text(resource)
        require(!Regex("<!DOCTYPE|<!ENTITY", RegexOption.IGNORE_CASE).containsMatchIn(xml))
        val factory = javax.xml.parsers.DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true; isExpandEntityReferences = false
        }
        val document = factory.newDocumentBuilder().apply { setEntityResolver { _, _ -> org.xml.sax.InputSource(java.io.StringReader("")) } }
            .parse(org.xml.sax.InputSource(java.io.StringReader(xml)))
        val root = document.documentElement
        require(root.localName == "MPD" && root.getAttribute("type") != "dynamic")
        val elements = root.getElementsByTagName("*")
        for (i in 0 until elements.length) {
            val e = elements.item(i) as Element
            require(e.localName !in setOf("ContentProtection", "SegmentTemplate", "SegmentList", "Location", "UTCTiming"))
            require(!e.hasAttributeNS("http://www.w3.org/1999/xlink", "href"))
        }
        fun children(e: Element, name: String) = (0 until e.childNodes.length).map { e.childNodes.item(it) }.filterIsInstance<Element>().filter { it.localName == name }
        fun baseAt(e: Element, from: Resource): Resource {
            val urls = children(e, "BaseURL"); require(urls.size <= 1)
            return urls.singleOrNull()?.textContent?.trim()?.let { target(from, it, "file") } ?: from
        }
        val period = children(root, "Period").single()
        require(period.getAttribute("start") in setOf("", "PT0S", "PT0.0S"))
        val durationText = root.getAttribute("mediaPresentationDuration").ifEmpty { period.getAttribute("duration") }
        val duration = java.time.Duration.parse(durationText).toMillis() / 1000.0
        require(duration > 0)
        val pbase = baseAt(period, baseAt(root, base))
        val formats = ArrayList<JSONObject>()
        for (adapt in children(period, "AdaptationSet")) {
            val abase = baseAt(adapt, pbase)
            for (representation in children(adapt, "Representation")) {
                val target = baseAt(representation, abase)
                require(target.uri != base.uri && !target.uri.path.endsWith('/'))
                require(formats.size < 16)
                val probe = probe(target, media, duration)
                formats.add(probe.format)
            }
        }
        require(formats.isNotEmpty())
        return info(media, formats)
    }
}
