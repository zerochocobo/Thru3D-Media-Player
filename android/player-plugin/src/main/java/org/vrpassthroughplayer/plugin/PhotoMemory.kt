package org.vrpassthroughplayer.plugin

import android.app.ActivityManager
import android.content.Context

/** Current headroom, not a fixed source megapixel or device-model allowance. */
internal object PhotoMemory {
    const val MIB = 1024L * 1024
    data class Budget(val native: Long, val output: Long)
    @Volatile private var app: Context? = null
    fun attach(context: Context) { app = context.applicationContext }
    fun evaluate(total: Long, available: Long, threshold: Long, low: Boolean,
                 heapMax: Long, heapUsed: Long): Budget {
        if(total<=0 || heapMax<=0)return Budget(0,0)
        val reserve = maxOf(128*MIB, threshold.coerceAtLeast(0), total.coerceAtLeast(0)/20)
        val native = if(low) 0 else (available-reserve).coerceAtLeast(0)/3*2
        val heap = (heapMax-heapUsed-16*MIB).coerceAtLeast(0)
        return Budget(native, minOf(native/6, heap/2, 8192L*8192*4))
    }
    fun snapshot(): Budget = try {
        val context = app ?: error("PHOTO_MEMORY_UNAVAILABLE")
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: error("PHOTO_MEMORY_UNAVAILABLE")
        val info = ActivityManager.MemoryInfo(); manager.getMemoryInfo(info)
        val runtime = Runtime.getRuntime()
        evaluate(info.totalMem, info.availMem, info.threshold, info.lowMemory,
            runtime.maxMemory(), runtime.totalMemory()-runtime.freeMemory())
    } catch(_: Exception) { throw IllegalStateException("PHOTO_MEMORY_UNAVAILABLE") }
}
