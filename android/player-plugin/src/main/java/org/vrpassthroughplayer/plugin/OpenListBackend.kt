package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import org.vrpassthroughplayer.cloudcore.Cloudcore
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.util.UUID

/** OAuth mounts live in the encrypted core database; account IDs keep existing cloud paths stable. */
internal object OpenListBackend {
    private val drivers = OpenListAuth.drivers + (CloudDrive.WEBDAV to "WebDav")
    fun supported(provider: String) = provider in drivers
    private var initialized = false
    @Synchronized fun start(context: Context) {
        if (initialized) return
        try {
            Cloudcore.start(File(context.noBackupFilesDir, "openlist-vr-v1").absolutePath, CloudSecret.key(context))
            initialized = true
        } catch (_: Exception) { throw CloudFailure("cloud_store_unavailable") }
    }
    fun request(method: String, route: String, body: JSONObject? = null, cancellation: CloudCancellation? = null): JSONObject {
        val result = try {
            if (cancellation == null) JSONObject(Cloudcore.request(method, route, body?.toString() ?: ""))
            else {
                val key = Cloudcore.newRequest()
                try {
                    cancellation.attachAction { Cloudcore.cancelRequest(key) }
                    JSONObject(Cloudcore.requestCancelable(method, route, body?.toString() ?: "", key))
                } finally { cancellation.detachAction(); Cloudcore.cancelRequest(key) }
            }
        }
        catch (error: Exception) { throw CloudDiagnostics.failure("OpenList $route", error) }
        return CloudDiagnostics.checkCore(result, route)
    }
    fun create(credential: OpenListAuth.Credential) = create(credential.provider, credential.addition())
    fun createWebDav(connection: RemoteWebDav.Connection): JSONObject =
        create(CloudDrive.WEBDAV, connection.addition()).apply {
            val fields = connection.metadata()
            fields.keys().forEach { put(it, fields.get(it)) }
        }
    fun webDavConnection(account: JSONObject): RemoteWebDav.Connection {
        require(account.getString("provider") == CloudDrive.WEBDAV && account.getInt("core_id") > 0)
        val storage = request("GET", "/account?id=" + account.getInt("core_id")).getJSONObject("data")
        require(storage.getString("mount_path") == account.getString("mount") && storage.getString("driver") == "WebDav")
        return RemoteWebDav.fromAddition(JSONObject(storage.getString("addition")))
    }
    private fun create(provider: String, addition: JSONObject): JSONObject {
        val mount = "/" + UUID.randomUUID().toString()
        val body = JSONObject().put("mount_path", mount).put("driver", drivers.getValue(provider))
            .put("addition", addition.toString()).put("cache_expiration", 5)
            .put("web_proxy", true).put("webdav_policy", "native_proxy").put("down_proxy_url", "").put("disabled", false)
        var id = 0
        try {
            id = request("POST", "/create", body).getJSONObject("data").getInt("id")
            val account = JSONObject().put("core_id", id).put("mount", mount).put("provider", provider)
            client(account).page("/")
            return account
        } catch (error: Exception) {
            // CreateStorage persists failed initializations too. Remove only this attempted mount.
            if (id == 0) runCatching {
                val all = request("GET", "/accounts?page=1&per_page=10000").getJSONObject("data").getJSONArray("content")
                for (i in 0 until all.length()) if (all.getJSONObject(i).optString("mount_path") == mount) id = all.getJSONObject(i).getInt("id")
            }
            if (id > 0) runCatching { remove(id) }
            throw error
        }
    }
    fun remove(id: Int) { require(id > 0); request("POST", "/delete?id=$id") }
    fun client(account: JSONObject, cancellation: CloudCancellation? = null, folderId: String = ""): Client {
        if (!supported(account.optString("provider")) || !account.has("mount") || account.optInt("core_id") <= 0)
            throw CloudFailure("cloud_login_required")
        return Client(account.getString("mount"), account.getString("provider"), folderId) { method, route, body ->
            request(method, route, body, cancellation)
        }
    }

