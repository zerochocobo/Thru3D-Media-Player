package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** Plex video libraries use the same ray browser and authenticated Range proxy as other servers. */
internal class PlexClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    private fun get(path: String, args: Map<String, Any> = emptyMap()): JSONObject = container(http.bytes(
        account.endpoint(path + if (args.isEmpty()) "" else "?" + mediaQuery(args)), 4 * 1024 * 1024))
    override fun capabilities() = MediaLibraryPresentation.capabilities(
        facets = listOf("genres", "tags", "performers", "studios"), navigation = listOf("genres", "tags", "folders"),
        filters = listOf("watched", "min_rating"), tree = true)
        .put("home_layout", "libraries").put("artwork", true)
    override fun probe(): String {
        val info = get("identity")
        mediaRequire(info.optString("machineIdentifier").isNotBlank(), "Wrong server type")
        if (account.userId.isNotBlank()) mediaRequire(info.optString("machineIdentifier") == account.userId, "Wrong server type")
        sections() // /identity is public: a successful identity request alone does not prove authorization.
        return info.optString("version")
    }
    private fun sections() = (get("library/sections").optJSONArray("Directory") ?: JSONArray()).objects()
        .filter { it.optString("type") in setOf("movie", "show") }
    private fun section(request: JSONObject): JSONObject? {
        val all = sections(); val selected = request.optString("library_id")
        if (selected.isBlank()) return all.firstOrNull()
        return all.firstOrNull { it.optString("key") == selected } ?: throw MediaServerFailure("Video unavailable")
    }
    private fun library(data: JSONObject) = JSONObject().put("id", numeric(data.getString("key")))
        .put("title", data.optString("title").take(256)).put("kind", "container").put("container", true)
        .put("collection_type", if (data.optString("type") == "show") "tvshows" else "movies")
        .put("has_cover", true).put("cover_image", imageNode("section-${numeric(data.getString("key"))}", "Thumb", data.optString("updatedAt")))
    override fun home(request: JSONObject): JSONObject {
        val all = sections()
        val home = JSONObject().put("capabilities", capabilities()).put("total", all.size)
            .put("recent", JSONArray()).put("resume", JSONArray()).put("recent_opened", JSONArray())
            .put("libraries", JSONArray(all.map(::library))).put("library_id", "")
        try {
            val watched = nodes(get("library/all", mapOf("type" to "1,4", "sort" to "lastViewedAt:desc",
                "X-Plex-Container-Start" to 0, "X-Plex-Container-Size" to 16)))
                .filter { it.optString("type") in VIDEO && (it.optLong("viewOffset") > 0 || it.optInt("viewCount") > 0 || it.optLong("lastViewedAt") > 0) }
                .take(16).map(::summary)
            home.put("recent_opened", JSONArray(watched)).put("resume", JSONArray(watched.filter {
                it.optLong("position_ms") > 0 && (it.optLong("duration_ms") <= 0 || it.optLong("position_ms") < it.optLong("duration_ms") - 1000)
            }))
        } catch (error: Exception) {
            if (error is MediaServerFailure && error.code in setOf("Request cancelled", "Server authentication required")) throw error
            home.put("recent_error", (error as? MediaServerFailure)?.code ?: "Invalid server response")
        }
        return home
    }
    override fun browse(request: JSONObject): JSONObject {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val global = request.optBoolean("all_libraries") || request.optString("library_id").isBlank() && request.optString("mode").isBlank()
        val selected = if (global) null else section(request)
        if (!global && selected == null) return JSONObject().put("entries", JSONArray()).put("total", 0).put("page", page)
        val folder = request.optString("mode") == "folders" || request.optString("mode") == "library" && selected?.optString("type") == "show"
        val parent = request.optString("parent_id")
        val args = linkedMapOf<String, Any>("X-Plex-Container-Start" to (page - 1) * 48, "X-Plex-Container-Size" to 48)
        val path = if (global) { args["type"] = "1,4"; "library/all" }
        else if (folder && parent.isNotBlank()) "library/metadata/${numeric(parent)}/children" else {
            args["type"] = if (selected!!.optString("type") == "show") { if (folder) 2 else 4 } else 1
            "library/sections/${numeric(selected.getString("key"))}/all"
        }
        val sort = mapOf("created_at" to "addedAt", "title" to "titleSort", "date" to "originallyAvailableAt",
            "duration" to "duration", "rating100" to "rating")[request.optString("sort", "created_at")]
            ?: throw MediaServerFailure("Server query unsupported")
        args["sort"] = sort + if (request.optString("direction") == "ASC") ":asc" else ":desc"
        if (request.optString("q").isNotBlank()) args["title"] = request.optString("q").take(200)
        if (request.has("watched")) args["unwatched"] = if (request.getBoolean("watched")) 0 else 1
        if (request.optInt("min_rating") > 0) args["rating>="] = request.getInt("min_rating") / 10.0
        for ((local, remote) in FACETS) {
            val values = request.optJSONArray(local) ?: continue
            mediaRequire(values.length() <= 100, "Server query unsupported")
            if (values.length() > 0) args[remote] = values.objectsOrStrings().distinct().joinToString(",") { facetId(it) }
        }
        mediaRequire(request.optString("unclassified").isBlank() && FACETS.keys.none { request.optJSONArray("exclude_$it")?.length()?.let { n -> n > 0 } == true }, "Server query unsupported")
        val result = get(path, args)
        val entries = nodes(result).filter { it.optString("type") in VIDEO || (folder && it.optString("type") in CONTAINERS) }.map(::summary)
        return JSONObject().put("entries", JSONArray(entries)).put("total", result.optInt("totalSize", result.optInt("size", entries.size))).put("page", page)
    }
    override fun candidates(request: JSONObject): JSONObject {
        val selected = section(request)
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val remote = FACETS[request.optString("kind")] ?: throw MediaServerFailure("Server query unsupported")
        val entries = if (selected == null) emptyList() else (get("library/sections/${numeric(selected.getString("key"))}/$remote",
            mapOf("type" to if (selected.optString("type") == "show") 4 else 1)).optJSONArray("Directory") ?: JSONArray()).objects()
            .filter { it.optString("title").contains(request.optString("q").take(200), true) }.map {
                JSONObject().put("id", facetId(it.getString("key"))).put("name", it.optString("title").take(256)).put("count", -1)
            }
        return JSONObject().put("entries", JSONArray(entries.drop((page - 1) * 48).take(48))).put("total", entries.size).put("page", page)
    }
    private fun item(id: String): JSONObject = nodes(get("library/metadata/${numeric(id)}", mapOf("includeChapters" to 1)))
        .firstOrNull { it.optString("ratingKey") == id } ?: throw MediaServerFailure("Video unavailable")
    private fun facets(data: JSONObject, remote: String): JSONArray = JSONArray((data.optJSONArray(remote) ?: JSONArray()).objects()
        .take(100).mapNotNull { tag ->
            val id = tag.optString("id"); val name = tag.optString("tag")
            if (!id.matches(Regex("[0-9]{1,20}")) || name.isBlank()) null else JSONObject().put("id", id).put("name", name.take(256))
        })
    private fun summary(data: JSONObject): JSONObject {
        val id = numeric(data.getString("ratingKey")); val type = data.optString("type")
        val container = type in CONTAINERS
        val sources = data.optJSONArray("Media") ?: JSONArray()
        val source = sources.objects().firstOrNull { originalPart(it) != null } ?: JSONObject()
        val parts = source.optJSONArray("Part") ?: JSONArray()
        val part = if (parts.length() == 1) parts.getJSONObject(0) else JSONObject()
        val title = if (type == "episode") listOf(data.optString("grandparentTitle"), data.optString("title")).filter { it.isNotBlank() }.joinToString(" · ") else data.optString("title", "Video")
        val result = JSONObject().put("id", id).put("kind", if (container) "container" else "video").put("container", container)
            .put("title", title.take(256)).put("duration_ms", data.optLong("duration").coerceAtLeast(0))
            .put("basename", part.optString("file").substringAfterLast('/').substringAfterLast('\\'))
            .put("width", source.optInt("width")).put("height", source.optInt("height"))
            .put("description", data.optString("summary").take(2000)).put("rating", (data.optDouble("rating", 0.0) * 10).toInt())
            .put("year", data.optInt("year")).put("type", type).put("child_count", data.optInt("childCount", data.optInt("leafCount", -1)))
            .put("watched", data.optInt("viewCount") > 0).put("position_ms", data.optLong("viewOffset").coerceAtLeast(0))
            .put("genres", facets(data, "Genre")).put("tags", facets(data, "Label")).put("performers", facets(data, "Role"))
            .put("studios", JSONArray().apply { if (data.optString("studio").isNotBlank()) put(JSONObject()
                .put("id", data.optString("studio")).put("name", data.optString("studio").take(256))) })
            .put("studio", JSONObject().put("name", data.optString("studio")))
            .apply { if (!container) put("uri", MediaLibraryUri.scene(account.id, id)) }
        val variants = JSONObject()
        val poster = data.optString("thumb").ifBlank { data.optString("parentThumb").ifBlank { data.optString("grandparentThumb") } }
        val art = data.optString("art").ifBlank { data.optString("parentArt").ifBlank { data.optString("grandparentArt") } }
        if (poster.isNotBlank()) variants.put("Primary", imageNode(id, "Primary", poster))
        if (art.isNotBlank()) variants.put("Backdrop", imageNode(id, "Backdrop", art))
        val thumb = if (type == "episode") data.optString("thumb").ifBlank { art } else art
        if (thumb.isNotBlank()) variants.put("Thumb", imageNode(id, "Thumb", thumb))
        result.put("image_variants", variants).put("has_cover", variants.length() > 0)
        listOf("Primary", "Thumb", "Backdrop").firstOrNull { variants.has(it) }?.let { result.put("cover_image", variants.getJSONObject(it)) }
        return result
    }
    override fun detail(id: String): JSONObject {
        val data = item(id)
        val result = summary(data).put("markers", JSONArray((data.optJSONArray("Chapter") ?: JSONArray()).objects().take(500).map {
            JSONObject().put("title", it.optString("title").take(150)).put("position_ms", it.optLong("startTimeOffset").coerceAtLeast(0))
        }))
        val variants = result.getJSONObject("image_variants")
        result.put("images", JSONArray(listOf("Primary", "Backdrop").mapNotNull { variants.optJSONObject(it) }))
            .put("backdrops", JSONArray(listOfNotNull(variants.optJSONObject("Backdrop"))))
        val actors = (data.optJSONArray("Role") ?: JSONArray()).objects().take(100).mapNotNull { actor ->
            val roleId = actor.optString("id"); val name = actor.optString("tag")
            if (!roleId.matches(Regex("[0-9]{1,20}")) || name.isBlank()) null else JSONObject().put("id", roleId)
                .put("name", name.take(256)).put("role", actor.optString("role").take(256)).put("has_cover", actor.optString("thumb").isNotBlank())
                .apply { if (actor.optString("thumb").isNotBlank()) put("cover_image", imageNode("actor-${numeric(id)}-$roleId", "Primary", actor.getString("thumb"))) }
        }
        result.put("actors", JSONArray(actors))
        val media = data.optJSONArray("Media") ?: JSONArray()
        mediaRequire(media.length() <= 128, "Server response too large")
        val versions = media.objects().filter { originalPart(it) != null && it.optString("id").matches(Regex("[0-9]{1,20}")) }
        if (versions.size > 1) result.put("versions", JSONArray(versions.mapIndexed { index, version ->
            val part = originalPart(version)!!; val source = version.optString("id")
            val name = listOf(version.optString("videoResolution").ifBlank { "${version.optInt("width")}×${version.optInt("height")}" },
                version.optString("videoCodec").uppercase(), version.optString("container").uppercase()).filter(String::isNotBlank).joinToString(" · ")
            JSONObject().put("id", numeric(id)).put("source_id", source).put("version_name", name).put("default_version", index == 0)
                .put("title", result.getString("title") + " · " + name).put("uri", MediaLibraryUri.scene(account.id, id, source))
                .put("basename", part.optString("file").substringAfterLast('/').substringAfterLast('\\'))
                .put("width", version.optInt("width")).put("height", version.optInt("height"))
                .put("duration_ms", part.optLong("duration", data.optLong("duration"))).put("position_ms", 0)
                // Item-level chapters need not match another edition's cut.
                .put("markers", JSONArray())
        }))
        return result
    }
    private fun imageNode(id: String, type: String, key: String) = JSONObject().put("id", id).put("image_type", type).put("image_index", 0)
        .put("image_tag", java.security.MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).take(16).joinToString("") { "%02x".format(it) })

    override fun image(id: String, type: String, index: Int, tag: String, width: Int): URI {
        mediaRequire(type in setOf("Primary", "Thumb", "Backdrop") && index == 0 && tag.length <= 256 && width in 64..1024, "Cover unavailable")
        val section = Regex("section-([0-9]{1,20})").matchEntire(id)
        val actor = Regex("actor-([0-9]{1,20})-([0-9]{1,20})").matchEntire(id)
        val key = if (section != null) {
            val library = sections().firstOrNull { it.getString("key") == section.groupValues[1] } ?: throw MediaServerFailure("Cover unavailable")
            library.optString("art").ifBlank { library.optString("thumb").ifBlank {
                val first = nodes(get("library/sections/${numeric(section.groupValues[1])}/all", mapOf("type" to if (library.optString("type") == "show") 2 else 1,
                    "sort" to "addedAt:desc", "X-Plex-Container-Start" to 0, "X-Plex-Container-Size" to 1))).firstOrNull()
                first?.optString("art").orEmpty().ifBlank { first?.optString("thumb").orEmpty() }
            } }
        } else if (actor != null) {
            val roles = item(actor.groupValues[1]).optJSONArray("Role") ?: JSONArray()
            roles.objects().firstOrNull { it.optString("id") == actor.groupValues[2] }?.optString("thumb").orEmpty()
        } else {
            val data = item(numeric(id))
            if (type == "Primary") data.optString("thumb").ifBlank { data.optString("parentThumb").ifBlank { data.optString("grandparentThumb") } }
            else if (type == "Thumb" && data.optString("type") == "episode") data.optString("thumb").ifBlank { data.optString("art") }
            else data.optString("art").ifBlank { data.optString("parentArt").ifBlank { data.optString("grandparentArt") } }
        }
        mediaRequire(key.length in 1..8192, "Cover unavailable")
        val asset = runCatching { URI(key) }.getOrNull() ?: throw MediaServerFailure("Cover unavailable")
        mediaRequire(asset.rawUserInfo == null && asset.fragment == null && if (asset.isAbsolute)
            asset.scheme in setOf("http", "https") && !asset.host.isNullOrBlank() else
            key.startsWith('/') && !key.startsWith("//") && asset.path.split('/').none { it in setOf(".", "..") }, "Cover unavailable")
        // Plex fetches its own declared asset. The account token stays on the local server.
        return account.endpoint("photo/:/transcode?" + mediaQuery(mapOf("url" to key, "width" to width, "height" to width, "minSize" to 0, "upscale" to 0)))
    }
    override fun cover(id: String): URI = endpoint(item(id).optString("thumb"), "/library/metadata/")
    private fun endpoint(key: String, prefix: String): URI {
        mediaRequire(key.startsWith(prefix), "Media address differs from server")
        val uri = account.endpoint(key)
        mediaRequire(account.accepts(uri) && uri.rawQuery == null && !uri.path.contains("/../"), "Media address differs from server")
        return uri
    }
    private fun originalPart(media: JSONObject): JSONObject? {
        val parts = media.optJSONArray("Part") ?: return null
        return parts.optJSONObject(0)?.takeIf { parts.length() == 1 && it.optBoolean("exists", true) && it.optBoolean("accessible", true) }
    }
    override fun stream(id: String): MediaStreamLink = stream(id, "")
    override fun stream(id: String, sourceId: String): MediaStreamLink {
        val data = item(id)
        mediaRequire(data.optString("type") in VIDEO, "Video unavailable")
        if (sourceId.isNotEmpty()) numeric(sourceId)
        val parts = (data.optJSONArray("Media") ?: JSONArray()).objects().filter { sourceId.isEmpty() || it.optString("id") == sourceId }.mapNotNull(::originalPart)
        val part = parts.firstOrNull() ?: throw MediaServerFailure("Original stream unavailable")
        val url = endpoint(part.getString("key"), "/library/parts/")
        val subtitles = (part.optJSONArray("Stream") ?: JSONArray()).objects().filter {
            it.optInt("streamType") == 3 && it.optString("key").isNotBlank() && it.optString("codec") in setOf("srt", "ass", "ssa", "vtt")
        }.take(8).map { caption -> MediaSubtitleLink(endpoint(caption.getString("key"), "/library/streams/"),
            caption.optString("displayTitle").ifBlank { caption.optString("language", "Subtitles") }.take(150), caption.optString("codec"),
            caption.optString("languageCode").ifBlank { caption.optString("language") }.take(80)) }
        return MediaStreamLink(url, "${numeric(part.optString("id"))}:${part.optLong("size")}:${data.optLong("updatedAt")}", subtitles,
            basename = part.optString("file").substringAfterLast('/').substringAfterLast('\\'))
    }
    companion object {
        private val VIDEO = setOf("movie", "episode")
        private val CONTAINERS = setOf("show", "season")
        private val FACETS = mapOf("genres" to "genre", "tags" to "label", "performers" to "actor", "studios" to "studio")
        private fun facetId(value: String): String {
            mediaRequire(value.isNotBlank() && value.length <= 256 && value.none { it == ',' || it.isISOControl() }, "Server query unsupported")
            return value
        }
        internal fun numeric(id: String): String { mediaRequire(id.matches(Regex("[0-9]{1,20}")), "Invalid media identity"); return id }
        internal fun container(bytes: ByteArray): JSONObject = try { JSONObject(String(bytes, Charsets.UTF_8)).getJSONObject("MediaContainer") }
            catch (_: Exception) { throw MediaServerFailure("Invalid server response") }
        private fun nodes(container: JSONObject) = (container.optJSONArray("Metadata") ?: JSONArray()).objects()
        private fun JSONArray.objectsOrStrings() = (0 until length()).map { getString(it) }
    }
}
