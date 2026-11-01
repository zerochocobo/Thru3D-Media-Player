package org.vrpassthroughplayer.plugin

import java.io.File
import java.net.URI
import java.util.Locale

/** Validated, transient input. Never serialize this object into diagnostics or history. */
internal class ExternalPlaybackRequest private constructor(
    val uri: String,
    val title: String,
    val mime: String,
    val headers: Map<String, String>,
    val scheme: String,
    val loopback: Boolean,
) {
    companion object {
        val headerNames = setOf("user-agent", "referer", "cookie", "authorization", "accept", "accept-language",
            "x-emby-token", "x-mediabrowser-token")

        fun parse(action: String?, text: String?, title: String? = null, mime: String? = null,
                  headers: Map<String, String> = emptyMap(), privateRoots: List<File> = emptyList()): ExternalPlaybackRequest {
            require(action == "android.intent.action.VIEW") { "UNSUPPORTED_ACTION" }
            require(text != null && text.length in 1..8192 && text.none { it.isISOControl() }) { "INVALID_URI" }
            val value = try { URI(text) } catch (_: Exception) { throw IllegalArgumentException("INVALID_URI") }
            val scheme = value.scheme?.lowercase(Locale.ROOT)
            require(scheme in setOf("file", "content", "http", "https")) { "UNSUPPORTED_SCHEME" }
            require(value.rawUserInfo == null) { "URI_CREDENTIALS_NOT_SUPPORTED" }
            if (scheme == "http" || scheme == "https") {
                require(!value.host.isNullOrBlank() && value.port in -1..65535) { "INVALID_URI" }
            } else if (scheme == "content") {
                require(!value.rawAuthority.isNullOrBlank() && !value.rawPath.isNullOrEmpty()) { "INVALID_URI" }
            } else {
                require(value.rawAuthority.isNullOrEmpty() && !value.path.isNullOrEmpty() && value.query == null && value.fragment == null) { "INVALID_FILE_URI" }
                require(value.path.none { it.isISOControl() }) { "INVALID_FILE_URI" }
                val file = try { File(value).canonicalFile } catch (_: Exception) { throw IllegalArgumentException("INVALID_FILE_URI") }
                require(privateRoots.none { root ->
                    val base = root.canonicalFile.toPath()
                    file.toPath().startsWith(base)
                }) { "PRIVATE_FILE_DENIED" }
            }
            val cleanHeaders = linkedMapOf<String, String>()
            headers.forEach { (key, content) ->
                val name = key.lowercase(Locale.ROOT)
                require(name in headerNames) { "UNSUPPORTED_HEADER" }
                require(content.length <= 8192 && content.none { it == '\r' || it == '\n' || it == '\u0000' }) { "INVALID_HEADER" }
                require(!cleanHeaders.containsKey(name)) { "DUPLICATE_HEADER" }
                cleanHeaders[name] = content
            }
            val host = value.host?.removePrefix("[")?.removeSuffix("]")?.lowercase(Locale.ROOT).orEmpty()
            val loopback = host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" ||
                host.matches(Regex("127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}"))
            val cleanTitle = title.orEmpty().filterNot { it.isISOControl() }
            val titleEnd = cleanTitle.offsetByCodePoints(0, minOf(256, cleanTitle.codePointCount(0, cleanTitle.length)))
            return ExternalPlaybackRequest(text, cleanTitle.substring(0, titleEnd),
                mime.orEmpty().take(128), cleanHeaders.toMap(), scheme!!, loopback)
        }
    }

    // Prevent accidental URL/token disclosure through logging, exceptions or data-class output.
    override fun toString() = "ExternalPlaybackRequest(scheme=$scheme, loopback=$loopback)"
}

