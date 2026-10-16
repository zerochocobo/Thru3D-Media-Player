package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLEncoder
import java.nio.file.AccessDeniedException
import java.nio.file.NoSuchFileException
import org.json.JSONArray
import org.json.JSONObject

/** External-storage document identities. A tree grant never authorizes another volume or parent. */
internal object StorageDocumentPolicy {
    const val AUTHORITY = "com.android.externalstorage.documents"
    data class Id(val volume: String, val path: String) {
        val text get() = "$volume:$path"
        fun contains(other: Id) = volume.equals(other.volume, true) &&
            (path.isEmpty() || path == other.path || other.path.startsWith("$path/"))
    }
    data class Location(val tree: Id, val document: Id)
    fun id(text: String): Id {
        val split = text.indexOf(':')
        require(split > 0)
        val volume = text.substring(0, split)
        val path = text.substring(split + 1)
        require(Regex("[A-Za-z0-9-]{1,64}").matches(volume))
        require(path.isEmpty() || path.split('/').all { it.isNotEmpty() && it !in listOf(".", "..") && it.none { c -> c == '\\' || c.code < 32 } })
        return Id(volume, path)
    }
    fun parse(text: String): Location {
        val uri = URI(text)
        require(uri.scheme == "content" && uri.rawAuthority == AUTHORITY && uri.rawQuery == null && uri.rawFragment == null)
        val parts = uri.rawPath.split('/')
        require(parts.size in listOf(3, 5) && parts[0].isEmpty() && parts[1] == "tree")
        fun decode(value: String) = URI("content://x/$value").path.removePrefix("/")
        val tree = id(decode(parts[2]))
        val doc = if (parts.size == 3) tree else {
            require(parts[3] == "document"); id(decode(parts[4]))
        }
        require(tree.contains(doc))
        return Location(tree, doc)
    }
    private fun encoded(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    fun tree(id: Id) = "content://$AUTHORITY/tree/${encoded(id.text)}"
    fun document(tree: Id, document: Id): String {
        require(tree.contains(document))
        return tree(tree) + "/document/" + encoded(document.text)
    }
    fun parent(uri: String): String? {
        val at = parse(uri)
        if (at.tree == at.document) return null
        return document(at.tree, Id(at.document.volume, at.document.path.substringBeforeLast('/', "")))
    }
    fun relative(origin: String, value: String): String {
        val at = parse(origin)
        require(!value.startsWith('/') && '\\' !in value)
        val parts = at.document.path.substringBeforeLast('/', "").split('/').filter(String::isNotEmpty).toMutableList()
        val minimum = at.tree.path.split('/').count(String::isNotEmpty)
        for (part in value.split('/')) when (part) {
            "", "." -> Unit
            ".." -> { require(parts.size > minimum); parts.removeAt(parts.lastIndex) }
            else -> { require(part.none { it.code < 32 }); parts.add(part) }
        }
        return document(at.tree, id(at.document.volume + ":" + parts.joinToString("/")))
    }
}

/** Provider-independent, read-only tree browser; provider flags never enable file mutation. */
internal class StorageDocumentTree(private val provider: Provider) {
    data class Entry(val id: String, val name: String, val directory: Boolean, val size: Long = -1, val modified: Long = -1)
    interface Provider {
        fun grants(): List<String>
        fun query(uri: String, children: Boolean): List<Entry>
    }
    fun grants(volume: String): List<StorageDocumentPolicy.Id> = provider.grants().mapNotNull {
        runCatching { StorageDocumentPolicy.parse(it).tree }.getOrNull()?.takeIf { root -> root.volume.equals(volume, true) }
    }.distinct().sortedBy { it.path.length }.fold(mutableListOf()) { roots, next ->
        if (roots.none { it.contains(next) }) roots.add(next)
        roots
    }
    fun authorized(uri: String): Boolean = runCatching {
        val at = StorageDocumentPolicy.parse(uri)
        provider.grants().any { runCatching { StorageDocumentPolicy.parse(it).tree == at.tree }.getOrDefault(false) }
    }.getOrDefault(false)
    fun directory(uri: String, mediaOnly: Boolean = true): JSONArray {
        if (!authorized(uri)) throw AccessDeniedException("document")
        val at = StorageDocumentPolicy.parse(uri)
        val entries = provider.query(uri, true).filter { row ->
            val child = runCatching { StorageDocumentPolicy.id(row.id) }.getOrNull()
            child != null && at.document.contains(child) && child != at.document &&
                child.path.substringBeforeLast('/', "") == at.document.path && validName(row.name) &&
                !row.name.startsWith('.') && (row.directory || !mediaOnly || MediaKinds.supportedFileName(row.name))
        }.sortedWith(compareBy({ !it.directory }, { it.name.lowercase() }))
        return JSONArray().apply { entries.forEach { put(row(at.tree, it)) } }
    }
    /** A selected subfolder stays explicit: it is never silently presented as the disk root. */
    fun root(volume: String): JSONArray {
        val roots = grants(volume)
        if (roots.isEmpty()) throw AccessDeniedException("document")
        roots.firstOrNull { it.path.isEmpty() }?.let { return directory(StorageDocumentPolicy.document(it, it)) }
        return JSONArray().apply { roots.forEach { tree ->
            val uri = StorageDocumentPolicy.document(tree, tree)
            val entry = provider.query(uri, false).firstOrNull { it.id == tree.text && it.directory }
                ?: throw NoSuchFileException("document")
            put(row(tree, entry))
        } }
    }
    fun filePath(path: String, root: String, volume: String): JSONArray {
        val relative = path.removePrefix(root.trimEnd('/')).trimStart('/')
        if (relative.isEmpty()) return root(volume)
        val doc = StorageDocumentPolicy.id("$volume:$relative")
        val tree = grants(volume).firstOrNull { it.contains(doc) } ?: throw AccessDeniedException("document")
        return directory(StorageDocumentPolicy.document(tree, doc))
    }
    private fun validName(name: String) = name.isNotEmpty() && name !in listOf(".", "..") && name.none { it == '/' || it == '\\' || it.code < 32 }
    private fun row(tree: StorageDocumentPolicy.Id, entry: Entry): JSONObject {
        val uri = StorageDocumentPolicy.document(tree, StorageDocumentPolicy.id(entry.id))
        return JSONObject().put("id", uri).put("uri", uri).put("title", entry.name).put("container", entry.directory)
            .put("size", entry.size).put("modified", entry.modified).put("kind", if (entry.directory) "folder" else MediaKinds.fileNameKind(entry.name))
            .put("read_only", true).put("can_delete", false).put("can_rename", false)
    }
}
