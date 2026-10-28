package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import kotlin.math.*

/** Pure coordinate/age policy. Rects map source UV to model UV, including letterbox or zoom. */
internal object PortraitDepthGeometry {
    const val GRID = 64
    const val MAX_AGE_US = 750_000L
    data class Crop(val rect: FloatArray, val content: IntArray)
    data class Mask(val bytes: ByteBuffer, val rect: FloatArray, val bounds: FloatArray)
    data class Map(val frame: Long, val pts: Long, val shot: Long, val crop: Crop, val mask: Mask,
                   val width: Int, val height: Int, val residual: FloatArray)

    fun crop(bounds: FloatArray, sourceWidth: Int, sourceHeight: Int, width: Int, height: Int): Crop {
        val w = (bounds[2]-bounds[0])*1.5f; val h = (bounds[3]-bounds[1])*1.5f
        val x0 = ((bounds[0]+bounds[2]-w)*.5f).coerceAtLeast(0f)
        val y0 = ((bounds[1]+bounds[3]-h)*.5f).coerceAtLeast(0f)
        val x1 = ((bounds[0]+bounds[2]+w)*.5f).coerceAtMost(1f)
        val y1 = ((bounds[1]+bounds[3]+h)*.5f).coerceAtMost(1f)
        require(x1>x0 && y1>y0)
        val aspect = (x1-x0)*sourceWidth/((y1-y0)*sourceHeight)
        val cw = min(width, (height*aspect).roundToInt()).coerceAtLeast(1)
        val ch = min(height, (width/aspect).roundToInt()).coerceAtLeast(1)
        val x = (width-cw)/2; val y = (height-ch)/2
        val sx = cw.toFloat()/width/(x1-x0); val sy = ch.toFloat()/height/(y1-y0)
        return Crop(floatArrayOf(x.toFloat()/width-x0*sx, y.toFloat()/height-y0*sy, sx, sy), intArrayOf(x,y,cw,ch))
    }

    private fun sample(data: FloatArray, w: Int, h: Int, x: Float, y: Float): Float {
        if (x !in 0f..1f || y !in 0f..1f) return 0f
        val px = (x*w-.5f).coerceIn(0f,(w-1).toFloat()); val py = (y*h-.5f).coerceIn(0f,(h-1).toFloat())
        val ix = px.toInt(); val iy = py.toInt(); val fx = px-ix; val fy = py-iy
        val jx = min(w-1,ix+1); val jy = min(h-1,iy+1)
        return (data[iy*w+ix]*(1-fx)+data[iy*w+jx]*fx)*(1-fy)+(data[jy*w+ix]*(1-fx)+data[jy*w+jx]*fx)*fy
    }
    private fun alpha(mask: Mask, x: Float, y: Float): Float {
        val u = mask.rect[0]+x*mask.rect[2]; val v = mask.rect[1]+y*mask.rect[3]
        if (u !in 0f..1f || v !in 0f..1f) return 0f
        val ix = (u*GRID).toInt().coerceIn(0,GRID-1); val iy = (v*GRID).toInt().coerceIn(0,GRID-1)
        return (mask.bytes.get(iy*GRID+ix).toInt() and 255)/255f
    }
    fun residual(near: ByteBuffer, width: Int, height: Int, crop: Crop, mask: Mask): FloatArray {
        val values = FloatArray(width*height) { near.getFloat(it*4).also { n -> require(n.isFinite() && n in 0f..1f) } }
        val foreground = ArrayList<Float>()
        for (y in 0 until height step 2) for (x in 0 until width step 2) {
            val sx = ((x+.5f)/width-crop.rect[0])/crop.rect[2]
            val sy = ((y+.5f)/height-crop.rect[1])/crop.rect[3]
            if (alpha(mask,sx,sy) > .8f) foreground.add(values[y*width+x])
        }
        if (foreground.size < 24) return FloatArray(width*height)
        foreground.sort()
        val center = foreground[foreground.size/2]
        val range = max(.15f, foreground[foreground.size*9/10]-foreground[foreground.size/10])
        return FloatArray(values.size) { i ->
            val x = i%width; val y = i/width
            val local = max(abs(values[i]-values[y*width+max(0,x-2)]),
                max(abs(values[i]-values[y*width+min(width-1,x+2)]),
                    max(abs(values[i]-values[max(0,y-2)*width+x]),abs(values[i]-values[min(height-1,y+2)*width+x]))))
            // Suppress unreliable depth cliffs. The final 64-grid slope limiter below also bounds
            // displacement across mesh triangles, without cutting holes into the current Alpha.
            ((values[i]-center)/range).coerceIn(-.5f,.5f) * (1f-local/.25f).coerceIn(0f,1f)
        }
    }

