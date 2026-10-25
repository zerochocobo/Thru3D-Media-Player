package org.vrpassthroughplayer.plugin

/** Admission estimates, not a claim about driver/model peak PSS. Keep foreground unaffected. */
internal object ReadingMemoryPolicy {
    const val MIB = 1024L * 1024
    data class Policy(val budget: Long, val color: Boolean, val lowTier: Boolean, val retain: Boolean)
    fun evaluate(total: Long, available: Long, threshold: Long, lowMemory: Boolean,
                 lowRam: Boolean, double: Boolean): Policy {
        val low = lowRam || total <= 6L * 1024 * MIB
        val budget = (if (low) { if (double) 96 else 64 } else { if (double) 192 else 128 }) * MIB
        // Android availMem is reclaimable headroom, not guaranteed unused memory.
        val floor = maxOf(512 * MIB, threshold.coerceAtLeast(0) * 2)
        val retain = total > 0 && !lowMemory && available >= floor
        val color = retain && available >= floor + 256 * MIB
        return Policy(if (retain) budget else 0, color, low, retain)
    }
}