/** Contract evidence for diagnostics: names and value kinds only, never values. */
internal object ExternalPlaybackContract {
    const val MAX_ENTRIES = 64
    fun startMs(values: List<Any?>): Int = values.firstNotNullOfOrNull { value ->
        when (value) { is Int -> value.toLong(); is Long -> value; else -> null }
    }?.coerceIn(0, Int.MAX_VALUE.toLong())?.toInt() ?: 0

    const val REDACTED = "<redacted>"
    private val namePattern = Regex("[A-Za-z0-9._-]{1,48}")

    /** Names can carry URLs or tokens too: only short, segmented identifiers are kept. */
    fun safeName(name: String?): String =
        name?.takeIf { it.matches(namePattern) && it.split('.', '_', '-').all { part -> part.length <= 24 } } ?: REDACTED

    fun kind(value: Any?): String = when (value) {
        null -> "null"
        is String -> "string"
        is Int -> "int"
        is Long -> "long"
        is Boolean -> "boolean"
        is Float -> if (value.isFinite()) "float" else "non_finite"
        is Double -> if (value.isFinite()) "double" else "non_finite"
        is Short, is Byte -> "short"
        is Char -> "char"
        is Array<*> -> if (value.isArrayOf<String>()) "string_array" else "array"
        is IntArray -> "int_array"
        is LongArray -> "long_array"
        is ByteArray -> "byte_array"
        is android.os.Bundle -> "bundle"
        is android.net.Uri -> "uri"
        is List<*> -> "list"
        is android.os.Parcelable -> "parcelable"
        is java.io.Serializable -> "serializable"
        else -> "other"
    }

    class Headers(val accepted: Map<String, String>, val received: List<String>, val dropped: List<String>)

    /** Bundle and MX-style string-array headers share one rule: unknown names are dropped and named. */
    fun headers(pairs: List<Pair<String?, String?>>): Headers {
        require(pairs.size <= MAX_ENTRIES) { "INVALID_HEADER" }
        val accepted = linkedMapOf<String, String>()
        val received = mutableListOf<String>()
        val dropped = mutableListOf<String>()
        for ((name, value) in pairs) {
            require(name != null) { "INVALID_HEADER" }
            val lower = name.lowercase(Locale.ROOT)
            received += safeName(lower)
            if (lower !in ExternalPlaybackRequest.headerNames) { dropped += safeName(lower); continue }
            accepted[name] = value ?: throw IllegalArgumentException("INVALID_HEADER")
        }
        return Headers(accepted, received, dropped)
    }

    fun stringArrayPairs(values: Array<String?>): List<Pair<String?, String?>> {
        require(values.size % 2 == 0 && values.size <= MAX_ENTRIES * 2) { "INVALID_HEADER" }
        return values.toList().chunked(2).map { it[0] to it[1] }
    }
}

/** Latest delivery wins; claiming removes it. No Intent, URI or receipt is persisted. */
internal class ExternalPlaybackInbox(private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
                                     private val lifetimeMs: Long = 60_000) {
    data class Delivery(val id: Long, val request: ExternalPlaybackRequest, val receivedMs: Long) {
        override fun toString() = "ExternalPlaybackDelivery(id=$id)"
    }
    private var serial = 0L
    private var waiting: Delivery? = null
    @Synchronized fun offer(request: ExternalPlaybackRequest): Long {
        val id = ++serial
        waiting = Delivery(id, request, clock())
        return id
    }
    @Synchronized fun claim(id: Long): Delivery? {
        val value = waiting ?: return null
        if (value.id != id) return null
        waiting = null
        return value.takeIf { clock() - it.receivedMs in 0..lifetimeMs }
    }
    @Synchronized fun claimLatest(): Delivery? = waiting?.let { claim(it.id) }
    @Synchronized fun current(id: Long) = id == serial
    @Synchronized fun discard(id: Long) { if (waiting?.id == id) waiting = null }
    /** Drops any waiting delivery and returns a new id that only outcome-only work can hold. */
    @Synchronized fun cancel(): Long { waiting = null; return ++serial }
}
