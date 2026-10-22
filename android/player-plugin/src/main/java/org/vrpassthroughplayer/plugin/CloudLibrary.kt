package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Only display metadata and stable cloud:// paths reach Godot. */
internal object CloudLibrary {
    private lateinit var store: CloudAccountStore
    private lateinit var appContext: Context
    private var saved = JSONArray()
    private var initialized = false
    val providers = CloudDrive.PROVIDERS
    private val activeStreams = HashMap<String, MutableList<Pair<LocalStreamServer, String>>>()
    private val metadata = HashMap<String, CloudMetadata>()
    private val playbackPages = CloudPlaybackPages()
    private val playbackCompanions = HashMap<String, CloudPlaybackPages.Playback>()

    @Synchronized fun start(context: Context) {
        if (initialized) return
        try {
            val candidate = CloudAccountStore(context.applicationContext)
            val accounts = candidate.load()
            store = candidate; saved = accounts; appContext = context.applicationContext; initialized = true
        } catch (_: Exception) { throw CloudFailure("cloud_store_unavailable") }
    }
    @Synchronized fun accounts(): JSONArray = JSONArray().also { result ->
        for (i in 0 until saved.length()) {
            val item = saved.getJSONObject(i)
            result.put(JSONObject().put("id", item.getString("id")).put("name", item.getString("name"))
                .put("provider", item.getString("provider")))
        }
    }
    @Synchronized private fun credentials(id: String): JSONObject = (0 until saved.length())
        .map { saved.getJSONObject(it) }.firstOrNull { it.getString("id") == id }
        ?.let { JSONObject(it.toString()) } ?: throw CloudFailure("cloud_login_required")
    @Synchronized private fun drive(account: JSONObject, http: CloudTransport = CloudHttp, folderId: String = ""): CloudClient {
        if (identity(credentials(account.getString("id"))) != identity(account))
            throw CloudFailure("cloud_login_required")
        val cache = metadata.getOrPut(account.getString("id")) { CloudMetadata() }
        return if (OpenListBackend.supported(account.getString("provider"))) {
            val client = OpenListBackend.client(account, http as? CloudCancellation, folderId) // Legacy Baidu cookies need OAuth reauthorization.
            OpenListBackend.start(appContext); client
        } else CloudDrive(account.getString("provider"), account.getString("cookie"), http, cache)
    }

    fun connect(provider: String, name: String, cookie: String, id: String? = null,
        commit: ((() -> Unit) -> Unit) = { it() }) = safe {
        require(provider == CloudDrive.P115 && id != null && name.isNotBlank() && CloudHttp.validCookie(cookie))
        val account = JSONObject().put("id", id).put("provider", provider)
            .put("name", name.trim().take(80)).put("cookie", cookie)
        // Validate the session with a single page, even when the root contains many files.
        CloudDrive(provider, cookie).page("/")
        commit { synchronized(this) {
            if (credentials(id).getString("provider") != provider) throw CloudFailure()
            val updated = JSONArray()
            for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
            updated.put(account)
            store.save(updated); saved = updated
            revoke(id)
        } }
        CloudAccountChanges.emit()
    }
    private fun identity(account: JSONObject) = account.optString("cookie", account.optString("mount"))

    fun connectOAuth(credential: OpenListAuth.Credential, name: String, id: String? = null,
        commit: ((() -> Unit) -> Unit) = { it() }) = safe {
        require(name.isNotBlank() && OpenListAuth.supported(credential.provider))
        OpenListBackend.start(appContext)
        saveMount(OpenListBackend.create(credential), name, id, commit)
    }
    fun webDavMetadata(id: String): JSONObject = safe {
        val account = credentials(id)
        require(account.getString("provider") == CloudDrive.WEBDAV)
        JSONObject().put("base", account.getString("base")).put("username", account.optString("username"))
            .put("has_password", account.optBoolean("has_password"))
    }
    fun connectWebDav(name: String, base: String, username: String, password: String, id: String? = null,
        commit: ((() -> Unit) -> Unit) = { it() }) = safe {
        require(name.isNotBlank())
        val old = id?.let(::credentials)
        require(old == null || old.getString("provider") == CloudDrive.WEBDAV)
        OpenListBackend.start(appContext)
        val previous = old?.let(OpenListBackend::webDavConnection)
        val connection = RemoteWebDav.connection(base, username, password, previous)
        saveMount(OpenListBackend.createWebDav(connection), name, id, commit, old?.getString("mount"))
    }
    private fun saveMount(candidate: JSONObject, name: String, id: String?, commit: ((() -> Unit) -> Unit), expectedMount: String? = null) {
        candidate.put("id", id ?: UUID.randomUUID().toString()).put("name", name.trim().take(80))
        var accepted = false
        var retired = 0
        try {
            commit { synchronized(this) {
                if (id != null) {
                    val old = credentials(id)
                    require(old.getString("provider") == candidate.getString("provider"))
                    if (expectedMount != null) require(old.getString("mount") == expectedMount)
                    retired = old.optInt("core_id")
                }
                val updated = JSONArray()
                for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
                updated.put(candidate)
                store.save(updated); saved = updated; accepted = true
                if (id != null) revoke(id)
            } }
        } finally {
            if (!accepted) runCatching { OpenListBackend.remove(candidate.getInt("core_id")) }
        }
        if (retired > 0) runCatching { OpenListBackend.remove(retired) }
        CloudAccountChanges.emit()
    }
    private fun source(account: JSONObject, client: CloudClient, file: CloudFile): CloudStreamSource {
        val resolve = {
            if (identity(credentials(account.getString("id"))) != identity(account)) throw CloudFailure("cloud_login_required")
            client.resolve(file)
        }
        return if (OpenListBackend.supported(account.getString("provider")))
            CloudStreamSource(file.size, resolve, linkConnection = OpenListBackend::connection)
        else CloudStreamSource(file.size, resolve)
    }

