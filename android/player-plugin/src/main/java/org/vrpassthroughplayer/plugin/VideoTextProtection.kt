package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

/** Detection never holds a colour lease after staging; GL/PBO operations only run on the GL owner.
 * One readback/inference at a time. Model/scene results are generation scoped and immutable. */
internal class VideoTextProtection(private val context: () -> Context?,private val redraw: () -> Unit) : AutoCloseable {
    private val lock=Any()
    private val worker=TextWorker.handler
    private var closed=false
    private var epoch=1L
    private var generation=-1L
    private var format=-1L
    private var lastRequestedPts=-1L
    private var lastPts=-1L
    private var handle=0L
    private var loading=false
    private var busy=false
    private var lastStart=0L
    private var lastFull=0L
    private var lastCuts=-1L
    private var error=""
    private var detectMs=0.0
    private var updates=0L
    private var resultPts=-1L
    private var latest=FloatArray(0)
    private val tracker=TextProtectionPolicy.Tracker()
    private val transition=TextProtectionTransition()
    private var latestBoxes=emptyList<TextProtectionPolicy.Box>()
    private var animationQueued=false
    private var animationTicket=0L
    private data class Input(val epoch: Long,val pts: Long,val w: Int,val h: Int,val crop: TextProtectionPolicy.Crop,val rgb: ByteBuffer,val renderer: Long)
    private var pending: Input?=null
    private var fullSignature: FloatArray?=null
    private var edgeSignature: FloatArray?=null
    private var changed=true

