package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.Context
import android.net.wifi.WifiManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Library sources for the in-headset menu: local MediaStore, DLNA servers and SMB shares.
 * Every request returns an id at once; the result arrives as media_list(id, json) with
 * {source, state: ready|error|denied, entries|servers, error}. */
internal class MediaSources(
    private val host: () -> Activity?,
    private val beforeMutation: (String) -> Unit = {},
    private val emit: (Int, String) -> Unit,
) {
    private val ids = AtomicInteger()
    private val network = Executors.newSingleThreadExecutor { Thread(it, "QuestMediaNetwork") }
    private val cloudNetwork = Executors.newSingleThreadExecutor { Thread(it, "QuestCloudNetwork") }
    private val cloudBrowseRequests = CloudBrowseRequests()
    private val photoDirectoryRequests = CloudBrowseRequests()
    private val local = LocalVideoLibrary(host, emit)
    @Volatile private var fileManagementEnabled = false
    fun setFileManagement(enabled: Boolean) {
        fileManagementEnabled = enabled
        local.setFileManagement(enabled)
    }
    private val dlna by lazy {
        val prefs = (context() ?: error("Activity unavailable")).getSharedPreferences("dlna_sources", Context.MODE_PRIVATE)
        DlnaLibrary({ prefs.getString("catalog", "").orEmpty() }, { check(prefs.edit().putString("catalog", it).commit()) { "Could not save DLNA server" } })
    }
    @Volatile private var server: LocalStreamServer? = null
    private val smb by lazy { SmbLibrary(context() ?: error("Activity unavailable")) { streams() } }
    private val mediaServers = MediaServerLibrary(::context, ::streams, ::nextId, emit = emit)
    fun serverRequest(json: String): Int = mediaServers.request(json)
    fun serverCancel(id: Int) = mediaServers.cancel(id)
    fun releaseMediaStream(uri: String) {
        mediaServers.release(uri)
        server?.revoke(uri)
    }

    private fun context(): Context? = host()?.applicationContext
    @Synchronized fun streams(): LocalStreamServer = server ?: LocalStreamServer().also { server = it }

    fun releasePhotoStream(uri: String) { if (uri.isNotEmpty()) server?.revoke(uri) }
    fun streamProgress(uri: String): TransferMeter.Snapshot? = server?.progress(uri)
    fun streamFailure(uri: String): PlaybackFailure? = server?.failure(uri)

    fun nextId(): Int = ids.incrementAndGet()
    /** Main thread: may show the media permission request. path "" lists the storage volumes. */
    fun browseLocal(id: Int, path: String) = local.browse(id, path)
    /** Main thread: requests legacy read access or opens settings, emitting local_access events. */
    fun grantAllFiles() = local.grantAllFiles()
    fun refreshLocalStorage() = local.refreshStorage()
    fun openLocalEjectSettings(id: Int, path: String) = local.openEjectSettings(id,path)
    fun onPermissionResult(requestCode: Int, granted: Boolean) = local.onPermissionResult(requestCode, granted)

    @Volatile private var stopped = false
    private val cloudAccountChanged: () -> Unit = {
        if (!stopped) emit(0, JSONObject().put("source", "cloud").put("state", "accounts_changed").toString())
    }
    init {
        CloudAccountChanges.subscribe(cloudAccountChanged)
        DlnaClient.log = { android.util.Log.i("QuestDlna", it) }
        cloudNetwork.execute {
            if (!stopped) runCatching { context()?.let { CloudWebDav.restore(it) } }
            if (stopped) CloudWebDav.stop()
        }
    }

    fun dlnaDiscover(): Int = run("dlna") {
        val lock = (context()?.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.createMulticastLock("QuestDlna")
        lock?.setReferenceCounted(false)
        runCatching { lock?.acquire() }
        try { JSONObject().put("servers", dlna.refresh()) }
        finally { if (lock?.isHeld == true) lock.release() }
    }

    fun dlnaServers(): Int = run("dlna") { JSONObject().put("servers", dlna.servers()) }
    fun dlnaSave(json: String): Int = run("dlna") {
        JSONObject().put("saved_id", dlna.save(JSONObject(json))).put("servers", dlna.servers())
    }
    fun dlnaRemove(id: String): Int = run("dlna") { dlna.remove(id); JSONObject().put("servers", dlna.servers()) }

    fun dlnaBrowse(serverId: String, objectId: String): Int = run("dlna") {
        JSONObject().put("server_id", serverId).put("object_id", objectId)
            .put("entries", dlna.browse(serverId, objectId.ifEmpty { "0" }))
    }

    fun smbServers(): Int = run("smb") { JSONObject().put("servers", smb.serversJson()) }
    fun smbDiscover(): Int = run("smb") {
        // WS-Discovery answers arrive as multicast-addressed traffic too; Wi-Fi drops it without the lock.
        val lock = (context()?.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.createMulticastLock("QuestSmb")
        lock?.setReferenceCounted(false); lock?.acquire()
        try { JSONObject().put("discovered", smb.discover()) } finally { lock?.release() }
    }
    fun smbSave(request: String): Int = run("smb") {
        JSONObject().put("saved_id", smb.save(JSONObject(request))).put("servers", smb.serversJson())
    }
    fun smbRemove(id: String): Int = run("smb") { smb.remove(id); JSONObject().put("servers", smb.serversJson()) }
    fun smbBrowse(serverId: String, path: String): Int = run("smb") {
        JSONObject().put("server_id", serverId).put("path", path).put("entries", smb.browse(serverId, path))
    }

    fun cloudBrowse(path: String, refresh: Boolean, offset: Int = 0, order: String = ""): Int {
        val id = nextId()
        cloudBrowseRequests.submit(id, { cancellation ->
            val result = try {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.browse(path, refresh, offset, cancellation, order).put("state", "ready")
            } catch (error: Exception) {
                CloudDiagnostics.response(error, "cloud.browse")
            }
            result.put("source", "cloud").put("path", path).put("offset", offset).put("order", order).toString()
        }, emit)
        return id
    }
    fun cloudCancel(id: Int) = cloudBrowseRequests.cancel(id)
    fun cloudSearch(path: String, query: String, scope: String, kind: String, cursor: String, refresh: Boolean): Int {
        val id = nextId()
        cloudBrowseRequests.submit(id, { cancellation ->
            val result = try {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.search(path, query, scope, kind, cursor, refresh, cancellation).put("state", "ready")
            } catch (error: Exception) { JSONObject().put("state", "error").put("error", error.message ?: "Cloud search failed") }
            result.put("source", "cloud_search").put("path", path).put("query", query).put("scope", scope)
                .put("kind", kind).put("cursor", cursor).toString()
        }, emit)
        return id
    }
    fun cloudSearchResolve(path: String, token: String): Int {
        val id = nextId()
        cloudBrowseRequests.submit(id, { cancellation ->
            val result = try {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                JSONObject().put("entry", CloudLibrary.resolveSearch(path, token, cancellation)).put("state", "ready")
            } catch (error: Exception) { JSONObject().put("state", "error").put("error", error.message ?: "Cloud search failed") }
            result.put("source", "cloud_search_resolve").put("path", path).put("token", token).toString()
        }, emit)
        return id
    }
    fun photoDirectoryPage(path: String, offset: Int, order: String): Int {
        val id = nextId()
        photoDirectoryRequests.submit(id, { cancellation ->
            val result = try {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.browse(path, false, offset, cancellation, order).put("state", "ready")
            } catch (_: Exception) { JSONObject().put("state", "error").put("error", "PHOTO_DIRECTORY_UNAVAILABLE") }
            result.put("path", path).put("offset", offset).put("order", order).toString()
        }, emit)
        return id
    }
    fun photoDirectoryCancel(id: Int) = photoDirectoryRequests.cancel(id)

    fun cloudRemove(id: String): Int = run("cloud") {
        CloudLibrary.start(context() ?: error("Activity unavailable"))
        CloudLibrary.remove(id)
        JSONObject()
    }

    fun renameFile(json: String, prepare: Boolean): Int {
        val id = nextId()
        network.execute {
            var request = JSONObject()
            val result = try {
                request = JSONObject(json)
                val uri = request.getString("uri")
                check(fileManagementEnabled) { "File management is off" }
                if (!prepare) {
                    val readers = linkedSetOf(uri)
                    request.optJSONArray("related_uris")?.let { related ->
                        require(related.length() <= 65)
                        for (i in 0 until related.length()) readers.add(related.getString(i))
                    }
                    readers.forEach(beforeMutation)
                    check(fileManagementEnabled) { "File management is off" }
                }
                val result = when {
                    uri.startsWith("file://") -> local.renameFile(request, prepare)
                    uri.startsWith("smb://") -> smb.renameFile(request, prepare)
                    uri.startsWith("cloud://") -> {
                        CloudLibrary.start(context() ?: error("Activity unavailable"))
                        CloudLibrary.renameFile(request, prepare) { check(fileManagementEnabled) { "File management is off" } }
                    }
                    else -> error("Rename unavailable for this source")
                }
                if (!result.has("state")) result.put("state", "ready") else result
            } catch (error: Exception) { JSONObject().put("state", "error").put("error", error.message ?: "Rename failed; check the folder") }
            if (!stopped) emit(id, result.put("source", "file_rename").put("uri", request.optString("uri")).put("prepare", prepare).toString())
        }
        return id
    }

    fun deleteFile(json: String, inspect: Boolean = false, prepare: Boolean = false): Int {
        val id = nextId()
        network.execute {
            var request = JSONObject()
            var sent = false
            val result = try {
                request = JSONObject(json)
                val uri = request.getString("uri")
                require(uri.startsWith("file://") || uri.startsWith("smb://") || uri.startsWith("cloud://"))
                if (!inspect) check(fileManagementEnabled) { "File management is off" }
                if (!inspect && !prepare) { beforeMutation(uri); check(fileManagementEnabled) { "File management is off" } }
                // CloudDeletion handles uncertainty after its single write; exceptions here precede it.
                sent = !inspect && !prepare && !uri.startsWith("cloud://")
                val result = when {
                    uri.startsWith("file://") -> local.deleteFile(request, inspect, prepare)
                    uri.startsWith("smb://") -> smb.deleteFile(request, inspect, prepare)
                    else -> {
                        CloudLibrary.start(context() ?: error("Activity unavailable"))
                        CloudLibrary.deleteFile(request, inspect, prepare) { check(fileManagementEnabled) { "File management is off" } }
                    }
                }
                if (!result.has("state")) result.put("state", "ready") else result
            } catch (error: Exception) {
                // A transport error after dispatch is ambiguous. Never silently resend a delete.
                val smbError = error as? org.codelibs.jcifs.smb.impl.SmbException
                val definite = error.message != "Delete result needs checking" && (error is IllegalArgumentException || error is IllegalStateException || error is android.system.ErrnoException ||
                    smbError?.ntStatus in setOf(0xC0000022.toInt(), 0xC0000043.toInt(), 0xC0000121.toInt(), 0xC00000BA.toInt()))
                JSONObject().put("state", if (sent && !definite) "uncertain" else "error")
                    .put("error", if (error is CloudFailure && !sent) error.message else if (smbError != null && definite) "File deletion permission denied" else if (definite) error.message ?: "File deletion failed" else "Delete result needs checking")
            }
            if (!stopped) emit(id, result.put("source", "file_delete").put("uri", request.optString("uri")).put("inspect", inspect).toString())
        }
        return id
    }

    /** MPV-playable location for a library URI; blocks (SMB connects). Worker threads only. */
    private val strm = StrmResolver(::readStrm, ::isStrm) { origin, target ->
        if (target.startsWith("smb://")) smb.strmTarget(target, origin) else target
    }

    private fun isStrm(uri: String): Boolean {
        if (StrmFile.location(uri)) return true
        val source = android.net.Uri.parse(uri)
        if (source.scheme != "content") return false
        return context()?.contentResolver?.query(source, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            it.moveToFirst() && StrmFile.named(it.getString(0).orEmpty())
        } == true
    }

    private fun readStrm(uri: String): StrmDocument {
        val source = android.net.Uri.parse(uri)
        val bytes = when (source.scheme) {
            "file" -> java.io.File(source.path ?: throw StrmFailure("STRM_READ_FAILED")).inputStream().use(StrmFile::read)
            "content" -> (context()?.contentResolver?.openInputStream(source) ?: throw StrmFailure("STRM_READ_FAILED")).use(StrmFile::read)
            "smb" -> smb.readStrm(uri)
            "cloud" -> {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                StrmFile.read(CloudLibrary.dav.source(CloudPaths.path(uri)))
            }
            "http", "https" -> return StrmHttp.read(uri)
            else -> throw StrmFailure("STRM_UNSUPPORTED_ADDRESS")
        }
        return StrmDocument(bytes, if (source.scheme == "smb") smb.strmOrigin(uri) else uri)
    }

    fun playable(uri: String): String {
        val target = strm.resolve(uri)
        return try { directPlayable(target) }
        catch (error: Exception) {
            if (target != uri) throw StrmFailure("STRM_TARGET_UNAVAILABLE", error)
            throw error
        }
    }

    private fun directPlayable(uri: String): String = when {
        (uri.startsWith("http://") || uri.startsWith("https://")) && java.net.URI(uri).path.orEmpty().endsWith(".iso", true) -> {
            // Blu-ray preflight uses FFmpeg's independent HTTP reader; route it through Android TLS too.
            val source = HttpRangeStreamSource.remote(java.net.URI(uri))
            try { streams().publish(source, java.net.URI(uri).path.substringAfterLast('/')) }
            catch (error: Exception) { source.close(); throw error }
        }
        uri.startsWith("medialib://") -> mediaServers.playable(uri)
        uri.startsWith("smb://") -> smb.stream(uri)
        uri.startsWith("cloud://") -> {
            CloudLibrary.start(context() ?: error("Activity unavailable"))
            CloudLibrary.playable(uri, streams())
        }
        else -> uri
    }

    /** Extra M4A tracks beside a video (clone voice first). Local files, the MediaStore library and
     * SMB; DLNA servers expose no sibling files. Blocks; worker threads only. Never throws. */
    fun sidecarAudio(uri: String): List<SidecarAudio.Track> = try {
        val source = android.net.Uri.parse(uri)
        when (source.scheme) {
            "file" -> source.path?.let { SidecarAudio.forFile(it) } ?: emptyList()
            "content" -> context()?.let { SidecarAudio.forMediaStore(it, source) } ?: emptyList()
            "smb" -> smb.sidecarAudio(uri)
            "medialib" -> mediaServers.sidecarAudio(uri)
            "cloud" -> {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.sidecarAudio(uri, streams())
            }
            else -> emptyList()
        }
    } catch (error: Throwable) {
        android.util.Log.w("QuestSidecarAudio", "Sidecar audio lookup failed: ${error.javaClass.simpleName}")
        emptyList()
    }

    fun sidecarSubtitles(uri: String): List<SidecarSubtitles.Track> = try {
        when {
            uri.startsWith("file://") -> SidecarSubtitles.forLocal(java.io.File(android.net.Uri.parse(uri).path ?: ""))
            uri.startsWith("smb://") -> smb.sidecarSubtitles(uri)
            uri.startsWith("medialib://") -> mediaServers.sidecarSubtitles(uri)
            uri.startsWith("http://") || uri.startsWith("https://") -> SidecarSubtitles.forDlna(dlna.subtitles(uri)) { source, name -> streams().publish(source, name) }
            uri.startsWith("cloud://") -> {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.sidecarSubtitles(uri, streams())
            }
            else -> emptyList()
        }
    } catch (error: Exception) {
        android.util.Log.w("QuestSubtitles", "Network subtitle lookup failed: ${error.javaClass.simpleName}")
        emptyList()
    }

    private fun run(source: String, block: () -> JSONObject): Int {
        val id = ids.incrementAndGet()
        (if (source == "cloud") cloudNetwork else network).execute {
            val result = try { block().put("state", "ready") }
            catch (error: Throwable) { JSONObject().put("state", "error").put("error", error.message ?: error.javaClass.simpleName) }
            emit(id, result.put("source", source).toString())
        }
        return id
    }

    fun close() {
        stopped = true
        CloudAccountChanges.unsubscribe(cloudAccountChanged)
        mediaServers.close()
        cloudBrowseRequests.close(); photoDirectoryRequests.close()
        network.shutdownNow(); cloudNetwork.shutdownNow(); local.close()
        CloudLibrary.stopStreams()
        CloudWebDav.stop()
        server?.close(); server = null
    }
}
