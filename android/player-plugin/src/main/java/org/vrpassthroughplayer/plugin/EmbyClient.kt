package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder
import java.util.UUID

internal fun mediaId(id: String): String {
    mediaRequire(id.matches(Regex("[A-Za-z0-9-]{1,64}")), "Invalid media identity")
    return id
}
internal fun mediaQuery(values: Map<String, Any>): String = values.entries.joinToString("&") {
    URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value.toString(), "UTF-8")
}
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

/** User-scoped Emby/Jellyfin APIs mapped to the common VR browsing contract. */
internal class EmbyClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    private fun user() = mediaId(account.userId)
    private fun get(path: String, args: Map<String, Any> = emptyMap(), body: JSONObject? = null,
        method: String = if (body == null) "GET" else "POST"): JSONObject {
        val raw = String(http.bytes(account.endpoint(path + if (args.isEmpty()) "" else "?" + mediaQuery(args)),
            4 * 1024 * 1024, body, method = method), Charsets.UTF_8)
        return if (raw.isBlank()) JSONObject() else JSONObject(raw)
    }
    override fun capabilities(): JSONObject = MediaLibraryPresentation.capabilities(
        facets = listOf("genres", "tags", "performers", "studios"), navigation = listOf("genres", "tags", "folders"),
        filters = listOf("watched", "min_rating"), favoriteScope = "server", tree = true,
        excludes = if (account.provider == "emby") listOf("tags") else emptyList(), unclassified = listOf("genres", "tags"))
        .put("home_layout", "libraries").put("artwork", true)
    fun login(username: String, password: String): MediaServerAccount {
        val auth = get("Users/AuthenticateByName", body = JSONObject().put("Username", username).put("Pw", password))
        val token = auth.getString("AccessToken")
        mediaRequire(token.isNotBlank(), "Server authentication required")
        return account.copy(key = token, userId = mediaId(auth.getJSONObject("User").getString("Id")), username = username)
    }
    override fun probe(): String {
        val info = get("System/Info/Public")
        val product = info.optString("ProductName").lowercase()
        mediaRequire(!(account.provider == "emby" && product.contains("jellyfin")) &&
            !(account.provider == "jellyfin" && product.contains("emby")), "Wrong server type")
        get("Users/${user()}/Items", mapOf("Limit" to 1, "Recursive" to true, "IncludeItemTypes" to "Movie,Episode,Video"))
        return info.optString("Version")
    }
    override fun home(request: JSONObject): JSONObject {
        val libraries = get("Users/${user()}/Views").getJSONArray("Items").objects()
            .filter { it.optString("CollectionType") !in setOf("music", "books", "games", "livetv", "channels", "photos", "audiobooks") }
        val home = JSONObject().put("capabilities", capabilities()).put("total", libraries.size)
            .put("recent", JSONArray()).put("resume", JSONArray()).put("recent_opened", JSONArray())
            .put("libraries", JSONArray(libraries.map(::summary))).put("library_id", "")
        try {
            val args = linkedMapOf<String, Any>("Recursive" to true, "IncludeItemTypes" to "Movie,Episode,Video",
                "Limit" to 16, "StartIndex" to 0, "SortBy" to "DatePlayed", "SortOrder" to "Descending",
                "Fields" to "MediaSources,MediaStreams,PrimaryImageAspectRatio", "EnableUserData" to true, "EnableImages" to true)
            val watched = get("Users/${user()}/Items", args).getJSONArray("Items").objects().filter { item ->
                val state = item.optJSONObject("UserData") ?: JSONObject()
                state.optLong("PlaybackPositionTicks") > 0 || state.optInt("PlayCount") > 0 || state.optBoolean("Played") ||
                    state.optString("LastPlayedDate").isNotBlank()
            }.map(::summary).filter { !it.optBoolean("container") }
            home.put("recent_opened", JSONArray(watched))
                .put("resume", JSONArray(watched.filter { it.optLong("position_ms") > 0 &&
                    (it.optLong("duration_ms") <= 0 || it.optLong("position_ms") < it.optLong("duration_ms") - 1000) }))
        } catch (error: Exception) {
            if (error is MediaServerFailure && error.code in setOf("Request cancelled", "Server authentication required")) throw error
            // A failed optional history query must not hide the libraries or local history.
            home.put("recent_error", (error as? MediaServerFailure)?.code ?: "Invalid server response")
        }
        return home
    }
    private fun browseArgs(request: JSONObject): LinkedHashMap<String, Any> {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val folders = request.optString("mode") == "folders"
        val libraryTypes = when (request.optString("collection_type")) {
            "tvshows" -> "Series"
            "movies" -> "Movie,Video,BoxSet"
            else -> "Movie,Series,Video,BoxSet"
        }
        val args = linkedMapOf<String, Any>("Recursive" to !folders, "IncludeItemTypes" to if (folders)
            "CollectionFolder,Folder,Series,Season,Movie,Episode,Video,BoxSet,Playlist"
            else if (request.optString("mode") == "library") libraryTypes else "Movie,Episode,Video",
            "StartIndex" to (page - 1) * 48, "Limit" to 48, "EnableTotalRecordCount" to true,
            "Fields" to "MediaSources,MediaStreams,Overview,People,Genres,Studios,Chapters,Tags,Path,ParentId,ChildCount,PrimaryImageAspectRatio",
            "SortBy" to (mapOf("title" to "SortName", "date" to "PremiereDate", "duration" to "Runtime", "rating100" to "CommunityRating")[request.optString("sort")] ?: "DateCreated"),
            "SortOrder" to if (request.optString("direction") == "ASC") "Ascending" else "Descending")
        val parent = if (request.optBoolean("all_libraries")) "" else request.optString("parent_id").ifBlank { request.optString("library_id") }
        if (parent.isNotBlank()) args["ParentId"] = mediaId(parent)
        val q = request.optString("q").take(200)
        if (q.isNotBlank()) args["SearchTerm"] = q
        if (request.has("watched")) args["IsPlayed"] = request.getBoolean("watched")
        if (request.optBoolean("favorites")) args["Filters"] = "IsFavorite"
        if (request.optInt("min_rating") > 0) args["MinCommunityRating"] = request.getInt("min_rating") / 10.0
        for ((local, remote) in listOf("genres" to "Genres", "tags" to "Tags", "exclude_tags" to "ExcludeTags",
            "performers" to "PersonIds", "studios" to "StudioIds")) {
            val values = request.optJSONArray(local) ?: continue
            mediaRequire(values.length() <= 100)
            if (values.length() > 0) {
                if (local == "exclude_tags") mediaRequire(account.provider == "emby", "Server query unsupported")
                val terms = (0 until values.length()).map { values.getString(it) }.distinct()
                mediaRequire(terms.all { it.isNotBlank() && it.length <= 256 && !it.contains('|') }, "Server query unsupported")
                args[remote] = terms.joinToString(if (local == "performers") "," else "|")
            }
        }
        return args
    }
    override fun browse(request: JSONObject): JSONObject {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val args = browseArgs(request)
        val missing = request.optString("unclassified")
        if (missing.isNotBlank()) {
            mediaRequire(missing in setOf("genres", "tags"), "Server query unsupported")
            return unclassified(args, missing, page)
        }
        val result = get("Users/${user()}/Items", args)
        return JSONObject().put("entries", JSONArray(result.getJSONArray("Items").objects().map(::summary)))
            .put("total", result.getInt("TotalRecordCount")).put("page", page)
    }
    override fun folderArtwork(id: String): JSONObject {
        val result = get("Users/${user()}/Items", mapOf("ParentId" to mediaId(id), "Recursive" to false,
            "Limit" to 2, "EnableTotalRecordCount" to true, "EnableImages" to true))
        val items = result.getJSONArray("Items").objects()
        val images = JSONObject()
        // Only a unique direct movie may lend its artwork; never scan descendants or pick a
        // random member of a collection. The folder keeps its own identity and navigation.
        if (result.optInt("TotalRecordCount", items.size) == 1 && items.size == 1 &&
            !items[0].optBoolean("IsFolder") && items[0].optString("Type") in setOf("Movie", "Video")) {
            val variants = summary(items[0]).getJSONObject("image_variants")
            for (type in listOf("Thumb", "Backdrop")) variants.optJSONObject(type)?.let { images.put(type, it) }
        }
        return JSONObject().put("scene_id", id).put("image_variants", images)
    }
    // No shared native 'has no genre/tag' predicate: scan bounded pages, retaining only the
    // requested result page. Closing this request's HTTP scope also cancels the scan.
    private fun unclassified(args: LinkedHashMap<String, Any>, kind: String, page: Int): JSONObject {
        args["Limit"] = 128; args["Fields"] = "MediaSources,MediaStreams,Genres,Tags,ParentId,PrimaryImageAspectRatio"
        val out = JSONArray(); var matched = 0; var offset = 0
        val start = (page - 1) * 48
        while (true) {
            args["StartIndex"] = offset
            val result = get("Users/${user()}/Items", args)
            val items = result.getJSONArray("Items").objects()
            for (item in items) {
                val node = summary(item)
                if (node.getJSONArray(kind).length() == 0) {
                    if (matched in start until start + 48) out.put(node)
                    matched++
                }
            }
            offset += items.size
            if (items.isEmpty() || offset >= result.optInt("TotalRecordCount", offset)) break
        }
        return JSONObject().put("entries", out).put("total", matched).put("page", page)
    }
    override fun candidates(request: JSONObject): JSONObject {
        val kind = request.optString("kind")
        val path = mapOf("genres" to "Genres", "tags" to "Tags", "performers" to "Persons", "studios" to "Studios")[kind]
            ?: throw MediaServerFailure("Server query unsupported")
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val args = linkedMapOf<String, Any>("UserId" to user(), "Recursive" to true,
            "IncludeItemTypes" to "Movie,Episode,Video", "StartIndex" to (page - 1) * 48, "Limit" to 48,
            "SortBy" to "SortName", "SortOrder" to "Ascending", "Fields" to "ItemCounts")
        val parent = request.optString("library_id")
        if (parent.isNotBlank()) args["ParentId"] = mediaId(parent)
        val q = request.optString("q").take(200)
        if (q.isNotBlank()) args["SearchTerm"] = q
        val result = get(path, args)
        val nodes = result.getJSONArray("Items").objects().map { data ->
            val name = data.getString("Name").take(256)
            JSONObject().put("id", if (kind in setOf("genres", "tags")) name else data.getString("Id"))
                .put("name", name).put("count", if (data.has("ChildCount")) data.optInt("ChildCount") else -1)
        }
        return JSONObject().put("entries", JSONArray(nodes)).put("total", result.optInt("TotalRecordCount", nodes.size)).put("page", page)
    }
    override fun favorite(request: JSONObject): JSONObject {
        val id = mediaId(request.getString("scene_id")); val selected = request.getBoolean("favorite")
        val data = get("Users/${user()}/FavoriteItems/$id", method = if (selected) "POST" else "DELETE")
        return JSONObject().put("scene_id", id).put("favorite", data.optBoolean("IsFavorite", selected))
    }
    private fun item(id: String) = get("Users/${user()}/Items/${mediaId(id)}")
    private fun facets(data: JSONObject, objects: String, strings: String, nameIdentity: Boolean): JSONArray {
        val nodes = (data.optJSONArray(objects) ?: JSONArray()).objects().take(100).mapNotNull {
            val name = it.optString("Name").take(256)
            val id = if (nameIdentity) name else it.optString("Id")
            if (name.isBlank() || id.isBlank()) null else JSONObject().put("id", id).put("name", name).apply {
                if (objects == "People") {
                    put("role", it.optString("Role").take(150)); put("type", it.optString("Type"))
                    if (it.optString("PrimaryImageTag").isNotBlank()) put("cover_image", imageNode(id, "Primary", 0, it.getString("PrimaryImageTag")))
                    put("has_cover", has("cover_image"))
                }
            }
        }
        if (nodes.isNotEmpty()) return JSONArray(nodes)
        val values = data.optJSONArray(strings) ?: JSONArray()
        return JSONArray((0 until minOf(100, values.length())).map { values.getString(it).take(256) }
            .filter { it.isNotBlank() }.map { JSONObject().put("id", it).put("name", it) })
    }
    private fun summary(data: JSONObject): JSONObject {
        val id = mediaId(data.getString("Id"))
        val sources = data.optJSONArray("MediaSources") ?: JSONArray()
        val source = directSource(sources) ?: JSONObject()
        val video = (source.optJSONArray("MediaStreams") ?: data.optJSONArray("MediaStreams") ?: JSONArray()).objects().firstOrNull { it.optString("Type") == "Video" }
        val container = data.optBoolean("IsFolder") || data.optString("Type") in setOf("CollectionFolder", "Folder", "Series", "Season", "BoxSet", "Playlist")
        val userData = data.optJSONObject("UserData") ?: JSONObject()
        val result = JSONObject().put("id", id).put("kind", if (container) "container" else "video").put("container", container)
            .put("title", data.optString("Name", "Video").take(256)).put("duration_ms", data.optLong("RunTimeTicks").coerceAtLeast(0) / 10000)
            .put("basename", basename(source.optString("Path").ifBlank { data.optString("Path").ifBlank { data.optString("FileName") } }))
            .put("width", video?.optInt("Width") ?: 0).put("height", video?.optInt("Height") ?: 0)
            .put("description", data.optString("Overview").take(2000)).put("rating", (data.optDouble("CommunityRating", 0.0) * 10).toInt())
            .put("year", data.optInt("ProductionYear")).put("type", data.optString("Type"))
            .put("collection_type", data.optString("CollectionType"))
            .put("part_count", data.optInt("PartCount", 1).coerceAtLeast(1))
            .put("video_3d_format", source.optString("Video3DFormat").ifBlank { data.optString("Video3DFormat") })
            .put("child_count", data.optInt("ChildCount", -1)).put("favorite", userData.optBoolean("IsFavorite"))
            .put("watched", userData.optBoolean("Played")).put("position_ms", userData.optLong("PlaybackPositionTicks").coerceAtLeast(0) / 10000)
            .put("genres", facets(data, "GenreItems", "Genres", true)).put("tags", facets(data, "TagItems", "Tags", true))
            .put("performers", facets(data, "People", "", false)).put("studios", facets(data, "Studios", "", false))
        val tags = data.optJSONObject("ImageTags") ?: JSONObject()
        for ((input, output) in mapOf("ParentId" to "parent_id", "SeasonId" to "season_id", "SeriesId" to "series_id")) {
            data.optString(input).takeIf { it.isNotBlank() }?.let { raw ->
                runCatching { mediaId(raw) }.getOrNull()?.let { result.put(output, it) }
            }
        }
        if (data.optString("SeriesName").isNotBlank()) result.put("series_title", data.optString("SeriesName").take(256))
        val variants = JSONObject()
        for (type in listOf("Primary", "Thumb", "Backdrop")) {
            val tag = if (type == "Backdrop") data.optJSONArray("BackdropImageTags")?.optString(0).orEmpty() else tags.optString(type)
            if (tag.isNotBlank()) variants.put(type, imageNode(id, type, 0, tag))
        }
        result.put("image_variants", variants)
        val coverType = listOf("Primary", "Thumb", "Backdrop").firstOrNull { tags.optString(it).isNotBlank() ||
            (it == "Backdrop" && (data.optJSONArray("BackdropImageTags")?.length() ?: 0) > 0) }
        result.put("has_cover", coverType != null)
        if (coverType != null) result.put("cover_image", imageNode(id, coverType, 0,
            if (coverType == "Backdrop") data.optJSONArray("BackdropImageTags")?.optString(0).orEmpty() else tags.optString(coverType)))
        if (!container) result.put("uri", MediaLibraryUri.scene(account.id, id))
        return result
    }
    override fun detail(id: String): JSONObject {
        val data = item(id)
        val artwork = images(data)
        val result = playableDetail(data).put("description", data.optString("Overview"))
            .put("images", artwork).put("backdrops", backdrops(data, artwork))
        if (result.optInt("part_count") > 1 || partMarker.containsMatchIn(result.optString("basename"))) {
            val additional = get("Videos/${mediaId(id)}/AdditionalParts", mapOf("UserId" to user(), "Fields" to "MediaSources,MediaStreams,Path,Chapters", "EnableImages" to true))
                .getJSONArray("Items").objects()
            mediaRequire(additional.size <= 128, "Server response too large")
            val parts = (listOf(data) + additional).distinctBy { it.getString("Id") }.map { raw ->
                playableDetail(raw).apply {
                    val thumb = raw.optJSONObject("ImageTags")?.optString("Thumb").orEmpty()
                    val backdrop = raw.optJSONArray("BackdropImageTags")?.optString(0).orEmpty()
                    if (thumb.isNotBlank()) put("part_image", imageNode(getString("id"), "Thumb", 0, thumb)).put("has_cover", true)
                    else if (backdrop.isNotBlank()) put("part_image", imageNode(getString("id"), "Backdrop", 0, backdrop)).put("has_cover", true)
                }
            }
            parts.forEachIndexed { index, part ->
                val marker = partMarker.findAll(part.optString("basename")).lastOrNull()
                    ?: partMarker.findAll(part.optString("title")).lastOrNull()
                val label = marker?.groupValues?.get(1)?.lowercase() ?: "#${index + 1}"
                marker?.groupValues?.get(2)?.toLongOrNull()?.let { part.put("part_number", it) }
                part.put("part_label", label).put("title", result.getString("title") + " · " + label)
            }
            // Emby can return the main file and additional parts out of sequence. Missing
            // markers stay at the end in their original order; numeric ties are stable too.
            val ordered = parts.sortedBy { it.optLong("part_number", Long.MAX_VALUE) }
            result.put("parts", JSONArray(ordered)).put("part_count", ordered.size)
        }
        return result.put("actors", JSONArray(result.getJSONArray("performers").objects().filter { it.optString("type") in setOf("", "Actor", "GuestStar") }))
    }
    private fun playableDetail(data: JSONObject): JSONObject {
        val result = summary(data).put("markers", chapterMarkers(data))
        val sources = data.optJSONArray("MediaSources") ?: return result
        if (sources.length() <= 1) return result
        mediaRequire(sources.length() <= 128, "Server response too large")
        val defaultId = directSource(sources)?.optString("Id").orEmpty()
        val versions = sources.objects().filter { it.optString("Id").isNotBlank() }.distinctBy { it.getString("Id") }.mapIndexed { index, source ->
            val sourceId = source.getString("Id")
            val name = source.optString("Name").take(256).ifBlank { basename(source.optString("Path")) }.ifBlank { "${index + 1}" }
            val video = (source.optJSONArray("MediaStreams") ?: JSONArray()).objects().firstOrNull { it.optString("Type") == "Video" }
            JSONObject().put("id", result.getString("id")).put("source_id", sourceId).put("version_name", name)
                .put("uri", MediaLibraryUri.scene(account.id, result.getString("id"), sourceId))
                .put("title", result.getString("title") + " · " + name).put("default_version", sourceId == defaultId)
                .put("basename", basename(source.optString("Path").ifBlank { source.optString("FileName") }))
                .put("duration_ms", source.optLong("RunTimeTicks").coerceAtLeast(0) / 10000)
                .put("width", video?.optInt("Width") ?: 0).put("height", video?.optInt("Height") ?: 0)
                .put("video_3d_format", source.optString("Video3DFormat")).put("markers", chapterMarkers(source))
                // The item's server progress does not identify which version was watched.
                .put("position_ms", 0)
        }
        if (versions.size > 1) result.put("versions", JSONArray(versions))
        return result
    }
    private fun chapterMarkers(data: JSONObject) = JSONArray((data.optJSONArray("Chapters") ?: JSONArray()).objects().take(500).map {
        JSONObject().put("title", it.optString("Name").take(150)).put("position_ms", it.optLong("StartPositionTicks").coerceAtLeast(0) / 10000)
    })
    private val partMarker = Regex("(?:^|[ ._-])((?:cd|part|pt|disc|disk)[ ._-]?([0-9]{1,9}))(?=[ ._-]|$)", RegexOption.IGNORE_CASE)
    private fun imageNode(id: String, type: String, index: Int, tag: String = "") = JSONObject()
        .put("id", id).put("image_type", type).put("image_index", index).put("image_tag", tag.take(256))
    private fun backdrops(data: JSONObject, artwork: JSONArray): JSONArray {
        val own = artwork.objects().filter { it.optString("image_type") == "Backdrop" }
        if (own.isNotEmpty()) return JSONArray(own.take(12))
        val parent = data.optString("ParentBackdropItemId")
        val tags = data.optJSONArray("ParentBackdropImageTags") ?: JSONArray()
        if (parent.isNotBlank() && tags.length() > 0) {
            val id = runCatching { mediaId(parent) }.getOrNull()
            val inherited = if (id != null) (0 until minOf(12, tags.length())).mapNotNull { index ->
                tags.optString(index).takeIf { it.isNotBlank() }?.let { imageNode(id, "Backdrop", index, it) }
            } else emptyList()
            if (inherited.isNotEmpty()) return JSONArray(inherited)
        }
        // Keep portrait posters and chapter thumbnails out of a page-wide background.
        val thumbs = artwork.objects().filter { it.optString("image_type") == "Thumb" }.take(1)
        if (thumbs.isNotEmpty()) return JSONArray(thumbs)
        return JSONArray(artwork.objects().filter { it.optString("image_type") == "Screenshot" &&
            it.optInt("width") > it.optInt("height") && it.optInt("height") > 0 }.take(12))
    }
    private fun images(data: JSONObject): JSONArray {
        val id = mediaId(data.getString("Id")); val tags = data.optJSONObject("ImageTags") ?: JSONObject()
        val images = linkedMapOf<String, JSONObject>()
        fun add(type: String, index: Int) {
            if (type !in setOf("Primary", "Thumb", "Backdrop", "Screenshot", "Art", "Banner") || index !in 0..9999) return
            val tag = if (type == "Backdrop") data.optJSONArray("BackdropImageTags")?.optString(index).orEmpty() else tags.optString(type)
            images["$type/$index"] = imageNode(id, type, index, tag)
        }
        for (type in listOf("Primary", "Thumb", "Art", "Banner")) if (tags.optString(type).isNotBlank()) add(type, 0)
        for (index in 0 until minOf(128, data.optJSONArray("BackdropImageTags")?.length() ?: 0)) add("Backdrop", index)
        try {
            val raw = http.bytes(account.endpoint("Items/$id/Images"), 1024 * 1024)
            JSONArray(String(raw, Charsets.UTF_8)).objects().take(128).forEach {
                val type = it.optString("ImageType"); val index = it.optInt("ImageIndex", 0)
                add(type, index)
                images["$type/$index"]?.put("width", it.optInt("Width"))?.put("height", it.optInt("Height"))
            }
        } catch (error: Exception) {
            if (error is MediaServerFailure && error.code in setOf("Request cancelled", "Server authentication required")) throw error
            // A server without image enumeration still supplies its tagged images.
        }
        return JSONArray(images.values.take(128))
    }
    override fun cover(id: String): URI = account.endpoint("Items/${mediaId(id)}/Images/Primary?maxWidth=512&quality=85")
    override fun image(id: String, type: String, index: Int, tag: String, width: Int): URI {
        mediaRequire(type in setOf("Primary", "Thumb", "Backdrop", "Screenshot", "Art", "Banner") && index in 0..9999, "Cover unavailable")
        mediaRequire(tag.length <= 256 && width in 64..1024, "Invalid server request")
        val args = linkedMapOf<String, Any>("maxWidth" to width, "maxHeight" to width, "quality" to 85)
        if (tag.isNotBlank()) args["tag"] = tag
        return account.endpoint("Items/${mediaId(id)}/Images/$type/$index?" + mediaQuery(args))
    }
    private fun basename(path: String): String = if (path.startsWith("http://", true) || path.startsWith("https://", true))
        runCatching { URI(path).path.orEmpty().substringAfterLast('/') }.getOrDefault("")
        else path.substringAfterLast('/').substringAfterLast('\\')
    private fun directSource(sources: JSONArray): JSONObject? = sources.objects().firstOrNull {
        it.optBoolean("SupportsDirectPlay", true) && it.optString("Protocol", "File").lowercase() in setOf("file", "http", "https") && !it.optBoolean("RequiresOpening") && !it.optBoolean("IsInfiniteStream")
    }
    override fun stream(id: String): MediaStreamLink = stream(id, "")
    override fun stream(id: String, sourceId: String): MediaStreamLink {
        val args = linkedMapOf<String, Any>("UserId" to user())
        if (sourceId.isNotEmpty()) args["MediaSourceId"] = sourceId
        val data = get("Items/${mediaId(id)}/PlaybackInfo", args)
        val sources = data.optJSONArray("MediaSources") ?: throw MediaServerFailure("Video unavailable")
        // Direct play preserves the file and enables true byte seeking through our proxy.
        val candidates = if (sourceId.isEmpty()) sources else JSONArray(sources.objects().filter { it.optString("Id") == sourceId })
        val source = directSource(candidates)
            ?: throw MediaServerFailure("Original stream unavailable")
        val selectedId = source.getString("Id")
        mediaRequire(selectedId.length in 1..256)
        val protocol = source.optString("Protocol", "File").lowercase()
        if (protocol in setOf("http", "https") || source.optBoolean("IsRemote")) {
            val url = try { URI(source.getString("Path")) } catch (_: Exception) { throw MediaServerFailure("Invalid remote media address") }
            mediaRequire(url.scheme in setOf("http", "https") && !url.host.isNullOrEmpty() && url.rawUserInfo == null, "Invalid remote media address")
            val headerData = source.optJSONObject("RequiredHttpHeaders") ?: JSONObject()
            val headers = headerData.keys().asSequence().associateWith { headerData.getString(it) }
            return MediaStreamLink(url, selectedId + ":" + source.optLong("Size") + ":" + source.optString("ETag"),
                runCatching { subtitleLinks(id, source) }.getOrDefault(emptyList()), runCatching { audioLinks(source) }.getOrDefault(emptyList()),
                url.path.substringAfterLast('/'), remote = true, headers = headers)
        }
        val streamArgs = mapOf("Static" to true, "MediaSourceId" to selectedId,
            "PlaySessionId" to data.optString("PlaySessionId").ifBlank { UUID.randomUUID().toString().replace("-", "") })
        val basename = source.optString("Path").ifBlank { source.optString("FileName") }
            .substringAfterLast('/').substringAfterLast('\\').ifBlank {
                if (source.optString("Container").equals("iso", true)) "video.iso" else ""
            }
        return MediaStreamLink(account.endpoint("Videos/${mediaId(id)}/stream?" + mediaQuery(streamArgs)),
            selectedId + ":" + source.optLong("Size") + ":" + source.optString("ETag"), runCatching { subtitleLinks(id, source) }.getOrDefault(emptyList()), runCatching { audioLinks(source) }.getOrDefault(emptyList()), basename)
    }
    private fun audioLinks(source: JSONObject): List<MediaAudioLink> {
        val video = source.optString("Path").substringAfterLast('/').substringAfterLast('\\')
        if (video.isBlank()) return emptyList()
        val files = (source.optJSONArray("MediaStreams") ?: JSONArray()).objects().filter {
            it.optString("Type") == "Audio" && it.optBoolean("IsExternal") && it.optString("DeliveryUrl").isNotBlank()
        }.associateBy { it.optString("Path").substringAfterLast('/').substringAfterLast('\\') }
        return SidecarAudio.select(video, files.keys).mapNotNull { name ->
            val item = files.getValue(name)
            val url = account.endpoint("").resolve(item.getString("DeliveryUrl"))
            if (!account.accepts(url)) return@mapNotNull null
            MediaAudioLink(url, source.getString("Id") + ":audio:" + item.optInt("Index"), SidecarAudio.title(video, name))
        }
    }
    private fun subtitleLinks(id: String, source: JSONObject): List<MediaSubtitleLink> {
        val sourceId = source.getString("Id")
        mediaRequire(sourceId != "." && sourceId != "..")
        val segment = URLEncoder.encode(sourceId, "UTF-8").replace("+", "%20")
        val textCodecs = setOf("srt", "subrip", "ass", "ssa", "vtt", "webvtt", "smi", "sami", "subviewer", "microdvd", "mov_text")
        return (source.optJSONArray("MediaStreams") ?: JSONArray()).objects().filter {
            it.optString("Type") == "Subtitle" && it.optBoolean("IsExternal") && it.optInt("Index", -1) >= 0 &&
                (it.optBoolean("IsTextSubtitleStream") || it.optString("Codec").lowercase() in textCodecs)
        }.distinctBy { it.getInt("Index") }.take(8).map { caption ->
            val index = caption.getInt("Index")
            val title = caption.optString("DisplayTitle").ifBlank { caption.optString("Title") }
                .ifBlank { caption.optString("Language").ifBlank { "SRT ${index + 1}" } }.take(150)
            MediaSubtitleLink(account.endpoint("Videos/${mediaId(id)}/$segment/Subtitles/$index/Stream.srt"), title,
                language = caption.optString("Language").take(80))
        }
    }
}
