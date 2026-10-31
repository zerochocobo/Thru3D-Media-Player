package org.vrpassthroughplayer.plugin

/** Bounded asynchronous copies. Cancelled/consumed requests cannot be resurrected by a late callback. */
internal class FrameCopyResults(private val capacity: Int = 4) {
    private var sequence = 0
    private val results = LinkedHashMap<Int, Any?>()

    @Synchronized fun reserve(): Int {
        if (sequence == Int.MAX_VALUE) return 0
        val id = ++sequence
        while (results.size >= capacity) results.remove(results.keys.first())
        results[id] = null
        return id
    }

    @Synchronized fun complete(id: Int, result: Any) {
        if (results.containsKey(id) && results[id] == null) results[id] = result
    }

    @Synchronized fun state(id: Int): String = when (val result = results[id]) {
        null -> if (results.containsKey(id)) "pending" else "failed:unknown"
        is ByteArray -> "ready"
        else -> { results.remove(id); result.toString() }
    }

    @Synchronized fun take(id: Int): ByteArray = results.remove(id) as? ByteArray ?: ByteArray(0)
    @Synchronized fun cancel(id: Int) { results.remove(id) }
}
