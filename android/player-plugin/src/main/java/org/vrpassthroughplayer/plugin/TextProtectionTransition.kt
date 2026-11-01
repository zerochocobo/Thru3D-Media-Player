package org.vrpassthroughplayer.plugin

import kotlin.math.abs

/** Render-time transitions, independent of detector cadence/latency. Never interpolate over a seek/cut.
 * Retaining a line briefly across an empty detection avoids flatten/unflatten on every subtitle gap. */
internal class TextProtectionTransition {
    data class Snapshot(val regions: FloatArray, val weights: FloatArray, val animating: Boolean) {
        companion object { val EMPTY = Snapshot(FloatArray(0), FloatArray(0), false) }
    }
    private class Track(val first: TextProtectionPolicy.Box, now: Long) {
        var from = first
        var to = first
        var geometryStart = now
        var fromWeight = 0f
        var toWeight = 1f
        var weightStart = now
        var duration = ENTER_MS
        fun weight(now: Long) = lerp(fromWeight,toWeight,progress(now,weightStart,duration))
        fun box(now: Long): TextProtectionPolicy.Box {
            val t=progress(now,geometryStart,GEOMETRY_MS)
            return TextProtectionPolicy.Box(lerp(from.x0,to.x0,t),lerp(from.y0,to.y0,t),lerp(from.x1,to.x1,t),lerp(from.y1,to.y1,t))
        }
        fun animating(now: Long) = now < weightStart+duration || now < geometryStart+GEOMETRY_MS
    }
    private val tracks=mutableListOf<Track>()
    private var targets: List<TextProtectionPolicy.Box>?=null
    private var clock=-1L
    fun reset() { tracks.clear();targets=null;clock=-1 }
    fun sample(next: List<TextProtectionPolicy.Box>,nowMs: Long): Snapshot {
        if(clock>nowMs)reset()
        clock=nowMs
        if(tracks.removeAll { it.toWeight==0f && nowMs>=it.weightStart+it.duration }) targets=null
        if(targets!=next) {
            val unused=tracks.toMutableList()
            for(box in next.take(TextProtectionPolicy.MAX_REGIONS)) {
                val old=unused.maxByOrNull { it.to.overlap(box) }?.takeIf {
                    it.to.overlap(box)>.20f || (abs((it.to.y0+it.to.y1)-(box.y0+box.y1)) < minOf(it.to.height,box.height)*.6f &&
                        abs((it.to.x0+it.to.x1)-(box.x0+box.x1))<.35f)
                }
                if(old!=null) {
                    unused.remove(old)
                    if(!same(old.to,box)) { old.from=old.box(nowMs);old.to=box;old.geometryStart=nowMs }
                    if(old.toWeight!=1f) { old.fromWeight=old.weight(nowMs);old.toWeight=1f;old.weightStart=nowMs;old.duration=ENTER_MS }
                } else if(tracks.size<TextProtectionPolicy.MAX_REGIONS) tracks.add(Track(box,nowMs))
            }
            for(old in unused) if(old.toWeight!=0f) {
                old.fromWeight=old.weight(nowMs);old.toWeight=0f;old.weightStart=nowMs+HOLD_MS;old.duration=EXIT_MS
            }
            targets=next
        }
        if(tracks.isEmpty())return Snapshot.EMPTY
        val boxes=tracks.map { it.box(nowMs) }
        return Snapshot(TextProtectionPolicy.flatten(boxes),tracks.map { it.weight(nowMs) }.toFloatArray(),tracks.any { it.animating(nowMs) })
    }
    companion object {
        const val ENTER_MS=240L
        const val HOLD_MS=200L
        const val EXIT_MS=320L
        const val GEOMETRY_MS=180L
        private fun same(a: TextProtectionPolicy.Box,b: TextProtectionPolicy.Box) = a.x0==b.x0&&a.y0==b.y0&&a.x1==b.x1&&a.y1==b.y1
        private fun lerp(a: Float,b: Float,t: Float) = a+(b-a)*t
        private fun progress(now: Long,start: Long,duration: Long): Float {
            val t=((now-start).toFloat()/duration).coerceIn(0f,1f)
            return t*t*(3f-2f*t)
        }
    }
}
