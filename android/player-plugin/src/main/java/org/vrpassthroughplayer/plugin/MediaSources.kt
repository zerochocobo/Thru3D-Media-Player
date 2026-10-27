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
    private val usb: UsbStorage = UsbStorage(host, emit) { refreshLocalStorage() }
    private val local: LocalVideoLibrary = LocalVideoLibrary(host, emit, usb)
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
    fun clearPlaybackReferences() { network.execute { runCatching { dlna.clearPlaybackReferences() } } }
    fun releaseMediaStream(uri: String) {
        usb.forgetStream(uri)
        mediaServers.release(uri)
        server?.revoke(uri)
    }

    private fun context(): Context? = host()?.applicationContext
    @Synchronized fun streams(): LocalStreamServer = server ?: LocalStreamServer().also { server = it }

    fun releasePhotoStream(uri: String) { if (uri.isNotEmpty()) { usb.forgetStream(uri); server?.revoke(uri) } }
    fun streamProgress(uri: String): TransferMeter.Snapshot? = server?.progress(uri)
    fun streamFailure(uri: String): PlaybackFailure? = server?.failure(uri)
    fun prepareListening(uri: String) { server?.shareReadAhead(uri) }
    fun retainListeningAudio(uri: String, ranges: LongArray) { server?.retainAudio(uri,ranges) }
    fun listeningInput(uri: String): ListeningInput? = server?.listeningInput(uri)
    fun retainListening(uri: String): String? = server?.retain(uri)
    fun enableInterleaveCache(uri: String, audioChunks: List<AudioReadSpan>): Boolean = server?.enableInterleaveCache(uri, audioChunks) ?: false
    // Non-cloud views (SMB) are owned by the player's network lease, released like the parent.
    fun playbackView(uri: String, layout: Mp4PlaybackLayout): String? = server?.let {
        if (it.cloudBacked(uri)) CloudLibrary.playbackView(uri, layout, it) else it.playbackView(uri, layout)
    }
    fun finishIsoPreflight(uri: String) { server?.finishIsoPreflight(uri) }

    fun nextId(): Int = ids.incrementAndGet()
    /** Main thread: may show the media permission request. path "" lists the storage volumes. */
    fun browseLocal(id: Int, path: String, subtitlesOnly: Boolean = false) = local.browse(id, path, subtitlesOnly)
    /** Main thread: requests legacy read access or opens settings, emitting local_access events. */
    fun grantAllFiles() = local.grantAllFiles()
    fun grantLocalDirectory(path: String) = local.grantDirectory(path)
    fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) = local.onActivityResult(requestCode, resultCode, data)
    fun refreshLocalStorage(): Unit = local.refreshStorage()
    fun stopLocalStorage(id: Int, path: String) {
        if (path.startsWith("usb://")) usb.stop(id, path) else local.stopStorage(id,path)
    }
    fun onPermissionResult(requestCode: Int, granted: Boolean) = local.onPermissionResult(requestCode, granted)

    @Volatile private var stopped = false
    private val cloudAccountChanged: () -> Unit = {
        if (!stopped) emit(0, JSONObject().put("source", "cloud").put("state", "accounts_changed").toString())
    }
    init {
        CloudAccountChanges.subscribe(cloudAccountChanged)
        DlnaClient.log = { if (PlaybackPrivacy.diagnostics) android.util.Log.i("QuestDlna", it) }
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
    fun smbBrowse(serverId: String, path: String, subtitlesOnly: Boolean = false): Int = run("smb") {
        JSONObject().put("server_id", serverId).put("path", path).put("entries", smb.browse(serverId, path, subtitlesOnly))
    }

    fun cloudBrowse(path: String, refresh: Boolean, offset: Int = 0, order: String = "", folderId: String = "", subtitlesOnly: Boolean = false, pageSize: Int = CloudDrive.PAGE_SIZE): Int {
        val id = nextId()
        cloudBrowseRequests.submit(id, { cancellation ->
            val result = try {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.browse(path, refresh, offset, cancellation, order, folderId, subtitlesOnly, pageSize).put("state", "ready")
            } catch (error: Exception) {
                CloudDiagnostics.response(error, "cloud.browse")
            }
            if (!result.has("order")) result.put("order", order)
            result.put("source", "cloud").put("path", path).put("offset", offset).toString()
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
            "usb" -> StrmFile.read(usb.source(uri))
            "cloud" -> {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                StrmFile.read(CloudLibrary.dav.source(CloudPaths.path(uri)))
            }
            "http", "https" -> return StrmHttp.read(uri)
            else -> throw StrmFailure("STRM_UNSUPPORTED_ADDRESS")
        }
        return StrmDocument(bytes, if (source.scheme == "smb") smb.strmOrigin(uri) else uri)
    }

    fun audioDownload(uri: String): String = if (uri.startsWith("cloud://")) {
        CloudLibrary.start(context() ?: error("Activity unavailable"))
        CloudLibrary.audioDownload(uri, streams())
    } else playable(uri)

    fun voiceReference(uri: String): String {
        require(uri.startsWith("cloud://"))
        CloudLibrary.start(context() ?: error("Activity unavailable"))
        // A few seconds of reference audio must not hold full-file CDN bodies
        // alongside playback and FFmpeg's next seek connection. Keep each range
        // large enough for MP4's indexed read-ahead: 64 KiB caused hundreds of
        // round trips and hit the reference reader's 30-second deadline.
        return CloudLibrary.audioDownload(uri,streams(),1024*1024L)
    }

    fun playable(uri: String): String {
        val target = strm.resolve(uri)
        return try { directPlayable(target) }
        catch (error: Exception) {
            if (target != uri) throw StrmFailure("STRM_TARGET_UNAVAILABLE", error)
            throw error
        }
    }

    fun archiveStream(uri: String, cache: SmallRarCache? = null): String {
        val app = context() ?: error("Archive unavailable")
        return when (android.net.Uri.parse(uri).scheme) {
            "file", "content" -> {
                val source = ArchiveFileSource(app, uri)
                try { streams().publish(source, "archive.bin") } catch (e: Exception) { source.close(); throw e }
            }
            "cloud" -> { CloudLibrary.start(app); CloudLibrary.audioDownload(uri, streams(), 1024*1024L, archiveReading = true, archiveCache = cache) }
            "smb", "usb" -> directPlayable(uri)
            "dlna", "http", "https" -> {
                val address = if (uri.startsWith("dlna://")) dlna.playable(uri) else uri
                val source = HttpRangeStreamSource.remote(java.net.URI(address)).boundedRanges(1024*1024L).forArchiveReading()
                try { streams().publish(source, "archive.bin") } catch (e: Exception) { source.close(); throw e }
            }
            else -> error("Archive source is not supported")
        }
    }

    fun cachedArchive(uri: String): Boolean = streams().cachedArchive(uri)
    fun hasPhotoStream(uri: String): Boolean = server?.hasSource(uri) == true

    /** Capture owns its reader; opening it must not revoke playback or its subtitle/audio leases. */
    fun capturePlayable(uri: String): String {
        val target = strm.resolve(uri)
        return when {
            target.startsWith("medialib://") -> mediaServers.playable(target, true)
            // CloudLibrary.playable() switches the active video and calls stopStreams().
            // Use the existing independent download lease, including cloud targets in STRM.
            target.startsWith("cloud://") -> audioDownload(target)
            else -> directPlayable(target)
        }
    }
    fun captureAudio(uri: String, reader: String): List<SidecarAudio.Track> =
        mediaServers.captureAudio(reader) ?: sidecarAudio(uri)

    private fun directPlayable(uri: String): String = when {
        uri.startsWith("dlna://") -> dlna.playable(uri)
        (uri.startsWith("http://") || uri.startsWith("https://")) && java.net.URI(uri).path.orEmpty().endsWith(".iso", true) -> {
            // Blu-ray preflight uses FFmpeg's independent HTTP reader; route it through Android TLS too.
            val source = HttpRangeStreamSource.remote(java.net.URI(uri))
            try { streams().publish(source, java.net.URI(uri).path.substringAfterLast('/')) }
            catch (error: Exception) { source.close(); throw error }
        }
        uri.startsWith("medialib://") -> mediaServers.playable(uri)
        uri.startsWith("smb://") -> smb.stream(uri)
        uri.startsWith("usb://") -> usb.stream(uri, streams())
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
            "content" -> if (local.documents.owns(uri)) {
                val rows = local.documents.siblings(uri)
                val entries = (0 until rows.length()).map(rows::getJSONObject).filter { !it.optBoolean("container") }.associateBy { it.getString("title") }
                val video = StorageDocumentPolicy.parse(uri).document.path.substringAfterLast('/')
                SidecarAudio.select(video, entries.keys).mapNotNull { name ->
                    val fd = runCatching { context()?.contentResolver?.openFileDescriptor(android.net.Uri.parse(entries.getValue(name).getString("uri")), "r") }.getOrNull() ?: return@mapNotNull null
                    SidecarAudio.Track("fd://${fd.fd}", SidecarAudio.title(video, name), fd)
                }
            } else context()?.let { SidecarAudio.forMediaStore(it, source) } ?: emptyList()
            "smb" -> smb.sidecarAudio(uri)
            "usb" -> {
                val rows = usb.siblings(uri)
                val names = (0 until rows.length()).map(rows::getJSONObject).filter { !it.optBoolean("container") }.map { it.getString("title") }
                val video = source.lastPathSegment.orEmpty()
                SidecarAudio.select(video, names).map { name -> SidecarAudio.Track(usb.stream(usb.sibling(uri,name),streams()),SidecarAudio.title(video,name)) }
            }
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
            local.documents.owns(uri) -> {
                val rows = local.documents.siblings(uri)
                val entries = (0 until rows.length()).map(rows::getJSONObject).filter { !it.optBoolean("container") }.associateBy { it.getString("title") }
                val video = StorageDocumentPolicy.parse(uri).document.path.substringAfterLast('/')
                SidecarSubtitles.select(video, entries.keys).mapNotNull { name -> runCatching {
                    val item = entries.getValue(name)
                    val source = DocumentStreamSource(context() ?: error("Activity unavailable"), android.net.Uri.parse(item.getString("uri")))
                    try { SidecarSubtitles.Track(streams().publish(source, name), name) } catch (error: Exception) { source.close(); throw error }
                }.getOrNull() }
            }
            uri.startsWith("smb://") -> smb.sidecarSubtitles(uri)
            uri.startsWith("usb://") -> {
                val rows = usb.siblings(uri)
                val names = (0 until rows.length()).map(rows::getJSONObject).filter { !it.optBoolean("container") }.map { it.getString("title") }
                SidecarSubtitles.select(android.net.Uri.parse(uri).lastPathSegment.orEmpty(),names).map { name -> SidecarSubtitles.Track(usb.stream(usb.sibling(uri,name),streams()),name) }
            }
            uri.startsWith("medialib://") -> mediaServers.sidecarSubtitles(uri)
            uri.startsWith("dlna://") -> SidecarSubtitles.forDlna(dlna.subtitles(dlna.playable(uri))) { source, name -> streams().publish(source, name) }
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

    /** Raw sibling names only; no media-library filter, network resolution or stream publication. */
    fun subtitleFiles(uri: String): List<String> {
        require(SidecarSubtitles.supportsDirectory(uri))
        val names = when {
            uri.startsWith("file://") -> {
                val folder = java.io.File(android.net.Uri.parse(uri).path ?: "").parentFile ?: error("No parent folder")
                val children = folder.listFiles() ?: throw java.nio.file.AccessDeniedException("subtitle folder")
                children.filter { it.isFile && it.canRead() && it.length() > 0 && it.canonicalFile.parentFile == folder.canonicalFile }.map { it.name }
            }
            local.documents.owns(uri) -> {
                val rows = local.documents.siblings(uri)
                (0 until rows.length()).map(rows::getJSONObject).filter { !it.optBoolean("container") && it.optLong("size", -1) != 0L }.map { it.getString("title") }
            }
            uri.startsWith("usb://") -> {
                val rows = usb.siblings(uri)
                (0 until rows.length()).map(rows::getJSONObject).filter { !it.optBoolean("container") && it.optLong("size", -1) != 0L }.map { it.getString("title") }
            }
            uri.startsWith("smb://") -> return smb.subtitleFiles(uri)
            else -> {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                return CloudLibrary.subtitleFiles(uri)
            }
        }
        return SidecarSubtitles.files(names)
    }

    fun subtitleIdentity(uri: String): String = if (uri.startsWith("usb://")) usb.subtitleIdentity(uri) else ""

    /** A picker-selected subtitle owns an independent lease, never playable()'s video lease. */
    fun openSubtitleUri(uri: String): SidecarSubtitles.Track {
        val name = SidecarSubtitles.sourceName(uri)
        if (uri.startsWith("cloud://")) {
            CloudLibrary.start(context() ?: error("Activity unavailable"))
            return SidecarSubtitles.Track(CloudLibrary.audioDownload(uri, streams()), name)
        }
        if (uri.startsWith("smb://")) {
            val at = java.net.URI(uri)
            return openSubtitleFile("smb://${at.rawAuthority}${at.path}", name)
        }
        return openSubtitleFile(uri, name)
    }

    /** Revalidate against the original video's parent, never a caller-supplied path or proxy URL. */
    fun openSubtitleFile(uri: String, name: String): SidecarSubtitles.Track {
        require(SidecarSubtitles.supportsDirectory(uri) && SidecarSubtitles.supportedFile(name))
        return when {
            uri.startsWith("file://") -> {
                val folder = java.io.File(android.net.Uri.parse(uri).path ?: "").parentFile ?: error("No parent folder")
                val file = java.io.File(folder, name)
                require(file.isFile && file.canRead() && file.length() > 0 && file.canonicalFile.parentFile == folder.canonicalFile)
                SidecarSubtitles.Track(file.absolutePath, name)
            }
            local.documents.owns(uri) -> {
                val rows = local.documents.siblings(uri)
                val item = (0 until rows.length()).map(rows::getJSONObject).single { !it.optBoolean("container") && it.getString("title") == name }
                val source = DocumentStreamSource(context() ?: error("Activity unavailable"), android.net.Uri.parse(item.getString("uri")))
                try { SidecarSubtitles.Track(streams().publish(source, name), name) } catch (error: Exception) { source.close(); throw error }
            }
            uri.startsWith("usb://") -> {
                require(name in subtitleFiles(uri))
                SidecarSubtitles.Track(usb.stream(usb.sibling(uri, name), streams()), name)
            }
            uri.startsWith("smb://") -> smb.openSubtitleFile(uri, name)
            else -> {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.openSubtitleFile(uri, name, streams())
            }
        }
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
        network.shutdownNow(); cloudNetwork.shutdownNow(); local.close(); usb.close()
        CloudLibrary.stopStreams()
        CloudWebDav.stop()
        server?.close(); server = null
    }
}