    fun align(map: Map, current: Mask, frame: Long, pts: Long, shot: Long): ByteBuffer? {
        val age = pts-map.pts
        if (shot != map.shot || frame < map.frame || age !in 0..MAX_AGE_US) return null
        val a = map.mask.bounds; val b = current.bounds
        val sx = (a[2]-a[0])/(b[2]-b[0]); val sy = (a[3]-a[1])/(b[3]-b[1])
        if (!sx.isFinite() || !sy.isFinite() || sx !in .6f..1.67f || sy !in .6f..1.67f ||
            abs((a[0]+a[2]-b[0]-b[2])*.5f) > .3f || abs((a[1]+a[3]-b[1]-b[3])*.5f) > .3f) return null
        val fade = ((MAX_AGE_US-age).toFloat()/350_000).coerceIn(0f,1f)
        val field = FloatArray(GRID*GRID)
        for (y in 0 until GRID) for (x in 0 until GRID) {
            val u = ((x+.5f)/GRID-current.rect[0])/current.rect[2]
            val v = ((y+.5f)/GRID-current.rect[1])/current.rect[3]
            val oldX = a[0]+(u-b[0])*sx; val oldY = a[1]+(v-b[1])*sy
            val support = ((min(alpha(current,u,v),alpha(map.mask,oldX,oldY))-.4f)/.5f).coerceIn(0f,1f)
            field[y*GRID+x] = sample(map.residual,map.width,map.height,
                map.crop.rect[0]+oldX*map.crop.rect[2],map.crop.rect[1]+oldY*map.crop.rect[3])*fade*support
        }
        // A magnitude envelope bounds all four neighbouring slopes, preserving sign and exact
        // zero in newly uncovered pixels. Opposite signs each get half the allowed step.
        val magnitude = FloatArray(field.size) { abs(field[it]) }
        for (i in field.indices) for (direction in 0..3) {
            val j = when (direction) {
                0 -> if (i%GRID>0) i-1 else i
                1 -> if (i%GRID<GRID-1) i+1 else i
                2 -> if (i>=GRID) i-GRID else i
                else -> if (i+GRID<field.size) i+GRID else i
            }
            if (field[i]*field[j] < 0) magnitude[i] = min(magnitude[i],.04f)
        }
        for (i in field.indices) {
            if (i%GRID>0) magnitude[i] = min(magnitude[i],magnitude[i-1]+.08f)
            if (i>=GRID) magnitude[i] = min(magnitude[i],magnitude[i-GRID]+.08f)
        }
        for (i in field.lastIndex downTo 0) {
            if (i%GRID<GRID-1) magnitude[i] = min(magnitude[i],magnitude[i+1]+.08f)
            if (i+GRID<field.size) magnitude[i] = min(magnitude[i],magnitude[i+GRID]+.08f)
        }
        return ByteBuffer.allocateDirect(GRID*GRID).apply {
            for (i in field.indices) put(i, (128+sign(field[i])*magnitude[i]*254).roundToInt().coerceIn(1,255).toByte())
        }
    }
}
