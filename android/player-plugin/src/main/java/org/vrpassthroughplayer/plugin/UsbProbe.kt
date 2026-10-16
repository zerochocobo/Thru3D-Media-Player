package org.vrpassthroughplayer.plugin

import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject

/** Keep per-LUN failures instead of turning transport/table errors into an empty directory. */
internal object UsbProbe {
    data class Found(val lun: Int, val partition: UsbPartitions.Partition)
    data class Failure(val lun: Int, val stage: String, val reason: String)
    data class Geometry(val lun: Int, val sectorSize: Int, val sectorCount: Long)
    data class Result(val found: List<Found>, val failures: List<Failure>, val geometry: List<Geometry>) {
        fun error(): String = when {
            found.isNotEmpty() -> ""
            failures.any { it.stage == "partition_table" } -> "USB partition table could not be read"
            failures.isNotEmpty() -> "USB capacity could not be read"
            else -> "No supported USB partitions"
        }
        fun json() = JSONObject().put("partitions", found.size).put("failures", JSONArray().apply {
            failures.forEach { put(JSONObject().put("lun", it.lun).put("stage", it.stage).put("reason", it.reason)) }
        }).put("geometry", JSONArray().apply {
            geometry.forEach { put(JSONObject().put("lun", it.lun).put("sector_size", it.sectorSize).put("sector_count", it.sectorCount)) }
        })
    }
    fun scan(luns: IntRange, alive: () -> Boolean = { true }, open: (Int) -> UsbBlocks): Result {
        val found = mutableListOf<Found>(); val failures = mutableListOf<Failure>(); val geometry = mutableListOf<Geometry>()
        for (lun in luns) {
            if (!alive()) throw IOException("USB access stopped")
            var stage = "capacity"
            try {
                val block = open(lun)
                geometry.add(Geometry(lun, block.sectorSize, block.sectorCount))
                stage = "partition_table"
                UsbPartitions.scan(block) { failures.add(Failure(lun, "partition_boot", "read_failed")) }.forEach { found.add(Found(lun, it)) }
            } catch (error: Exception) {
                if (!alive()) throw IOException("USB access stopped", error)
                failures.add(Failure(lun, stage, if (error.message == "Invalid USB partition table") "invalid_table" else "read_failed"))
            }
        }
        return Result(found, failures, geometry)
    }
}
