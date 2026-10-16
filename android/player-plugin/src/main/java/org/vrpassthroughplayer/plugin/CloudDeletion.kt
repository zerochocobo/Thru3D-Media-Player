package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** A core rejection before calling the provider must not become an uncertain write. */
internal class CloudDeleteRejected(message: String) : IllegalStateException(message)

/** Only ordinary 115 delete. The core validates fresh target identity immediately before writing. */
internal class CloudDeletion(private val client: CloudClient, private val authorized: () -> Unit = {}) {
    private fun fresh(path: String): CloudFile? {
        val parent = path.substringBeforeLast('/').ifEmpty { "/" }
        val name = path.substringAfterLast('/')
        var offset = 0
        val seen = HashSet<String>()
        var count = 0
        var found: CloudFile? = null
        while (true) {
            val page = client.page(parent, offset, offset == 0)
            for (file in page.files) {
                check(seen.add(file.objectId)) { "Cloud file changed. Refresh the folder" }
                if (file.name == name) {
                    if (found != null) throw CloudFailure("cloud_file_ambiguous")
                    found = file
                }
            }
            count += page.files.size
            check(count <= DeleteTree.LIMIT && (page.nextOffset < 0 || page.nextOffset > offset)) { "Cloud folder too large" }
            if (page.nextOffset < 0) return found
            offset = page.nextOffset
        }
    }
    fun run(path: String, request: JSONObject, inspect: Boolean, prepare: Boolean): JSONObject {
        require(client.canDelete && path != "/" && path.startsWith('/') && !path.endsWith('/') &&
            path.removePrefix("/").split('/').none { it.isEmpty() || it in setOf(".", "..") || '\u0000' in it })
        require(request.optBoolean("folder") || MediaKinds.supported(path.substringAfterLast('/'))) { "File deletion unavailable for this source" }
        val expected = request.getString("cloud_id")
        require(expected.matches(Regex("[1-9][0-9]*")))
        if (inspect) {
            val file = fresh(path)
            return JSONObject().put("exists", file != null).put("changed", file != null && file.objectId != expected)
        }
        // These are expected metadata, not proof of permission. remove115 resolves the
        // path fresh and verifies ID, kind, permissions and file metadata in one place.
        val file = CloudFile(path.substringAfterLast('/'), request.optBoolean("folder"),
            if (request.optBoolean("folder")) 0 else request.getLong("size"), path,
            modified = request.optLong("modified", -1), objectId = expected, canDelete = true)
        if (file.folder) {
            // Confirmation binds the selected directory, not a recursive contents snapshot.
            val plan = DeleteTree(listOf(DeleteTree.Entry(org.json.JSONArray(listOf(path, expected)).toString(), true, 0, -1)))
            if (prepare) return JSONObject().put("preview", true).put("plan", plan.fingerprint).put("counts_known", false)
            plan.verify(request)
        }
        require(!prepare) { "Invalid folder preview" }
        authorized() // Check account identity again immediately before the write.
        try {
            client.remove(path, file)
            return JSONObject().put("deleted", true) // The SDK confirmed success; no duplicate read-back.
        }
        catch (error: CloudDeleteRejected) { throw error }
        catch (_: Exception) { /* An error can follow a successful delete. Read back, never replay. */ }
        return try {
            val remaining = fresh(path)
            if (remaining == null) JSONObject().put("deleted", true)
            else JSONObject().put("state", "uncertain").put("error", "Delete result needs checking")
        } catch (_: Exception) { JSONObject().put("state", "uncertain").put("error", "Delete result needs checking") }
    }
}
