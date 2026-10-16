package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import java.nio.file.AccessDeniedException
import java.nio.file.NoSuchFileException
import java.util.concurrent.ConcurrentHashMap

/** All resolver work runs on library/playback workers. No provider write operation is exposed. */
internal class LocalStorageDocuments(private val context: () -> Context?) : StorageDocumentTree.Provider {
    private val temporary = ConcurrentHashMap.newKeySet<String>()
    private val queries = ConcurrentHashMap.newKeySet<CancellationSignal>()
    fun cancelQueries() { queries.toList().forEach { it.cancel() } }
    val tree = StorageDocumentTree(this)
    private fun resolver() = context()?.contentResolver ?: error("Storage device unavailable")
    override fun grants(): List<String> = (resolver().persistedUriPermissions.filter { it.isReadPermission }.map { it.uri.toString() } + temporary).distinct()
    fun accept(uri: Uri, flags: Int, expectedVolume: String) {
        val at = StorageDocumentPolicy.parse(uri.toString())
        require(at.tree.volume.equals(expectedVolume, true)) { "Select a folder on this storage device" }
        if (flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0) throw AccessDeniedException("document")
        val doc = StorageDocumentPolicy.document(at.tree, at.tree)
        val metadata = query(doc, false).firstOrNull { it.id == at.tree.text && it.directory }
            ?: throw NoSuchFileException("document")
        check(metadata.directory)
        query(doc, true) // Preflight the actual grant before reporting success.
        context()?.let { LocalDocumentGrant.take(it, uri, flags) }
        temporary.add(StorageDocumentPolicy.tree(at.tree))
    }
    override fun query(uri: String, children: Boolean): List<StorageDocumentTree.Entry> {
        val at = StorageDocumentPolicy.parse(uri)
        val base = Uri.parse(StorageDocumentPolicy.tree(at.tree))
        val target = if (children) DocumentsContract.buildChildDocumentsUriUsingTree(base, at.document.text)
            else DocumentsContract.buildDocumentUriUsingTree(base, at.document.text)
        val fields = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS)
        val cancellation = CancellationSignal()
        queries.add(cancellation)
        return try { resolver().query(target, fields, null, null, null, cancellation)?.use { cursor ->
            buildList { while (cursor.moveToNext()) {
                cancellation.throwIfCanceled()
                val flags = if (cursor.isNull(5)) 0 else cursor.getInt(5)
                if (flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0) continue
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                add(StorageDocumentTree.Entry(id, name, cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                    if (cursor.isNull(3)) -1 else cursor.getLong(3), if (cursor.isNull(4)) -1 else cursor.getLong(4)))
            } }
        } ?: error("Storage folder could not be read") } finally { queries.remove(cancellation) }
    }
    fun siblings(uri: String) = StorageDocumentPolicy.parent(uri)?.let { tree.directory(it, false) } ?: org.json.JSONArray()
    fun owns(uri: String) = runCatching { StorageDocumentPolicy.parse(uri); true }.getOrDefault(false)
    fun initialUri(volume: String): Uri = DocumentsContract.buildDocumentUri(StorageDocumentPolicy.AUTHORITY, "$volume:")
}