    internal class Client(private val mount: String, provider: String, private val folderId: String = "",
        private val stream: (String) -> String = { Cloudcore.stream(it) },
        private val now: () -> Long = { System.nanoTime() / 1_000_000 },
        private val call: (String, String, JSONObject?) -> JSONObject = { method, route, body -> request(method, route, body) }) : CloudClient {
        override val canDelete = provider == CloudDrive.OPEN115
        override val canRename = provider == CloudDrive.OPEN115
        private data class Found(val file: CloudFile, val expires: Long)
        private var freshlyFound: Found? = null
        init { require(mount.matches(Regex("/[0-9a-f-]{36}"))) }
        private fun absolutePath(remote: String): String {
            require(remote.startsWith('/') && remote.split('/').none { it == "." || it == ".." || '\u0000' in it || '\\' in it }) {
                "directory.request: invalid remote path"
            }
            return mount + if (remote == "/") "" else remote
        }
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = readPage(path, offset, refresh, "source")
        override fun orderedPage(path: String, offset: Int, refresh: Boolean, order: String): CloudPage = readPage(path, offset, refresh, order)

        private fun readPage(path: String, offset: Int, refresh: Boolean, order: String): CloudPage {
            require(offset >= 0 && offset <= Int.MAX_VALUE - CloudDrive.PAGE_SIZE &&
                (canDelete || offset % CloudDrive.PAGE_SIZE == 0)) { "directory.request: invalid page offset" }
            require(order == "source" || order in CloudSortedPages.ORDERS) { "directory.request: invalid sort order" }
            absolutePath(path)
            val started = System.nanoTime()
            val data = if (canDelete) call("POST", "/list115", JSONObject().put("mount", mount).put("path", path)
                .put("offset", offset).put("refresh", refresh).put("order", order).put("folder_id", folderId)).getJSONObject("data")
            else call("POST", "/directory", JSONObject().put("mount", mount).put("path", path).put("folder_id", folderId)
                .put("offset", offset).put("order", order).put("refresh", refresh)).getJSONObject("data")
            val items = data.optJSONArray("content") ?: org.json.JSONArray()
            val total = data.getInt("total")
            if (canDelete && BuildConfig.DEBUG && PlaybackPrivacy.diagnostics) runCatching {
                val timing = data.optJSONObject("paging")
                val folder = timing?.optString("folder")?.takeIf { it in setOf("provided_id", "path_lookup", "memory", "root") } ?: "unknown"
                android.util.Log.i("QuestCloudPaging", "provider=115 mode=native limit=48 offset=$offset rows=${items.length()} total=$total " +
                    "folder=$folder cache_hit=${timing?.optBoolean("cache_hit") ?: false} resolve_ms=${timing?.optLong("resolve_ms", -1) ?: -1} " +
                    "list_ms=${timing?.optLong("list_ms", -1) ?: -1} elapsed_ms=${(System.nanoTime() - started) / 1_000_000}")
            }
            if (total < -1 || items.length() > CloudDrive.PAGE_SIZE || canDelete && (total < 0 || offset > total ||
                offset.toLong() + items.length() > total || items.length() == 0 && offset < total))
                throw CloudFailure(detail = "directory.page: offset=$offset, total=$total, rows=${items.length()}")
            val files = (0 until items.length()).mapNotNull { i ->
                val item = items.getJSONObject(i)
                val name = item.getString("name")
                // A provider row with no representable path must not break all other rows.
                // Advance the cursor by raw rows below, including these unavailable entries.
                if (!CloudPaths.validName(name)) return@mapNotNull null
                val child = CloudPaths.child(path, name)
                CloudFile(name, item.getBoolean("is_dir"), item.optLong("size"), child,
                    modified = if (item.has("modified_ms")) item.optLong("modified_ms", -1) else runCatching { java.time.OffsetDateTime.parse(item.optString("modified")).toInstant().toEpochMilli() }.getOrDefault(-1),
                    objectId = item.optString("id", child), canDelete = canDelete && item.optBoolean("can_delete"),
                    canRename = canRename && item.optBoolean("can_rename"))
            }
            // 115 can contain different objects at the same path. Keep their metadata visible;
            // object IDs still detect repeated provider rows, and find() rejects ambiguous paths.
            val keys = files.map { if (canDelete) it.objectId else it.name }
            if (keys.toSet().size != files.size) throw CloudFailure(detail = "directory.page: duplicate object IDs")
            val next = if (canDelete) { if (offset + items.length() < total) offset + items.length() else -1 } else data.getInt("next_offset")
            if (!canDelete && next != -1 && next != offset + CloudDrive.PAGE_SIZE) throw CloudFailure(detail = "directory.page: invalid continuation")
            return CloudPage(files, next, total)
        }
        override fun list(path: String): List<CloudFile> {
            val files = ArrayList<CloudFile>()
            val seen = HashSet<String>()
            var offset = 0
            repeat(5000) {
                val page = page(path, offset)
                page.files.forEach { if (!seen.add(if (canDelete) it.objectId else it.name)) throw CloudFailure() }
                files.addAll(page.files)
                if (page.nextOffset < 0) return files
                offset = page.nextOffset
            }
            throw CloudFailure("cloud_folder_too_large")
        }
        fun search(path: String, query: String, scope: String, kind: String, cursor: String, refresh: Boolean, cancellation: CloudCancellation? = null): JSONObject {
            absolutePath(path)
            val body = JSONObject().put("mount", mount).put("path", path).put("query", query)
                .put("scope", scope).put("kind", kind).put("cursor", cursor).put("refresh", refresh)
            return (if (cancellation == null) call("POST", "/search", body) else request("POST", "/search", body, cancellation)).getJSONObject("data")
        }
        fun resolveSearch(path: String, token: String, cancellation: CloudCancellation? = null): JSONObject {
            absolutePath(path)
            val body = JSONObject().put("mount", mount).put("token", token)
            return (if (cancellation == null) call("POST", "/searchresolve", body) else request("POST", "/searchresolve", body, cancellation)).getJSONObject("data")
        }
        override fun find(path: String): CloudFile {
            if (canDelete) {
                synchronized(this) { freshlyFound = null }
                return find115(path).also { synchronized(this) { freshlyFound = Found(it, now() + 10_000) } }
            }
            val matches = list(path.substringBeforeLast('/').ifEmpty { "/" })
                .filter { it.name == path.substringAfterLast('/') }
            if (matches.size > 1) throw CloudFailure("cloud_file_ambiguous")
            return matches.singleOrNull()?.takeIf { !it.folder } ?: throw CloudFailure("cloud_file_missing")
        }
        override fun companions(path: String, pageFiles: List<CloudFile>): List<CloudFile> {
            if (!canDelete) return pageFiles
            absolutePath(path)
            val started = System.nanoTime()
            val data = call("POST", "/companions115", JSONObject().put("mount", mount).put("path", path).put("folder_id", folderId)).getJSONObject("data")
            val rows = data.getJSONArray("content")
            playbackTiming("companion_search rows=${rows.length()} elapsed_ms=${(System.nanoTime() - started) / 1_000_000}")
            val parent = path.substringBeforeLast('/').ifEmpty { "/" }
            return (0 until rows.length()).map { i ->
                val item = rows.getJSONObject(i)
                val name = item.getString("name")
                require(CloudPaths.validName(name))
                CloudFile(name, item.getBoolean("is_dir"), item.optLong("size"), CloudPaths.child(parent, name),
                    modified = item.optLong("modified_ms", -1), objectId = item.getString("id"))
            }
        }
        private fun find115(path: String): CloudFile {
            absolutePath(path)
            val started = System.nanoTime()
            playbackTiming("locate_start parent_hint=${folderId.isNotEmpty()}")
            val response = call("POST", "/stat115", JSONObject().put("mount", mount).put("path", path).put("folder_id", folderId))
            val mode = response.optJSONObject("lookup")?.optString("folder")?.takeIf { it in setOf("provided_id", "memory", "root", "path_lookup") } ?: "unknown"
            playbackTiming("locate folder=$mode elapsed_ms=${(System.nanoTime() - started) / 1_000_000}")
            val item = response.getJSONObject("data")
            if (item.getBoolean("is_dir")) throw CloudFailure("cloud_file_missing")
            return CloudFile(item.getString("name"), false, item.optLong("size"), path,
                modified = item.optLong("modified_ms", -1), objectId = item.getString("id"),
                canDelete = item.optBoolean("can_delete"), canRename = item.optBoolean("can_rename"))
        }
        override fun remove(path: String, file: CloudFile) {
            check(canDelete && file.canDelete && path != "/" && file.id == path)
            call("POST", "/remove115", JSONObject().put("mount", mount).put("path", path).put("id", file.objectId)
                .put("folder", file.folder).put("size", file.size).put("modified", file.modified).put("folder_id", folderId))
        }
        override fun rename(path: String, file: CloudFile, newName: String) {
            check(canRename && file.canRename && path != "/" && file.id == path)
            call("POST", "/rename115", JSONObject().put("mount", mount).put("path", path).put("id", file.objectId)
                .put("folder", file.folder).put("size", file.size).put("modified", file.modified).put("new_name", newName).put("folder_id", folderId))
        }
        override fun freshMatches(parent: String, queries: List<String>): List<CloudFile>? {
            if (!canDelete) return null
            absolutePath(parent)
            val rows = call("POST", "/matches115", JSONObject().put("mount", mount).put("path", parent)
                .put("folder_id", folderId).put("queries", org.json.JSONArray(queries))).getJSONObject("data").getJSONArray("content")
            return (0 until rows.length()).map { i ->
                val item = rows.getJSONObject(i)
                val name = item.getString("name")
                require(CloudPaths.validName(name))
                CloudFile(name, item.getBoolean("is_dir"), item.optLong("size"), CloudPaths.child(parent, name),
                    modified = item.optLong("modified_ms", -1), objectId = item.getString("id"),
                    canDelete = item.optBoolean("can_delete"), canRename = item.optBoolean("can_rename"))
            }
        }
        override fun containsObject(file: CloudFile): Boolean? {
            if (!canDelete) return null
            absolutePath(file.id)
            return call("POST", "/exists115", JSONObject().put("mount", mount).put("path", file.id).put("id", file.objectId))
                .getJSONObject("data").getBoolean("exists")
        }
        override fun resolve(file: CloudFile): CloudLink {
            require(!file.folder && file.size > 0)
            // Consume a single recent find() result instead of searching the same path twice.
            // Listed companions and subsequent link refreshes still verify identity afresh.
            val verified = synchronized(this) {
                val found = freshlyFound
                freshlyFound = null
                found != null && found.file === file && found.expires > now()
            }
            if (canDelete && !verified && find115(file.id).objectId != file.objectId) throw CloudFailure("cloud_file_missing")
            if (canDelete) playbackTiming("prepare reused_lookup=$verified")
            val location = stream(absolutePath(file.id))
            val origin = URI(location)
            return CloudLink(location) { emptyMap() }.also { require(origin.host == "127.0.0.1" && origin.scheme == "http") }
        }
        private fun playbackTiming(fields: String) {
            if (BuildConfig.DEBUG && PlaybackPrivacy.diagnostics) runCatching {
                android.util.Log.i("QuestCloudPlayback", "provider=115 $fields")
            }
        }
    }
    /** The Go proxy owns all provider redirects. Kotlin only connects to this exact capability URL. */
    fun connection(uri: URI, link: CloudLink): HttpURLConnection {
        if (uri.toASCIIString() != link.url || uri.host != "127.0.0.1" || uri.scheme != "http" ||
            uri.rawUserInfo != null || uri.port !in 1..65535) throw CloudFailure()
        return uri.toURL().openConnection() as HttpURLConnection
    }
}
