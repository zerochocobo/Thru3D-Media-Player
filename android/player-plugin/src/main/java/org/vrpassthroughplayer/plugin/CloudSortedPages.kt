package org.vrpassthroughplayer.plugin

/** Browse in the provider's directory-wide order, one requested API page at a time.
 * Preserve every returned file type; UI and companion consumers apply their own filters.
 * A missing native order must not silently trigger a full-directory metadata crawl. */
internal class CloudSortedPages {
    fun page(client: CloudClient, path: String, offset: Int, refresh: Boolean, order: String): CloudPage {
        require((order in ORDERS || order == "source") && offset >= 0) { "directory.sort: invalid order or offset" }
        client.orderedPage(path, offset, refresh, order)?.let { return it }
        if (order == "source") return client.page(path, offset, refresh)
        throw CloudFailure(detail = "directory.sort: native provider sorting unavailable")
    }

    companion object {
        val ORDERS = setOf("name_asc", "name_desc", "modified_desc", "modified_asc", "size_desc", "size_asc")
        // Used only for bounded legacy search results, never for directory browsing.
        fun comparator(order: String): Comparator<CloudFile> = Comparator { a, b ->
            if (a.folder != b.folder) return@Comparator if (a.folder) -1 else 1
            val field = order.substringBefore('_')
            if (field == "modified" || (field == "size" && !a.folder)) {
                val av = if (field == "size") a.size else a.modified
                val bv = if (field == "size") b.size else b.modified
                if ((av < 0) != (bv < 0)) return@Comparator if (av < 0) 1 else -1
                if (av != bv) return@Comparator av.compareTo(bv) * if (order.endsWith("desc")) -1 else 1
            }
            val name = natural(a.name, b.name).takeIf { it != 0 } ?: a.name.compareTo(b.name)
            if (name != 0) name * if (field == "name" && order.endsWith("desc")) -1 else 1 else a.id.compareTo(b.id)
        }
        internal fun natural(a: String, b: String): Int {
            // Godot naturalnocasecmp compares uppercase code points and puts a leading
            // dot before other prefixes. Do not fold punctuation or expand characters.
            val left = a.codePoints().map { Character.toUpperCase(it) }.toArray()
            val right = b.codePoints().map { Character.toUpperCase(it) }.toArray()
            if (left.isNotEmpty() && right.isNotEmpty() && (left[0] == 46) != (right[0] == 46))
                return if (left[0] == 46) -1 else 1
            var i = 0; var j = 0
            while (i < left.size && j < right.size) {
                if (left[i] in 48..57 && right[j] in 48..57) {
                    var si = i; var sj = j
                    while (i < left.size && left[i] in 48..57) i++
                    while (j < right.size && right[j] in 48..57) j++
                    while (si < i && left[si] == 48) si++
                    while (sj < j && right[sj] == 48) sj++
                    if (i - si != j - sj) return (i - si).compareTo(j - sj)
                    while (si < i) {
                        if (left[si] != right[sj]) return left[si].compareTo(right[sj])
                        si++; sj++
                    }
                } else {
                    if (left[i] != right[j]) return left[i].compareTo(right[j])
                    i++; j++
                }
            }
            return (left.size - i).compareTo(right.size - j)
        }
    }
}
