package org.vrpassthroughplayer.plugin

import android.app.ActivityManager
import android.content.Context
import android.os.PowerManager

/** Admission headroom for optional work. Shared RAM includes GPU allocations; this is an
 * estimate, not an allocation guarantee or a device-model performance tier. */
internal object BackgroundResourceBudget {
    const val MIB = 1024L * 1024
    // Internal ceilings, not preallocation. Include CPU pixels and prepared GPU textures;
    // measured headroom and the reserve still determine actual cache admission.
    // A future preference can supply Limits without changing callers.
    data class Limits(val reserveBytes: Long = 768 * MIB, val reservePercent: Int = 15,
                      val maxCacheBytes: Long = 768 * MIB, val heapReserveBytes: Long = 32 * MIB)
    val limits = Limits()
    // Depth and portrait use different production workers, but share one optional photo workload.
    val photoWorkLock = Any()
    data class Snapshot(val spare: Long, val heapSpare: Long, val retain: Boolean,
                        val work: Boolean, val cacheLimit: Long, val reserve: Long) {
        fun admits(peak: Long): Boolean = work && peak > 0 && spare >= peak
    }

    fun evaluate(total: Long, available: Long, threshold: Long, low: Boolean,
                 heapMax: Long, heapUsed: Long, thermal: Int, config: Limits = limits): Snapshot {
        val reserve = maxOf(config.reserveBytes, total.coerceAtLeast(0) / 100 * config.reservePercent,
            threshold.coerceAtLeast(0).coerceAtMost(Long.MAX_VALUE / 2) * 2)
        val spare = (available.coerceAtLeast(0) - reserve).coerceAtLeast(0)
        val heap = (heapMax.coerceAtLeast(0) - heapUsed.coerceAtLeast(0) - config.heapReserveBytes).coerceAtLeast(0)
        val retain = total > 0 && !low && available >= reserve
        return Snapshot(spare, heap, retain, retain && heap >= 16 * MIB && thermal in 0..1,
            config.maxCacheBytes, reserve)
    }

    fun snapshot(context: Context?): Snapshot = runCatching {
        val app = context ?: error("MEMORY_UNAVAILABLE")
        val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: error("MEMORY_UNAVAILABLE")
        val memory = ActivityManager.MemoryInfo(); manager.getMemoryInfo(memory)
        val runtime = Runtime.getRuntime()
        val power = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val thermal = power?.currentThermalStatus ?: -1
        evaluate(memory.totalMem, memory.availMem, memory.threshold, memory.lowMemory,
            runtime.maxMemory(), runtime.totalMemory() - runtime.freeMemory(), thermal)
    }.getOrElse { evaluate(0, 0, 0, true, 0, 0, -1) }

    // Cold model/session, decode/rotation/direct buffers, GPU warp and result handover.
    // Includes a cold-model allowance even when the session may already be warm.
    fun photoPeak(width: Int, height: Int, includeModel: Boolean = true): Long {
        if (width <= 0 || height <= 0) return Long.MAX_VALUE
        val (w, h) = PhotoStereo.size(width, height)
        return (if (includeModel) 512 * MIB else 0) + w.toLong() * h * 128
    }
}
