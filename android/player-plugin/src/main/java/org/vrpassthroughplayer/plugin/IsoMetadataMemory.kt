package org.vrpassthroughplayer.plugin

import java.security.MessageDigest

/** ISO metadata blocks carried across reopens of the same remote disc (title
 * switch, resume, layer change), so the next lease does not fetch UDF,
 * playlist and clip-info sectors from the cloud again. Memory only: at most two
 * discs of IsoReadCache blocks; copies are zeroed when evicted or cleared. */
internal object IsoMetadataMemory {
    private const val DISCS = 2
    private val discs = object : LinkedHashMap<String, Map<Long, ByteArray>>(DISCS, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Map<Long, ByteArray>>): Boolean =
            (size > DISCS).also { if (it) eldest.value.values.forEach { block -> block.fill(0) } }
    }

    /** Stable for one object's bytes: account, object identity, size and change time; never stored as text. */
    fun key(vararg parts: Any): String = MessageDigest.getInstance("SHA-256")
        .digest(parts.joinToString("\u0000").toByteArray()).joinToString("") { "%02x".format(it) }

    /** Copies owned by the caller. */
    @Synchronized fun recall(key: String): Map<Long, ByteArray> = discs[key]?.mapValues { it.value.copyOf() }.orEmpty()

    @Synchronized fun keep(key: String, blocks: Map<Long, ByteArray>) {
        if (blocks.isEmpty()) return
        discs.remove(key)?.values?.forEach { it.fill(0) }
        discs[key] = blocks.mapValues { it.value.copyOf() }
    }

    @Synchronized fun clear() {
        discs.values.forEach { disc -> disc.values.forEach { it.fill(0) } }
        discs.clear()
    }
}
