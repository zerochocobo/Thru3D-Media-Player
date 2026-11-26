package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Saved endpoints and bounded playback references. HTTP video URIs stay compatible with history. */
internal class DlnaLibrary(
    load: () -> String,
    private val persist: (String) -> Unit,
    private val discover: () -> List<DlnaClient.Server> = { DlnaClient.discover() },
) {
    private val saved = LinkedHashMap<String, JSONObject>()
    private val found = LinkedHashMap<String, DlnaClient.Server>()
    private val references = LinkedHashMap<String, JSONObject>()
    // Match the player's 32-entry history. Directory browsing must not evict played items.
    private val playbackReferences = LinkedHashMap<String, JSONObject>()
    private var durableReferences = JSONArray()
    private var durablePlayback = JSONArray()
    private val transientReferences = HashSet<String>()
    init {
        runCatching { JSONObject(load()) }.getOrNull()?.let { data ->
            data.optJSONArray("servers")?.let { list ->
                for (i in 0 until minOf(list.length(), 64)) {
                    val row = list.optJSONObject(i) ?: continue
                    if (server(row) != null) saved[row.getString("id")] = row
                }
            }
            fun restore(name: String, target: MutableMap<String, JSONObject>, limit: Int) {
                val list = data.optJSONArray(name) ?: return
                for (i in 0 until minOf(list.length(), limit)) {
                    val row = list.optJSONObject(i) ?: continue
                    val uri = DlnaClient.httpUri(row.optString("uri")) ?: continue
                    if (server(row.optJSONObject("server") ?: continue) != null) target[uri.toString()] = row
                }
            }
            restore("references", references, 256)
            restore("playback_references", playbackReferences, 32)
            durableReferences = JSONArray(data.optJSONArray("references")?.toString() ?: "[]")
            durablePlayback = JSONArray(data.optJSONArray("playback_references")?.toString() ?: "[]")
        }
    }

    @Synchronized fun servers(): JSONArray {
        val merged = LinkedHashMap<String, JSONObject>()
        found.values.forEach { merged[it.id] = it.json().put("manual", false) }
        saved.forEach { (id, row) -> merged[id] = JSONObject(row.toString()).put("manual", true) }
        return JSONArray(merged.values.toList())
    }

    fun refresh(): JSONArray {
        // Saved routes remain usable when multicast is blocked or unavailable.
        val discovered = runCatching { discover() }.getOrDefault(emptyList())
        synchronized(this) { found.clear(); discovered.forEach { found[it.id] = it } }
        return servers()
    }

    fun save(request: JSONObject): String {
        val location = request.optString("location").takeIf { it.isNotBlank() }
            ?: DlnaClient.address(request.optString("host"), request.optString("port"), request.optString("scheme", "http"))
        val connected = DlnaClient.connect(location)
        val row = connected.json().put("name", request.optString("name").trim().take(150).ifEmpty { connected.name })
        synchronized(this) {
            val previous = LinkedHashMap(saved)
            val oldId = request.optString("id")
            if (oldId.isNotEmpty()) saved.remove(oldId)
            check(saved.size < 64 || saved.containsKey(connected.id)) { "Too many DLNA servers" }
            saved[connected.id] = row
            try { store() } catch (error: Exception) { saved.clear(); saved.putAll(previous); throw error }
        }
        return connected.id
    }

    @Synchronized fun remove(id: String) {
        val previous = saved.remove(id) ?: return
        try { store() } catch (error: Exception) { saved[id] = previous; throw error }
        // A saved server may also have been discovered; refresh can find it again.
        found.remove(id)
    }

    fun browse(id: String, objectId: String): JSONArray {
        val selected = synchronized(this) { saved[id]?.let(::server) ?: found[id] } ?: error("DLNA server unavailable")
        val diagnostics = if (PlaybackPrivacy.diagnostics) DlnaClient.BrowseDiagnostics() else null
        val entries = try {
            DlnaClient.browse(selected, objectId, diagnostics = diagnostics)
        } finally {
            if (diagnostics != null && PlaybackPrivacy.diagnostics) DlnaClient.log("library_listing {$diagnostics}")
        }
        synchronized(this) {
            for (i in 0 until entries.length()) {
                val entry = entries.getJSONObject(i)
                if (entry.optString("kind") != "video") continue
                val uri = entry.getString("uri")
                if (PlaybackPrivacy.networkHistory) transientReferences.remove(uri) else transientReferences.add(uri)
                references.remove(uri)
                references[uri] = JSONObject().put("uri", uri).put("object_id", entry.getString("id"))
                    .put("server", selected.json()).put("parent_id", objectId).put("subtitle_origin", "directory")
                    .put("subtitles", entry.optJSONArray("subtitles") ?: JSONArray())
                if (playbackReferences.containsKey(uri)) playbackReferences[uri] = references.getValue(uri)
            }
            // Keep every video in the complete displayed directory available for subtitle selection.
            while (references.size > DlnaClient.MAX_BROWSE_ITEMS) references.remove(references.keys.first())
            // Reference caching must never turn a successful browse into an error.
            runCatching { store() }
        }
        return entries
    }

    fun thumbnailReader(id: String, url: String): DlnaThumbnailReader? {
        val endpoint = synchronized(this) { saved[id]?.let(::server) ?: found[id] } ?: return null
        val media = DlnaClient.httpUri(url)?.takeIf { it.rawUserInfo == null } ?: return null
        if (listOf(endpoint.location, endpoint.controlUrl).none {
                DlnaClient.httpUri(it)?.host.equals(media.host, ignoreCase = true)
            }) return null
        return DlnaThumbnailReader(media)
    }

    fun thumbnailChildren(id: String, objectId: String, job: LocalThumbnailPrefetch.Work): JSONArray {
        val endpoint = synchronized(this) { saved[id]?.let(::server) ?: found[id] } ?: return JSONArray()
        return DlnaClient.thumbnailChildren(endpoint, objectId, job)
    }

    fun playable(uri: String): String {
        val identity = java.net.URI(uri)
        require(identity.scheme == "dlna" && !identity.rawAuthority.isNullOrEmpty())
        val id = java.net.URLDecoder.decode(identity.rawAuthority, "UTF-8")
        var selected = synchronized(this) { saved[id]?.let(::server) ?: found[id] }
        if (selected == null) { refresh(); selected = synchronized(this) { saved[id]?.let(::server) ?: found[id] } }
        val endpoint = selected ?: run {
            if (PlaybackPrivacy.diagnostics) DlnaClient.log("playback_lookup outcome=server_unavailable metadata=not_queried parent=not_queried")
            error("DLNA server unavailable")
        }
        val objectId = java.net.URLDecoder.decode(identity.rawPath.removePrefix("/"), "UTF-8")
        val metadataDiagnostics = if (PlaybackPrivacy.diagnostics) DlnaClient.BrowseDiagnostics(objectId) else null
        var parentDiagnostics: DlnaClient.BrowseDiagnostics? = null
        var parentStatus = "not_queried"
        var outcome = "failed"
        try {
            // Some servers declare the item but send an empty DIDL. Only a known parent on this
            // server may then confirm the exact object; without one the count failure stands.
            val metadataEntries = try {
                DlnaClient.browse(endpoint, objectId, metadata = true, diagnostics = metadataDiagnostics)
            } catch (error: DlnaClient.EmptyMetadataResponse) {
                if (knownParent(id, objectId, null) == null) throw error
                JSONArray()
            }
            val metadata = media(metadataEntries, objectId)
            val parentId = metadata?.optString("parent_id")?.takeIf { it.isNotBlank() && it != objectId }
                ?: knownParent(id, objectId, metadata?.optString("uri"))
            // Some servers list the stream only in BrowseDirectChildren. Use the saved parent
            // as a location hint and obtain the resource again, including any renewed URL.
            val entry = if (metadata != null) {
                parentStatus = "not_needed"
                metadata
            } else {
                parentStatus = "no_known_parent"
                val parent = parentId ?: error("DLNA item unavailable")
                parentDiagnostics = metadataDiagnostics?.let { DlnaClient.BrowseDiagnostics(objectId) }
                media(DlnaClient.browse(endpoint, parent, diagnostics = parentDiagnostics), objectId)
                    ?.takeIf { DlnaClient.httpUri(it.optString("uri")) != null } ?: error("DLNA item unavailable")
            }
            val resolved = entry.getString("uri")
            synchronized(this) {
                references[resolved] = JSONObject().put("uri", resolved).put("object_id", objectId).put("server", endpoint.json())
                    .put("parent_id", parentId.orEmpty()).put("subtitle_origin", "directory")
                    .put("subtitles", entry.optJSONArray("subtitles") ?: JSONArray())
                if (PlaybackPrivacy.networkHistory) transientReferences.remove(resolved) else transientReferences.add(resolved)
            }
            outcome = if (metadata != null) "metadata_selected" else "parent_selected"
            return resolved
        } finally {
            if (metadataDiagnostics != null && PlaybackPrivacy.diagnostics) {
                val parent = parentDiagnostics?.let { "{$it}" } ?: parentStatus
                DlnaClient.log("playback_lookup outcome=$outcome metadata={$metadataDiagnostics} parent=$parent")
            }
        }
    }

    @Synchronized private fun knownParent(serverId: String, objectId: String, uri: String?): String? {
        fun matches(row: JSONObject): Boolean = row.optString("object_id") == objectId &&
            row.optJSONObject("server")?.optString("id") == serverId &&
            row.optString("parent_id").let { it.isNotBlank() && it != "-1" && it != objectId }

        val reference = uri?.let { references[it] }?.takeIf(::matches)
            ?: references.values.lastOrNull(::matches)
            ?: playbackReferences.values.lastOrNull(::matches)
        return reference?.getString("parent_id")
    }

    fun subtitles(uri: String): List<MediaSubtitleLink> {
        if (!PlaybackPrivacy.networkHistory) synchronized(this) { transientReferences.add(uri) }
        val original = synchronized(this) { references[uri] ?: playbackReferences[uri] } ?: return emptyList()
        val reference = JSONObject(original.toString())
        var captions = reference.optJSONArray("subtitles") ?: JSONArray()
        var origin = reference.optString("subtitle_origin", "legacy")
        var captionVideo = uri
        var parentRequested = false
        val selected = reference.optJSONObject("server")?.let(::server)
        val objectId = reference.optString("object_id")
        fun updateVideo(entry: JSONObject?) {
            entry?.optString("uri")?.let { DlnaClient.httpUri(it) }?.let { captionVideo = it.toString() }
        }
        fun refreshParent(): Boolean {
            val parent = reference.optString("parent_id")
            if (selected == null || objectId.isBlank() || parent.isBlank() || parent == "-1") return false
            parentRequested = true
            reference.put("subtitle_directory_fallback", true)
            return runCatching {
                val entry = video(DlnaClient.browse(selected, parent), objectId)
                // A complete parent listing confirms removal as well as added/language tracks.
                captions = entry?.optJSONArray("subtitles") ?: JSONArray()
                origin = "directory"
                updateVideo(entry)
                true
            }.getOrDefault(false)
        }
        val metadata = if (selected != null && objectId.isNotBlank())
            runCatching { DlnaClient.browse(selected, objectId, metadata = true) }.getOrNull() else null
        if (metadata != null) {
            // Resource URLs can change (signed queries, alternate paths); IDs are server-scoped.
            val entry = video(metadata, objectId)
            updateVideo(entry)
            if (reference.optString("parent_id").isBlank()) {
                entry?.optString("parent_id")?.takeIf { it.isNotBlank() && it != "-1" && it != objectId }
                    ?.let { reference.put("parent_id", it) }
            }
            val refreshed = entry?.optJSONArray("subtitles")
            when {
                refreshed != null && refreshed.length() > 0 -> { captions = refreshed; origin = "metadata" }
                origin == "header" -> captions = JSONArray() // Header-only servers need a fresh HEAD, not a directory scan.
                captions.length() > 0 || reference.optBoolean("subtitle_directory_fallback") -> refreshParent()
                else -> captions = JSONArray()
            }
            // An empty/minimal BrowseMetadata response is not proof that old tracks were removed.
            // If the parent is unavailable, the optional downloader still validates cached links.
        }
        if (captions.length() == 0 || (metadata != null && origin == "legacy" && !parentRequested)) {
            val header = runCatching { DlnaClient.captionHeader(captionVideo) }.getOrDefault(JSONArray())
            if (header.length() > 0) { captions = header; origin = "header" }
            else if (captions.length() == 0 && origin == "header" && metadata != null && !parentRequested &&
                reference.optBoolean("subtitle_directory_fallback")) refreshParent()
        }
        synchronized(this) {
            val current = references[uri] ?: playbackReferences[uri]
            // A concurrent browse may have replaced the reference; keep its newer data, but
            // still record this playback so history replay can find the item later.
            val played = if (current === original) {
                references.remove(uri)
                reference.put("subtitles", captions).put("subtitle_origin", origin).also { references[uri] = it }
            } else current
            if (played != null) {
                playbackReferences.remove(uri)
                playbackReferences[uri] = played
                while (playbackReferences.size > 32) playbackReferences.remove(playbackReferences.keys.first())
                // The selected item must survive restart even if it was early in a large page.
                runCatching { store() }
            }
        }
        return (0 until captions.length()).mapNotNull {
            val track = captions.optJSONObject(it) ?: return@mapNotNull null
            val url = DlnaClient.httpUri(track.optString("url")) ?: return@mapNotNull null
            val type = DlnaClient.subtitleType(track.optString("extension"))
            if (type.isEmpty()) null else MediaSubtitleLink(url, track.optString("title"), type)
        }.take(8)
    }

    private fun video(entries: JSONArray, objectId: String): JSONObject? = media(entries, objectId, setOf("video"))

    /** Images and audio open through the same dlna:// identity as videos; subtitles stay video-only. */
    private fun media(entries: JSONArray, objectId: String, kinds: Set<String> = setOf("video", "image", "audio")): JSONObject? =
        (0 until entries.length())
            .mapNotNull { entries.optJSONObject(it) }
            .singleOrNull { it.optString("kind") in kinds && it.optString("id") == objectId }

    @Synchronized fun clearPlaybackReferences() {
        references.clear(); playbackReferences.clear(); transientReferences.clear(); durableReferences = JSONArray(); durablePlayback = JSONArray()
        store()
    }

    private fun store() {
        val mayRecord = PlaybackPrivacy.networkHistory
        val nextReferences = if (mayRecord) JSONArray(references.filterKeys { it !in transientReferences }.values.toList().takeLast(256)) else durableReferences
        val nextPlayback = if (mayRecord) JSONArray(playbackReferences.filterKeys { it !in transientReferences }.values.toList()) else durablePlayback
        persist(JSONObject().put("servers", JSONArray(saved.values.toList()))
            .put("references", nextReferences).put("playback_references", nextPlayback).toString())
        durableReferences = JSONArray(nextReferences.toString()); durablePlayback = JSONArray(nextPlayback.toString())
    }

    private fun server(row: JSONObject): DlnaClient.Server? {
        val location = DlnaClient.httpUri(row.optString("location")) ?: return null
        val control = DlnaClient.httpUri(row.optString("control_url")) ?: return null
        val id = row.optString("id").takeIf { it.isNotBlank() } ?: return null
        val type = row.optString("service_type", "urn:schemas-upnp-org:service:ContentDirectory:1")
        if (!type.matches(Regex("urn:schemas-upnp-org:service:ContentDirectory:[1-9][0-9]*"))) return null
        return DlnaClient.Server(id, row.optString("name"), location.toString(), control.toString(), type)
    }
}
