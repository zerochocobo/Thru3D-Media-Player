package org.vrpassthroughplayer.plugin

import java.io.InputStream
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** A STRM is a bounded text shortcut, never a playlist or a player command. */
internal class StrmFailure(val code: String, cause: Throwable? = null) : IllegalArgumentException(code, cause)
internal data class StrmDocument(val bytes: ByteArray, val location: String)

internal object StrmFile {
    const val MAX_BYTES = 65536
    const val MAX_DEPTH = 4
    private fun reject(code: String): Nothing = throw StrmFailure(code)

    fun named(name: String) = name.substringAfterLast('.').equals("strm", true)
    fun location(uri: String): Boolean = when {
        uri.startsWith("smb://") -> named(uri)
        else -> runCatching { named(URI(uri).path.orEmpty()) }.getOrDefault(false)
    }

    fun read(input: InputStream): ByteArray {
        val bytes = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - bytes.size()))
            if (count < 0) return bytes.toByteArray()
            if (count == 0) reject("STRM_READ_FAILED")
            bytes.write(buffer, 0, count)
            if (bytes.size() > MAX_BYTES) reject("STRM_TOO_LARGE")
        }
    }

    fun read(source: StreamSource): ByteArray = source.use {
        if (it.size > MAX_BYTES) reject("STRM_TOO_LARGE")
        if (it.size <= 0) reject("STRM_EMPTY")
        val bytes = ByteArray(it.size.toInt())
        it.open().use { reader ->
            var offset = 0
            while (offset < bytes.size) {
                val buffer = ByteArray(bytes.size - offset)
                val count = reader.read(offset.toLong(), buffer, buffer.size)
                if (count <= 0 || count > buffer.size) reject("STRM_READ_FAILED")
                buffer.copyInto(bytes, offset, 0, count); offset += count
            }
        }
        bytes
    }

    fun parse(bytes: ByteArray): String {
        if (bytes.size > MAX_BYTES) reject("STRM_TOO_LARGE")
        val (charset, skip) = when {
            bytes.size >= 3 && bytes[0] == 0xef.toByte() && bytes[1] == 0xbb.toByte() && bytes[2] == 0xbf.toByte() -> Charsets.UTF_8 to 3
            bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte() -> Charsets.UTF_16LE to 2
            bytes.size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte() -> Charsets.UTF_16BE to 2
            else -> Charsets.UTF_8 to 0
        }
        val text = try {
            charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, skip, bytes.size - skip)).toString()
        } catch (_: Exception) { reject("STRM_INVALID_TEXT") }
        if (text.any { it.code < 32 && it !in "\r\n\t" }) reject("STRM_INVALID_TEXT")
        val lines = text.lineSequence().map(String::trim).filter { it.isNotEmpty() && !it.startsWith('#') }.toList()
        if (lines.isEmpty()) reject("STRM_EMPTY")
        if (lines.size != 1) reject("STRM_MULTIPLE_TARGETS")
        if (lines[0].contains('|')) reject("STRM_UNSUPPORTED_ADDRESS")
        return lines[0]
    }

    fun target(origin: String, value: String): String { return try {
        if (Regex("^[A-Za-z]:[/\\\\]").containsMatchIn(value)) reject("STRM_WINDOWS_PATH")
        if (value.startsWith("\\\\")) {
            val unc = value.replace('\\', '/').removePrefix("//")
            return checked(URI("smb", unc.substringBefore('/'), "/" + unc.substringAfter('/', ""), null).toASCIIString())
        }
        if (Regex("^[A-Za-z][A-Za-z0-9+.-]*:").containsMatchIn(value)) return checked(value)
        val base = URI(origin)
        when (base.scheme) {
            "http", "https" -> checked(base.resolve(URI(value.replace(" ", "%20"))).toASCIIString())
            "file" -> {
                val path = normalized(base.path.substringBeforeLast('/'), value.replace('\\', '/'), 0)
                URI("file", "", path, null).toASCIIString()
            }
            "cloud", "smb" -> {
                // A leading slash is the mount/share root. '..' cannot escape that root.
                val minimum = if (base.scheme == "smb") 1 else 0
                val root = if (minimum == 1) "/" + base.path.trimStart('/').substringBefore('/') else ""
                val relative = value.replace('\\', '/')
                val path = normalized(if (relative.startsWith('/')) root else base.path.substringBeforeLast('/'), relative.trimStart('/'), minimum)
                checked(URI(base.scheme, base.authority, path, null).toASCIIString())
            }
            else -> reject("STRM_RELATIVE_PATH_UNAVAILABLE")
        }
    } catch (error: StrmFailure) { throw error }
      catch (_: Exception) { reject("STRM_INVALID_ADDRESS") }
    }

    private fun normalized(parent: String, path: String, minimum: Int): String {
        val parts = (if (path.startsWith('/')) emptyList() else parent.split('/').filter(String::isNotEmpty)).toMutableList()
        for (part in path.split('/')) when (part) {
            "", "." -> Unit
            ".." -> { if (parts.size <= minimum) reject("STRM_INVALID_ADDRESS"); parts.removeAt(parts.lastIndex) }
            else -> parts.add(part)
        }
        return "/" + parts.joinToString("/")
    }

    private fun checked(value: String): String {
        val uri = URI(value.replace(" ", "%20"))
        when (uri.scheme?.lowercase()) {
            "http", "https" -> if (uri.host.isNullOrEmpty()) reject("STRM_INVALID_ADDRESS")
            "smb" -> if (uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null || uri.path.isNullOrEmpty() || uri.path.split('/').any { it == "." || it == ".." }) reject("STRM_INVALID_ADDRESS")
            "file" -> {
                if (!uri.authority.isNullOrEmpty() || !uri.path.orEmpty().startsWith('/') || uri.rawQuery != null || uri.rawFragment != null) reject("STRM_INVALID_ADDRESS")
                if (Regex("^/[A-Za-z]:/").containsMatchIn(uri.path)) reject("STRM_WINDOWS_PATH")
            }
            "cloud" -> CloudPaths.path(value)
            "content" -> if (uri.authority.isNullOrEmpty()) reject("STRM_INVALID_ADDRESS")
            else -> reject("STRM_UNSUPPORTED_ADDRESS")
        }
        return uri.scheme.lowercase() + uri.toASCIIString().substring(uri.scheme.length)
    }

    /** Convert an external NAS address to an existing saved connection, without importing credentials. */
    fun smbTarget(value: String, connections: List<Pair<String, String>>, preferred: String): String {
        val uri = URI(value)
        val path = uri.path.orEmpty().trimStart('/')
        connections.firstOrNull { it.first == uri.host }?.let { return "smb://${it.first}/$path" }
        val address = uri.rawAuthority.orEmpty()
        val candidates = connections.mapNotNull { (id, host) ->
            val prefix = host.substringAfter('/', "").trim('/')
            if (!host.substringBefore('/').equals(address, true) || (prefix.isNotEmpty() && !path.startsWith("$prefix/"))) null
            else Triple(id, if (prefix.isEmpty()) path else path.removePrefix("$prefix/"), prefix.length)
        }
        val longest = candidates.maxOfOrNull { it.third } ?: reject("STRM_SMB_CONNECTION_REQUIRED")
        val matches = candidates.filter { it.third == longest }
        val selected = matches.firstOrNull { it.first == preferred } ?: matches.singleOrNull() ?: reject("STRM_SMB_CONNECTION_REQUIRED")
        return "smb://${selected.first}/${selected.second}"
    }
}

/** Parsing is deferred until playback; browsing never contacts the target URL. */
internal class StrmResolver(
    private val read: (String) -> StrmDocument,
    private val isStrm: (String) -> Boolean = StrmFile::location,
    private val mapTarget: (String, String) -> String = { _, target -> target },
) {
    fun resolve(original: String): String {
        var uri = original
        val visited = HashSet<String>()
        var depth = 0
        while (isStrm(uri)) {
            if (!visited.add(uri) || depth++ >= StrmFile.MAX_DEPTH) throw StrmFailure("STRM_RECURSIVE")
            val document = try { read(uri) } catch (error: StrmFailure) { throw error }
                catch (_: java.net.SocketTimeoutException) { throw StrmFailure("STRM_READ_TIMEOUT") }
                catch (_: Exception) { throw StrmFailure("STRM_READ_FAILED") }
            uri = mapTarget(uri, StrmFile.target(document.location, StrmFile.parse(document.bytes)))
        }
        return uri
    }
}