    fun rename(id: String, name: String) = safe {
        synchronized(this) {
            val updated = CloudAccountChanges.renamed(saved, id, name)
            store.save(updated); saved = updated
        }
        CloudAccountChanges.emit()
    }
    fun remove(id: String) = safe {
        var retired = 0
        synchronized(this) {
            retired = credentials(id).optInt("core_id")
            val updated = JSONArray()
            for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
            store.save(updated); saved = updated; revoke(id)
        }
        if (retired > 0) runCatching { OpenListBackend.start(appContext); OpenListBackend.remove(retired) }
        CloudAccountChanges.emit()
    }
    private fun revoke(id: String, disconnectDav: Boolean = true) {
        synchronized(sortedPages) { sortedPages.remove(id) }
        playbackCompanions.remove(id)?.cancellation?.cancel()
        if (disconnectDav) playbackPages.remove(id)
        if (disconnectDav) metadata.remove(id)
        activeStreams.remove(id)?.forEach { (server, url) -> server.revoke(url) }
        if (disconnectDav) CloudWebDav.disconnectClients()
    }
    @Synchronized fun stopStreams() { activeStreams.keys.toList().forEach { revoke(it, false) } }

    private val sortedPages = HashMap<String, CloudSortedPages>()
    fun searchScopes(provider: String): JSONArray = JSONArray().put("current").also {
        if (provider in setOf(CloudDrive.ONEDRIVE, CloudDrive.BAIDU)) it.put("tree")
        if (provider in setOf(CloudDrive.OPEN115, CloudDrive.ONEDRIVE, CloudDrive.BAIDU)) it.put("all")
    }
    fun search(path: String, query: String, scope: String, kind: String, cursor: String, refresh: Boolean, http: CloudTransport = CloudHttp): JSONObject {
        val (id, remote) = split(path)
        val account = credentials(id)
        require(query.isNotBlank() && query.codePointCount(0, query.length) <= 128 && kind in setOf("all", "video", "image", "folder")) { "Invalid search" }
        require((0 until searchScopes(account.getString("provider")).length()).any { searchScopes(account.getString("provider")).getString(it) == scope }) { "Search scope unavailable" }
        // Legacy cookie accounts retain current-directory search through their bounded metadata cache.
        val data = if (OpenListBackend.supported(account.getString("provider"))) {
            OpenListBackend.start(appContext)
            OpenListBackend.client(account).search(remote, query.trim(), scope, kind, cursor, refresh, http as? CloudCancellation)
        } else legacySearch.search(id, identity(account), drive(account, http), remote, query.trim(), kind, cursor, refresh)
        if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
        val entries = JSONArray()
        val content = data.getJSONArray("content")
        for (i in 0 until content.length()) {
            val item = content.getJSONObject(i)
            val name = item.getString("name")
            if (!item.getBoolean("is_dir") && !MediaKinds.supportedFileName(name)) continue
            val remotePath = item.optString("path")
            val location = if (remotePath.isEmpty()) "" else CloudPaths.child(remotePath.substringBeforeLast('/').ifEmpty { "/" }, name)
            entries.put(JSONObject().put("title", name).put("container", item.getBoolean("is_dir"))
                .put("kind", MediaKinds.fileNameKind(name)).put("search_token", item.getString("token"))
                .put("search_path", path).put("relative_path", location).put("size", item.optLong("size")))
        }
        return JSONObject().put("path", path).put("query", query.trim()).put("scope", scope).put("kind", kind)
            .put("cursor", cursor).put("next_cursor", data.optString("next_cursor")).put("limited", data.optBoolean("limited"))
            .put("entries", entries).put("search_scopes", searchScopes(account.getString("provider")))
    }
    private val legacySearch = CloudDirectorySearch()
    fun resolveSearch(path: String, token: String, cancellation: CloudCancellation? = null): JSONObject {
        val (id, remote) = split(path); val account = credentials(id)
        val data = if (OpenListBackend.supported(account.getString("provider"))) OpenListBackend.client(account).resolveSearch(remote, token, cancellation)
            else legacySearch.resolve(id, identity(account), token)
        if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
        val name = data.getString("name"); val destination = data.getString("path")
        require(CloudPaths.child(destination.substringBeforeLast('/').ifEmpty { "/" }, name) == destination)
        val full = "/$id" + destination
        return JSONObject().put("title", name).put("id", full).put("container", data.getBoolean("is_dir"))
            .put("cloud_id", data.optString("id")).put("sort_orders", sortOrders(account.getString("provider")))
            .put("kind", MediaKinds.fileNameKind(name)).put("uri", if (data.getBoolean("is_dir")) "" else CloudPaths.uri(full))
    }
    fun sortOrders(provider: String): JSONArray {
        val orders = (CloudSortedPages.ORDERS + "source").filter { provider != CloudDrive.QUARK || !it.startsWith("size_") }
        return JSONArray(if (provider in setOf(CloudDrive.OPEN115, CloudDrive.WEBDAV)) orders + orders.map { "mixed_$it" } else orders)
    }
    fun effectiveOrder(provider: String, order: String): String =
        if (provider == CloudDrive.QUARK && order.startsWith("size_")) "name_asc" else order

