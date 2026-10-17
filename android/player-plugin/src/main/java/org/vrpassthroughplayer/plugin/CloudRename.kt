package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Rebuild the confirmed plan from fresh metadata; mutate only verified object IDs. */
internal class CloudRename(private val client: CloudClient, private val authorized: () -> Unit = {}) {
    private fun fresh(parent: String, queries: List<String>): List<CloudFile> {
        client.freshMatches(parent, queries)?.let { return it }
        val result = ArrayList<CloudFile>()
        val seen = HashSet<String>()
        var offset = 0
        while (true) {
            val page = client.page(parent, offset, offset == 0)
            page.files.forEach { check(seen.add(it.objectId)) { "Cloud file changed. Refresh the folder" } }
            result.addAll(page.files)
            check(result.size <= DeleteTree.LIMIT) { "Cloud folder too large" }
            if (page.nextOffset < 0) return result
            check(page.nextOffset > offset) { "Cloud file changed. Refresh the folder" }
            offset = page.nextOffset
        }
    }

    fun run(path: String, request: JSONObject, prepare: Boolean): JSONObject {
        require(client.canRename && path != "/" && path.startsWith('/') && !path.endsWith('/') &&
            path.removePrefix("/").split('/').none { it.isEmpty() || it in setOf(".", "..") || '\u0000' in it })
        val expectedID = request.getString("cloud_id")
        require(expectedID.matches(Regex("[1-9][0-9]*")))
        val parent = path.substringBeforeLast('/').ifEmpty { "/" }
        val old = path.substringAfterLast('/')
        val queries = listOf(if (request.optBoolean("folder")) old else old.substringBeforeLast('.'), request.getString("new_name"))
        val files = fresh(parent, queries)
        val file = files.singleOrNull { it.objectId == expectedID && it.name == path.substringAfterLast('/') }
        check(file != null && file.canRename && file.folder == request.optBoolean("folder")) { "Cloud file changed. Refresh the folder" }
        if (!file.folder) MediaDeletePolicy.unchanged(file.size, file.modified, request.getLong("size"), request.optLong("modified", -1))
        val eligible = files.filter { !it.folder || it.objectId == file.objectId }
        val bundle = RenameBundle(file.name, request.getString("new_name"), eligible.map { it.name },
            request.optBoolean("include_same_name", true), file.folder)
        // Folders at the destination are collisions too, even though they are never companions.
        check(bundle.moves.none { move -> files.any { it.name.equals(move.to, true) } }) { "A file with that name already exists" }
        val originals = bundle.moves.associate { move ->
            val matches = files.filter { it.name == move.from && !it.folder }
            val item = if (move.from == file.name) file else matches.singleOrNull()
            check(item != null && item.canRename) { "Rename unavailable for this source" }
            move.from to item
        }
        val fingerprint = DeleteTree(bundle.moves.map { move ->
            val item = originals.getValue(move.from)
            DeleteTree.Entry(org.json.JSONArray(listOf(move.from, move.to, item.objectId)).toString(), item.folder, item.size, item.modified)
        }).fingerprint
        val preview = bundle.preview().apply {
            for (i in 0 until length()) getJSONObject(i).apply {
                put("old_path", CloudPaths.child(parent, getString("from")))
                put("new_path", CloudPaths.child(parent, getString("to")))
                put("size", originals.getValue(getString("from")).size)
            }
        }
        if (prepare) return JSONObject().put("preview", true).put("plan", fingerprint).put("moves", preview)
        check(request.optString("plan") == fingerprint) { "Folder changed; check its contents again" }
        fun inspect(move: RenameBundle.Move): Int {
            val original = originals.getValue(move.from)
            val current = fresh(parent, queries)
            val item = current.singleOrNull { it.objectId == original.objectId } ?: return -1
            if (item.folder != original.folder || (!item.folder && (item.size != original.size || item.modified != original.modified))) return -1
            return when {
                item.name == move.from && current.none { it.name == move.to } -> 0
                item.name == move.to -> 1
                else -> -1
            }
        }
        val result = bundle.execute(::inspect) { from, to ->
            authorized()
            val originalMove = bundle.moves.single { it.from == from || it.to == from }
            val original = originals.getValue(originalMove.from)
            val current = fresh(parent, queries).singleOrNull { it.objectId == original.objectId && it.name == from }
            check(current != null && current.canRename) { "Cloud file changed. Refresh the folder" }
            try { client.rename(CloudPaths.child(parent, from), current, to) } catch (_: Exception) { /* Inspect; never replay the same write. */ }
            val expected = if (from == originalMove.from) 1 else 0
            check(inspect(originalMove) == expected) { "Rename result needs checking" }
        }
        return result.put("moves", preview).put("new_path", CloudPaths.child(parent, bundle.moves[0].to)).put("new_title", bundle.moves[0].to)
    }
}
