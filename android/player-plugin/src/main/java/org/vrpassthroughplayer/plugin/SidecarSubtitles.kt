package org.vrpassthroughplayer.plugin

import java.net.HttpURLConnection
import java.net.URI
import java.io.File

/** Text subtitles associated with a video. Keep discovery separate from media filtering:
 * SRT/ASS files should become CC tracks, not playable library entries. */
internal object SidecarSubtitles {
    data class Track(val location: String, val title: String, val language: String = "")
    private const val automaticTrackLimit = 8 // MPV startup accepts eight external tracks.
    // .sub is ambiguous: MPV's detected codec decides whether it is text or bitmap.
    private val extensions = setOf("srt", "ass", "ssa", "vtt", "smi", "sami", "sub")

    fun supportedFile(name: String): Boolean = name.length in 1..1024 && !name.startsWith('.') &&
        name.none { it == '/' || it == '\\' || it.code < 32 } &&
        name.substringAfterLast('.', "").lowercase() in extensions

    /** Manual discovery has no basename restriction or automatic-track limit. */
    fun files(names: Collection<String>): List<String> = names.filter(::supportedFile).distinct()
        .sortedWith(compareBy<String> { it.lowercase() }.thenBy { it })

    fun directoryEntries(entries: org.json.JSONArray): org.json.JSONArray = org.json.JSONArray().apply {
        for (index in 0 until entries.length()) {
            val row = entries.getJSONObject(index)
            if (row.optBoolean("container") || supportedFile(row.optString("title"))) put(row)
        }
    }

    fun sourceName(uri: String): String {
        val at = URI(uri)
        require(uri.length <= 4096 && at.rawQuery == null && at.rawFragment == null && at.rawUserInfo == null)
        require(at.scheme in setOf("file", "smb", "cloud", "usb", "content"))
        if (at.scheme == "file") require(at.rawAuthority.isNullOrEmpty())
        val path = if (at.scheme == "content") StorageDocumentPolicy.parse(uri).document.path else at.path.orEmpty()
        require(path.split('/').none { it == "." || it == ".." || '\\' in it || it.any { c -> c.code < 32 } })
        val name = path.substringAfterLast('/')
        require(supportedFile(name))
        return name
    }

    fun supportsDirectory(uri: String): Boolean = when (uri.substringBefore("://", "")) {
        "file", "usb", "smb", "cloud" -> true
        "content" -> runCatching { StorageDocumentPolicy.parse(uri); true }.getOrDefault(false)
        else -> false
    }

    fun select(video: String, names: Collection<String>): List<String> {
        val stem = video.substringBeforeLast('.')
        if (stem.isEmpty()) return emptyList()
        return names.filter {
            '/' !in it && '\\' !in it && it.startsWith("$stem.", ignoreCase = true) &&
                it.substringAfterLast('.', "").lowercase() in extensions
        }.sortedWith(compareBy({ !it.substringBeforeLast('.').equals(stem, ignoreCase = true) },
            { when (it.substringAfterLast('.').lowercase()) { "srt" -> 0; "ass" -> 1; else -> 2 } },
            { it.lowercase() })).take(automaticTrackLimit)
    }

    fun forLocal(video: File): List<Track> {
        val directory = video.parentFile ?: return emptyList()
        return forDirectoryVideo(video.name,
            list = { path -> (if (path.isEmpty()) directory else File(directory, path)).list()?.toList().orEmpty() },
            isDirectory = { parent, entry ->
                val folder = child(directory, parent, entry)
                folder.isDirectory && staysInDirectory(folder)
            },
            open = { parent, name ->
                val file = child(directory, parent, name)
                if (file.isFile && file.canRead() && file.length() > 0 && (parent.isEmpty() || staysInDirectory(file)))
                    Track(file.absolutePath, name) else null
            })
    }

    private fun child(root: File, parent: String, name: String): File =
        File(if (parent.isEmpty()) root else File(root, parent), name)

    private fun staysInDirectory(file: File): Boolean {
        val parent = file.parentFile ?: return false
        return file.canonicalFile == File(parent.canonicalFile, file.name)
    }

    /** Keep same-directory matches first. The exact episode directory determines the
     * ownership of language-only filenames such as 3_English.srt. */
    fun forDirectoryVideo(video: String, list: (String) -> List<String>,
                          isDirectory: (String, String) -> Boolean, open: (String, String) -> Track?): List<Track> {
        val root = list("")
        val tracks = select(video, root).mapNotNull { name -> runCatching { open("", name) }.getOrNull() }.toMutableList()
        val stem = video.substringBeforeLast('.')
        if (tracks.size == automaticTrackLimit || stem.isBlank() || stem == "." || stem == ".." ||
            stem.any { it == '/' || it == '\\' || it.code < 32 }) return tracks

        // Optional lookups may fail without discarding the same-directory tracks.
        val (folder, names) = runCatching {
            val subs = matchingDirectory(root, "Subs") { isDirectory("", it) } ?: return tracks
            val episode = matchingDirectory(list(subs), stem) { isDirectory(subs, it) } ?: return tracks
            val path = "$subs/$episode"
            path to files(list(path))
        }.getOrNull() ?: return tracks
        val titles = tracks.mapTo(HashSet()) { it.title.lowercase() }
        for (name in names) {
            val key = name.lowercase()
            if (key in titles) continue
            val track = runCatching { open(folder, name) }.getOrNull() ?: continue
            tracks.add(track)
            titles.add(key)
            if (tracks.size == automaticTrackLimit) break
        }
        return tracks
    }