    fun browse(path: String, refresh: Boolean, offset: Int = 0, http: CloudTransport = CloudHttp, order: String = "", folderId: String = "", subtitlesOnly: Boolean = false, requestedSize: Int = CloudDrive.PAGE_SIZE): JSONObject = safe {
        val entries = JSONArray()
        var nextOffset = -1
        var total = -1
        var pageSize = CloudDrive.PAGE_SIZE
        var rawCount = 0
        var rawIds = emptyList<String>()
        var actualOrder = order
        var provider = ""
        if (path.isEmpty() || path == "/") {
            val accounts = accounts()
            for (i in 0 until accounts.length()) {
                val account = accounts.getJSONObject(i)
                entries.put(JSONObject().put("id", "/" + account.getString("id")).put("title", account.getString("name")).put("container", true)
                    .put("provider", account.getString("provider")).put("sort_orders", sortOrders(account.getString("provider"))))
            }
        } else {
            val (id, remote) = split(path)
            val account = credentials(id)
            provider = account.getString("provider")
            actualOrder = effectiveOrder(provider, order)
            val client = drive(account, http, folderId)
            val page = if (requestedSize != CloudDrive.PAGE_SIZE) client.sizedPage(remote, offset, refresh, actualOrder.ifEmpty { "source" }, requestedSize) else if (actualOrder.isEmpty()) client.page(remote, offset, refresh) else
                synchronized(sortedPages) { sortedPages.getOrPut(id) { CloudSortedPages() } }.page(client, remote, offset, refresh, actualOrder)
            if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            nextOffset = page.nextOffset
            total = page.total
            pageSize = page.pageSize
            rawCount = page.rawCount
            rawIds = page.rawIds
            synchronized(this) {
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
                if (Thread.currentThread().isInterrupted || (http as? CloudCancellation)?.cancelled == true) throw CloudFailure()
                if (!subtitlesOnly) playbackPages.replace(id, identity(account), remote, page.files,
                    offset == 0 && page.nextOffset < 0, folderId)
            }
            for (file in page.files) {
                if (!file.folder && !(if (subtitlesOnly) SidecarSubtitles.supportedFile(file.name) else MediaKinds.supported(file.name))) continue
                val child = CloudPaths.child(path, file.name)
                entries.put(JSONObject().put("id", child).put("title", file.name).put("container", file.folder)
                    .put("size", file.size).put("modified", file.modified).put("can_delete", client.canDelete && file.canDelete)
                    .put("can_rename", client.canRename && file.canRename)
                    .put("cloud_id", file.objectId).put("delete_effect", if (client.canDelete) "recycle" else "")
                    .put("delete_reason", "File deletion unavailable for this source").apply {
                        if (file.folder && (client.canDelete || client.canRename)) put("delete_uri", CloudPaths.uri(child))
                        if (!file.folder) put("uri", CloudPaths.uri(child)).put("kind", MediaKinds.kind(file.name))
                    })
            }
        }
        JSONObject().put("path", path).put("offset", offset).put("order", actualOrder).put("order_fallback", actualOrder != order).put("next_offset", nextOffset)
            .put("total", total).put("page_size", pageSize).put("raw_count", rawCount).put("raw_ids", JSONArray(rawIds))
            .put("direct_jump", CloudPaging.direct(provider)).put("entries", entries)
            .apply { if (provider.isNotEmpty()) put("search_scopes", searchScopes(provider)).put("sort_orders", sortOrders(provider)) }
    }
    fun renameFile(request: JSONObject, prepare: Boolean, authorized: () -> Unit): JSONObject {
        val (id, remote) = split(CloudPaths.path(request.getString("uri")))
        val account = credentials(id)
        val client = drive(account, folderId = playbackPages.folderId(id, identity(account), remote.substringBeforeLast('/').ifEmpty { "/" }))
        return try {
            val result = CloudRename(client) {
                authorized()
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            }.run(remote, request, prepare)
            if (result.has("new_path")) result.put("new_uri", CloudPaths.uri("/$id" + result.getString("new_path"))).remove("new_path")
            result.optJSONArray("moves")?.let { moves ->
                for (i in 0 until moves.length()) moves.getJSONObject(i).apply {
                    put("old_uri", CloudPaths.uri("/$id" + getString("old_path"))); remove("old_path")
                    put("new_uri", CloudPaths.uri("/$id" + getString("new_path"))); remove("new_path")
                }
            }
            result
        } finally {
            if (!prepare) {
                synchronized(sortedPages) { sortedPages.remove(id) }
                synchronized(this) { metadata[id]?.invalidate("/"); playbackPages.remove(id); playbackCompanions.remove(id) }
            }
        }
    }
    fun deleteFile(request: JSONObject, inspect: Boolean, prepare: Boolean, authorized: () -> Unit): JSONObject {
        val (id, remote) = split(CloudPaths.path(request.getString("uri")))
        val account = credentials(id)
        val client = drive(account, folderId = playbackPages.folderId(id, identity(account), remote.substringBeforeLast('/').ifEmpty { "/" }))
        require(remote != "/" && client.canDelete) { "File deletion unavailable for this source" }
        return try {
            CloudDeletion(client) {
                authorized()
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            }.run(remote, request, inspect, prepare)
        } finally {
            if (!inspect && !prepare) {
                synchronized(sortedPages) { sortedPages.remove(id) }
                synchronized(this) { metadata[id]?.invalidate("/"); playbackPages.remove(id); playbackCompanions.remove(id) }
            }
        }
    }
    /** Independent download lease: browsing photos or starting another video must not revoke it. */
    fun audioDownload(uri: String, server: LocalStreamServer, rangeWindow: Long = Long.MAX_VALUE): String = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val companions = playbackPages.forVideo(id, identity(account), remote)
        val client = drive(account, folderId = companions.folderId)
        val file = client.findForPlayback(remote, companions.files.singleOrNull { it.id == remote && !it.folder })
        val source = source(account, client, file)
        if(rangeWindow<Long.MAX_VALUE)source.boundedRanges(rangeWindow)
        try {
            source.prepare()
            synchronized(this) {
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
                server.publish(source, file.name)
            }
        } catch (error: Exception) { source.close(); throw error }
    }

    fun playable(uri: String, server: LocalStreamServer): String = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val companions = playbackPages.forVideo(id, identity(account), remote)
        val client = drive(account, folderId = companions.folderId)
        val file = client.findForPlayback(remote, companions.files.singleOrNull { it.id == remote && !it.folder })
        val source = source(account, client, file)
        source.prepare()
        synchronized(this) {
            if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            stopStreams()
            val url = server.publish(source, file.name)
            activeStreams.getOrPut(id) { ArrayList() }.add(server to url)
            playbackCompanions[id] = CloudPlaybackPages.Playback(remote, identity(account), companions)
            url
        }
    }

    /** Derived input retains the same object-bound resolver and logout boundary. */
    @Synchronized fun playbackView(parent: String, layout: Mp4PlaybackLayout, server: LocalStreamServer): String? {
        val owner = activeStreams.entries.firstOrNull { (_, streams) -> streams.any { it.first === server && it.second == parent } } ?: return null
        val url = server.playbackView(parent, layout) ?: return null
        owner.value.removeAll { it.first === server && !server.hasSource(it.second) }
        owner.value.add(server to url)
        return url
    }
    fun sidecarSubtitles(uri: String, server: LocalStreamServer): List<SidecarSubtitles.Track> = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val selected = companionSelection(id, account, remote) ?: return@safe emptyList()
        val client = drive(account, selected.cancellation, selected.page.folderId)
        SidecarSubtitles.forCloud(remote, selected.automatic(client)) { publishCompanion(account, client, it, server, selected) }
    }
    fun sidecarAudio(uri: String, server: LocalStreamServer): List<SidecarAudio.Track> = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val selected = companionSelection(id, account, remote) ?: return@safe emptyList()
        val client = drive(account, selected.cancellation, selected.page.folderId)
        SidecarAudio.forCloud(remote, selected.automatic(client)) { publishCompanion(account, client, it, server, selected) }
    }
    fun subtitleFiles(uri: String): List<String> = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        companionSelection(id, credentials(id), remote)?.subtitleNames() ?: emptyList()
    }
    fun openSubtitleFile(uri: String, name: String, server: LocalStreamServer): SidecarSubtitles.Track = safe {
        require(SidecarSubtitles.supportedFile(name))
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val selected = companionSelection(id, account, remote) ?: throw CloudFailure("cloud_file_missing")
        val client = drive(account, selected.cancellation, selected.page.folderId)
        val file = selected.subtitle(name, client)
        SidecarSubtitles.Track(publishCompanion(account, client, file, server, selected), name)
    }
    @Synchronized private fun companionSelection(id: String, account: JSONObject, remote: String): CloudPlaybackPages.Playback? =
        playbackCompanions[id]?.takeIf { it.path == remote && it.identity == identity(account) }
    private fun publishCompanion(account: JSONObject, client: CloudClient, file: CloudFile, server: LocalStreamServer, selected: CloudPlaybackPages.Playback): String {
        val id = account.getString("id")
        val source = source(account, client, file)
        return try {
            source.prepare()
            synchronized(this) {
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
                // Add to the current video's leases; playable() would revoke the video stream.
                if (playbackCompanions[id] !== selected || selected.cancellation.cancelled) throw CloudFailure()
                val url = server.publish(source, file.name)
                activeStreams.getOrPut(id) { ArrayList() }.add(server to url)
                url
            }
        } catch (error: Exception) { source.close(); throw error }
    }
    private fun split(path: String): Pair<String, String> {
        val normalized = if ('/' !in path.removePrefix("/")) "$path/" else path
        val valid = CloudPaths.path(CloudPaths.uri(normalized))
        val id = valid.removePrefix("/").substringBefore('/')
        return id to valid.removePrefix("/$id").ifEmpty { "/" }
    }
    val dav: CloudDavFiles = object : CloudDavFiles {
        override fun stat(path: String): DavEntry = safe {
            if (path == "/") return@safe DavEntry("/", "Quest Cloud", true)
            val (id, remote) = split(path)
            val account = credentials(id)
            if (remote == "/") return@safe DavEntry(path, account.getString("name"), true)
            val parent = remote.substringBeforeLast('/').ifEmpty { "/" }
            val client = drive(account, folderId = playbackPages.folderId(id, identity(account), parent))
            val files = client.freshMatches(parent, listOf(remote.substringAfterLast('/'))) ?: client.list(parent)
            val matches = files.filter { it.name == remote.substringAfterLast('/') }
            if (matches.size > 1) throw CloudFailure("cloud_file_ambiguous")
            val item = matches.singleOrNull() ?: throw CloudFailure("cloud_file_missing")
            DavEntry(path, item.name, item.folder, item.size)
        }
        override fun list(path: String): List<DavEntry> = safe {
            if (path == "/") {
                val accounts = accounts()
                return@safe (0 until accounts.length()).map { accounts.getJSONObject(it) }.map {
                    DavEntry("/" + it.getString("id"), it.getString("name"), true)
                }
            }
            val (id, remote) = split(path)
            drive(credentials(id)).list(remote).map { DavEntry(CloudPaths.child(path, it.name), it.name, it.folder, it.size) }
        }
        override fun source(path: String): StreamSource = safe {
            val (id, remote) = split(path)
            val account = credentials(id)
            val client = drive(account, folderId = playbackPages.folderId(id, identity(account), remote.substringBeforeLast('/').ifEmpty { "/" }))
            val file = client.find(remote)
            source(account, client, file)
        }
    }
    private inline fun <T> safe(block: () -> T): T = try { block() }
        catch (error: CloudFailure) { throw error }
        catch (error: Exception) { throw CloudDiagnostics.failure("cloud.library", error) }
}