    fun stats(): Map<String,Any> = synchronized(lock) { mapOf("ready" to (handle>0),"busy" to busy,"error" to error,"detect_ms" to detectMs,"updates" to updates,"regions" to latest.size/4) }
    private fun reset() {
        epoch++;transition.reset();latestBoxes=emptyList();animationQueued=false;animationTicket++;lastRequestedPts=-1L;lastStart=0;lastFull=0;latest=FloatArray(0);resultPts=-1;tracker.reset();fullSignature=null;edgeSignature=null;changed=true
        if(handle>0)TextDetectorNative.cancel(handle,epoch)
    }
    private fun start() {
        if(loading||handle>0||closed||error.isNotEmpty())return
        loading=true
        worker.post {
            var created=0L
            try {
                check(NarrationNative.supported()) { "text_runtime_unavailable" }
                val app=context() ?: error("text_context_unavailable")
                val manifest=JSONObject(app.assets.open("text-protection/model.json").bufferedReader().use { it.readText() })
                val directory=File(app.filesDir,manifest.getString("directory")).canonicalFile
                require(directory.path.startsWith(app.filesDir.canonicalPath+File.separator))
                NarrationModels.ensure(directory,manifest.getJSONObject("files"),{app.assets.open(manifest.getString("directory")+"/"+it)},
                    { synchronized(lock) { !closed } },{ _ -> })
                created=TextDetectorNative.create(File(directory,"multi_PP-OCRv6_det_tiny.onnx").path)
                check(created>0) { "text_model_unavailable" }
                synchronized(lock) { if(!closed) {handle=created;created=0;TextDetectorNative.cancel(handle,epoch)} }
                redraw()
            } catch(failure: Throwable) { failed(failure) }
            finally { if(created>0)TextDetectorNative.destroy(created);synchronized(lock) { loading=false } }
        }
    }
    fun failed(failure: Throwable) {
        val old=synchronized(lock) {
            if(closed||error.isNotEmpty())return
            error=failure.message ?: "text_detection_failed";latest=FloatArray(0);latestBoxes=emptyList();transition.reset()
            android.util.Log.w("QuestText","Text protection unavailable: $error")
            val value=handle;handle=0;value
        }
        if(old>0)worker.post { TextDetectorNative.destroy(old) }
        redraw()
    }
    /** Reuse an already-read depth input: 128 local edge samples, no additional GL readback.
     * Edges are an urgency hint only; a noisy background can at most select the bounded 4 Hz budget. */
    fun observe(rgb: ByteBuffer,width: Int,height: Int,pair: JSONObject) = synchronized(lock) {
        if(closed||width<3||height<3)return@synchronized
        val content=pair.optJSONArray("model_content_rect") ?: return@synchronized
        val data=rgb.asFloatBuffer();val plane=width*height
        if(data.capacity()!=plane*3)return@synchronized
        val boxes=latest.toList().chunked(4)
        val x0=boxes.minOfOrNull { it[0] } ?: .05f;val x1=boxes.maxOfOrNull { it[2] } ?: .95f
        val y0=boxes.minOfOrNull { it[1] } ?: .55f;val y1=boxes.maxOfOrNull { it[3] } ?: .95f
        fun gray(x: Int,y: Int): Float { val p=y*width+x;return data.get(p)*.299f+data.get(plane+p)*.587f+data.get(plane*2+p)*.114f }
        val signature=FloatArray(128) { i ->
            val u=x0+(i%16+.5f)/16*(x1-x0);val v=y0+(i/16+.5f)/8*(y1-y0)
            val x=((content.getDouble(0)+u*content.getDouble(2))*width).toInt().coerceIn(1,width-2)
            val y=((content.getDouble(1)+v*content.getDouble(3))*height).toInt().coerceIn(1,height-2)
            kotlin.math.abs(gray(x+1,y)-gray(x-1,y))+kotlin.math.abs(gray(x,y+1)-gray(x,y-1))
        }
        if(TextProtectionPolicy.edgeChanged(edgeSignature,signature))changed=true
        edgeSignature=signature
    }
    /** Called for every bridge tick, including pause. Poll only after a zero-time fence query. */
    fun poll(renderer: Long) {
        val input=synchronized(lock) { pending } ?: return
        if(input.renderer!=renderer) {
            synchronized(lock) { pending=null;busy=false;reset() }
            return
        }
        if(!RenderBridgeNative.readPortraitInput(renderer,input.rgb))return
        synchronized(lock) { if(pending!==input)return;pending=null }
        worker.post {
            try {
                val active=synchronized(lock) { if(closed||input.epoch!=epoch)0 else handle }
                if(active<=0)return@post
                val report=JSONObject(TextDetectorNative.detect(active,input.rgb,input.w,input.h,input.epoch))
                synchronized(lock) {
                    if(closed||input.epoch!=epoch)return@synchronized
                    check(report.optString("state")=="ready") { "text_detection_failed" }
                    if(input.crop==TextProtectionPolicy.Crop()) {
                        val floats=input.rgb.asFloatBuffer();val signature=FloatArray(144) { p ->
                            val x=(p%16)*input.w/16;val y=(p/16)*input.h/9;floats.get(y*input.w+x)
                        }
                        val prev=fullSignature
                        if(prev!=null&&signature.indices.sumOf { kotlin.math.abs(signature[it]-prev[it]).toDouble() }/signature.size>.25)tracker.reset()
                        fullSignature=signature
                    }
                    val boxes=report.getJSONArray("boxes")
                    val rows=(0 until boxes.length()).mapNotNull { i -> val b=boxes.getJSONArray(i)
                        input.crop.map(TextProtectionPolicy.Box(b.getDouble(0).toFloat(),b.getDouble(1).toFloat(),b.getDouble(2).toFloat(),b.getDouble(3).toFloat(),b.getDouble(4).toFloat())).takeIf { it.valid() } }
                    latestBoxes=tracker.update(rows);latest=TextProtectionPolicy.flatten(latestBoxes);resultPts=input.pts
                    detectMs=report.optDouble("detect_ms",0.0);updates++
                }
                redraw()
            } catch(failure: Throwable) { if(synchronized(lock) { input.epoch==epoch&&!closed })failed(failure) }
            finally { synchronized(lock) { busy=false } }
        }
    }
    /** Poll and stage are serialized on the owner; rectangles are immutable source UV snapshots. */
    fun frame(renderer: Long,token: Long,pair: JSONObject): TextProtectionTransition.Snapshot = synchronized(lock) {
        if(closed)return TextProtectionTransition.Snapshot.EMPTY
        val pts=pair.getLong("pts_us");val gen=pair.getLong("generation");val revision=pair.getLong("format_revision")
        val cuts=pair.optJSONObject("depth_kernel")?.optLong("cuts",lastCuts) ?: lastCuts
        if(gen!=generation||revision!=format||(lastCuts>=0&&cuts>lastCuts)||TextProtectionPolicy.discontinuity(lastPts,pts)) { reset();generation=gen;format=revision }
        lastPts=pts;lastCuts=cuts
        start()
        val now=System.nanoTime()
        val interval=max(if(changed)250.0 else 500.0,detectMs/.15)*1_000_000
        if(handle>0&&!busy&&pending==null&&pts!=lastRequestedPts&&now-lastStart>=interval&&error.isEmpty()) {
            val full=now-lastFull>2_000_000_000L
            val crop=if(full)TextProtectionPolicy.Crop() else tracker.crop() ?: TextProtectionPolicy.Crop()
            val sourceW=pair.optInt("color_width",pair.optInt("width",1920));val sourceH=pair.optInt("color_height",pair.optInt("height",1080))
            val (w,h)=TextProtectionPolicy.dimensions((sourceW*crop.w).toInt(),(sourceH*crop.h).toInt())
            val rgb=ByteBuffer.allocateDirect(w*h*12).order(ByteOrder.nativeOrder())
            RenderBridgeNative.stagePortraitInput(renderer,token,crop.content(),w,h)
            lastRequestedPts=pts;pending=Input(epoch,pts,w,h,crop,rgb,renderer);busy=true;lastStart=now;changed=false
            if(crop==TextProtectionPolicy.Crop())lastFull=now
        }
        val targets=if(TextProtectionPolicy.current(resultPts,pts,max(900_000L,(interval/1000*2).toLong()).coerceAtMost(2_000_000L)))latestBoxes else emptyList()
        // Quantize animation to ~30 Hz so Fill does not rebuild its full-resolution map at XR rate.
        val snapshot=transition.sample(targets,(now/1_000_000/33)*33)
        if(snapshot.animating&&!animationQueued) {
            animationQueued=true;val ticket=++animationTicket
            worker.postDelayed({
                val active=synchronized(lock) { if(closed||ticket!=animationTicket)false else {animationQueued=false;true} }
                if(active)redraw() // paused only; ordinary playback already supplies new frames
            },33)
        }
        snapshot
    }
    override fun close() {
        val old=synchronized(lock) { if(closed)return;closed=true;reset();pending=null;val value=handle;handle=0;value }
        // Same worker as inference/load. The native registry also holds a counted running lease.
        if(old>0)worker.post { TextDetectorNative.destroy(old) }
    }
    private object TextWorker { val handler by lazy { Handler(HandlerThread("VideoText").apply { start() }.looper) } }
}