    private fun matchingDirectory(entries: List<String>, name: String, isDirectory: (String) -> Boolean): String? {
        val matches = entries.filter { it.removeSuffix("/").equals(name, ignoreCase = true) && isDirectory(it) }
            .map { it.removeSuffix("/") }.distinct()
        return matches.firstOrNull { it == name } ?: matches.singleOrNull()
    }

    fun forCloud(path: String, pageFiles: List<CloudFile>, publish: (CloudFile) -> String): List<Track> {
        // Filter provided candidates only; the playback snapshot owns the discovery policy.
        val files = pageFiles.groupBy { it.name }.filterValues { it.size == 1 }
            .mapValues { it.value.single() }.filterValues { !it.folder && it.size > 0 }
        return select(path.substringAfterLast('/'), files.keys).mapNotNull { name ->
            // One inaccessible subtitle must not hide other tracks or fail video playback.
            runCatching { Track(publish(files.getValue(name)), name) }.getOrNull()
        }
    }

    fun forServer(http: MediaServerHttp, captions: List<MediaSubtitleLink>,
        publish: (StreamSource, String) -> String): List<Track> = captions.take(8).mapIndexedNotNull { index, caption ->
        runCatching {
            require(caption.extension in extensions)
            val bytes = http.bytes(caption.url, 4 * 1024 * 1024, textSubtitle = true)
            require(bytes.isNotEmpty())
            validate(bytes)
            val source = Bytes(bytes)
            try { Track(publish(source, "subtitle-$index.${caption.extension}"), caption.title, caption.language) }
            catch (error: Exception) { source.close(); throw error }
        }.getOrNull()
    }

    fun forDlna(captions: List<MediaSubtitleLink>, publish: (StreamSource, String) -> String): List<Track> =
        captions.take(8).mapIndexedNotNull { index, caption ->
            runCatching {
                require(caption.extension in extensions)
                val bytes = download(caption.url)
                validate(bytes)
                val source = Bytes(bytes)
                // MPV exposes this filename separately from the display title (e.g. "zh · SRT").
                // Keep it through the proxy so automatic matching still works after history replay.
                val filename = caption.url.path.substringAfterLast('/').takeIf {
                    it.isNotBlank() && '/' !in it && '\\' !in it && it.substringAfterLast('.', "").lowercase() in extensions
                } ?: "subtitle-$index.${caption.extension}"
                try { Track(publish(source, filename), caption.title, caption.language) }
                catch (error: Exception) { source.close(); throw error }
            }.getOrNull()
        }

    private fun validate(bytes: ByteArray) {
        require(bytes.isNotEmpty())
        val prefix = bytes.copyOf(minOf(256, bytes.size)).toString(Charsets.UTF_8).trimStart('\uFEFF', ' ', '\r', '\n', '\t').lowercase()
        require(!prefix.startsWith("<html") && !prefix.startsWith("<!doctype html") && !prefix.startsWith("{") && !prefix.startsWith("[{"))
    }

    private fun download(url: URI): ByteArray {
        var current = url
        repeat(4) {
            val connection = current.toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = 3000; connection.readTimeout = 5000
            connection.instanceFollowRedirects = false
            try {
                val status = connection.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    current = DlnaClient.httpUri(connection.getHeaderField("Location").orEmpty(), current.toString()) ?: error("Invalid subtitle redirect")
                } else {
                    require(status == 200 && connection.contentLengthLong <= 4 * 1024 * 1024)
                    return connection.inputStream.use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(output.size() + count <= 4 * 1024 * 1024)
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                }
            } finally { connection.disconnect() }
        }
        error("Too many subtitle redirects")
    }

    private class Bytes(data: ByteArray) : StreamSource {
        override val size = data.size.toLong()
        @Volatile private var bytes: ByteArray? = data
        override fun close() { bytes = null }
        override fun open(): StreamSource.Reader {
            check(bytes != null)
            return object : StreamSource.Reader {
                private var closed = false
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    check(!closed)
                    val data = bytes ?: error("Subtitle stream closed")
                    require(offset >= 0 && length in 1..buffer.size)
                    if (offset >= data.size) return -1
                    val count = minOf(length, data.size - offset.toInt())
                    data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                    return count
                }
                override fun close() { closed = true }
            }
        }
    }
}
