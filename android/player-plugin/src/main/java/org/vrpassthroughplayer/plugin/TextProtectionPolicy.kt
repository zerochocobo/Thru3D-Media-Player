package org.vrpassthroughplayer.plugin

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Source-image UVs, independent of the depth grid, display rotation and background motion. */
internal object TextProtectionPolicy {
    const val MAX_REGIONS = 8
    data class Box(val x0: Float, val y0: Float, val x1: Float, val y1: Float, val score: Float = 1f) {
        val width get() = x1 - x0
        val height get() = y1 - y0
        fun valid() = listOf(x0,y0,x1,y1,score).all { it.isFinite() } && x0 >= 0 && y0 >= 0 && x1 <= 1 && y1 <= 1 && width > 0 && height > 0
        fun overlap(other: Box): Float {
            val area = max(0f,min(x1,other.x1)-max(x0,other.x0))*max(0f,min(y1,other.y1)-max(y0,other.y0))
            return area / max(1e-6f, width*height+other.width*other.height-area)
        }
    }
    data class Crop(val x: Float = 0f, val y: Float = 0f, val w: Float = 1f, val h: Float = 1f) {
        // Native's content_rect maps source UV to model UV; invert the ROI mapping.
        fun content() = floatArrayOf(-x/w,-y/h,1f/w,1f/h)
        fun map(b: Box) = Box(x+b.x0*w,y+b.y0*h,x+b.x1*w,y+b.y1*h,b.score)
    }
    fun dimensions(width: Int,height: Int): Pair<Int,Int> {
        val scale = 640.0 / max(width,height).coerceAtLeast(1)
        return max(32,(width*scale/32).toInt()*32) to max(32,(height*scale/32).toInt()*32)
    }
    fun lines(input: List<Box>): List<Box> {
        val rows = mutableListOf<Box>()
        for (box in input.filter { it.valid() && it.score >= .4f && it.height in .005f.. .15f }.sortedBy { it.x0 }) {
            val i = rows.indexOfFirst { row ->
                val vertical = min(row.y1,box.y1)-max(row.y0,box.y0)
                vertical > min(row.height,box.height)*.55f && box.x0-row.x1 < max(row.height,box.height)*2
            }
            if(i<0) rows.add(box) else { val a=rows[i];rows[i]=Box(min(a.x0,box.x0),min(a.y0,box.y0),max(a.x1,box.x1),max(a.y1,box.y1),min(a.score,box.score)) }
        }
        return rows.filter { it.width >= .045f && it.height <= .15f && it.width > it.height*1.4f }
            .sortedByDescending { it.score*it.width }.take(MAX_REGIONS)
    }
    class Tracker {
        private var previous = emptyList<Box>()
        var regions = emptyList<Box>(); private set
        fun reset() { previous=emptyList();regions=emptyList() }
        fun update(input: List<Box>): List<Box> {
            val rows=lines(input)
            regions=rows.filter { row ->
                // Immediate high-confidence subtitle bands; scene-centre text needs a second stationary hit.
                (row.score >= .65f && (row.y0 >= .55f || row.y1 <= .22f)) || previous.any { it.overlap(row)>.55f }
            }.map { row ->
                val old=previous.maxByOrNull { it.overlap(row) }?.takeIf { it.overlap(row)>.65f }
                // Union slight detector jitter, but never average in a missing glyph.
                val a=old ?: row
                Box(max(0f,min(a.x0,row.x0)-.004f),max(0f,min(a.y0,row.y0)-.003f),
                    min(1f,max(a.x1,row.x1)+.004f),min(1f,max(a.y1,row.y1)+.003f),row.score)
            }
            previous=rows
            return regions
        }
        fun crop(): Crop? {
            if(regions.isEmpty())return null
            val x=max(0f,regions.minOf { it.x0 }-.05f);val y=max(0f,regions.minOf { it.y0 }-.05f)
            val w=min(1f,regions.maxOf { it.x1 }+.05f)-x;val h=min(1f,regions.maxOf { it.y1 }+.05f)-y
            return if(w*h<.65f) Crop(x,y,w,h) else null
        }
    }
    fun flatten(boxes: List<Box>) = boxes.take(MAX_REGIONS).flatMap { listOf(it.x0,it.y0,it.x1,it.y1) }.toFloatArray()
    fun current(resultPts: Long,shownPts: Long,ttlUs: Long = 900_000) = resultPts >= 0 && shownPts >= resultPts && shownPts-resultPts <= ttlUs
    fun discontinuity(previous: Long,pts: Long) = previous >= 0 && (pts < previous || abs(pts-previous)>1_500_000)
    fun edgeChanged(previous: FloatArray?,current: FloatArray): Boolean = previous!=null && previous.size==current.size &&
        current.indices.sumOf { abs(current[it]-previous[it]).toDouble() }/current.size.coerceAtLeast(1)>.08
}
