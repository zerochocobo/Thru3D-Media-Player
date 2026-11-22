package org.vrpassthroughplayer.plugin

import android.content.Context
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong

/** Still-photo depth models. [cache] names a map in the photo's directory and in [PhotoDepthStore]. */
internal enum class PhotoDepthModel(val cache: String, val width: Int, val height: Int) {
    /** DA2 Small 518x518: the best still-photo depth (DIODE indoor AbsRel 0.062). */
    QUALITY("da2-518-stretch-v2", 518, 518),
    /** ZipDepth base 512x512: ~10x faster, softer edges (indoor AbsRel 0.092). Resampled to 518. */
    FAST("zip-512-stretch-v1", 512, 512);

    companion object {
        fun ofCache(name: String): PhotoDepthModel? = entries.firstOrNull { it.cache == name }
    }
}

/** The user's photo 3D conversion setting. PROGRESSIVE shows the fast map first and refines it
 * with the quality model once the picture stays on screen (Godot asks; see refine_photo_3d). */
internal enum class PhotoDepthMode(val key: String) {
    PROGRESSIVE("progressive"), QUALITY("quality"), FAST("fast");
    /** Model of a first request; a kept quality map always wins (PhotoBridge). */
    val firstModel get() = if (this == QUALITY) PhotoDepthModel.QUALITY else PhotoDepthModel.FAST
    companion object { fun of(key: String) = entries.firstOrNull { it.key == key } }
}

/** Foreground and preloads share the DepthWorker's photo sessions, one per model. */
internal object PhotoDepthRuntime {
    const val IDLE_MS = 60_000L
    @Volatile var mode = PhotoDepthMode.QUALITY // Godot sets the saved choice (default progressive) when viewing starts.
    private val sessions by lazy { PhotoDepthModel.entries.associateWith { PhotoDepthSession(DepthNative::close) } }
    private val idle = Runnable { sessions.values.forEach { it.close() } }
    private val activity = AtomicLong()

    /** The first-request model's session is resident: optional work need not budget for building it. */
    fun alive(): Boolean = sessions.getValue(mode.firstModel).alive()

    fun <T> run(context: Context, model: PhotoDepthModel, checkCurrent: () -> Unit, process: (Long, Boolean) -> T): T {
        val worker = DepthWorker.handler
        activity.incrementAndGet()
        worker.removeCallbacks(idle)
        try {
            return sessions.getValue(model).use({ ModelPreparationGate.run {
                checkCurrent()
                val directory = PhotoDepthInput.cacheDirectory(context).path
                if (model == PhotoDepthModel.FAST) DepthNative.createPhotoFast(context.assets, directory)
                else DepthNative.createPhoto(context.assets, directory)
            } }, process)
        } finally { worker.postDelayed(idle, IDLE_MS) }
    }

    /** Photo viewing (re)opened: build the first-request session beside the first file's IO/colour decode,
     * not after it. Counting this as activity first voids a release posted by the previous picture's close.
     * The first inference of a new session is slower (~0.4 s for DA2 on Quest 3), so run one on blank input
     * unless real work waits. Progressive viewing builds the quality session only when a refinement needs it:
     * on Quest 2 its build and blank run would hold the worker for seconds ahead of the next fast map. */
    fun warm(context: Context, busy: () -> Boolean) {
        val worker = DepthWorker.handler
        val model = mode.firstModel
        activity.incrementAndGet()
        worker.post {
            if (busy()) return@post
            runCatching { synchronized(BackgroundResourceBudget.photoWorkLock) {
                run(context, model, {}) { handle, reused ->
                    if (!reused && !busy()) {
                        val w = model.width; val h = model.height
                        val rgb = ByteBuffer.allocateDirect(w * h * 12).order(ByteOrder.LITTLE_ENDIAN)
                        val near = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
                        DepthNative.processPhoto(handle, rgb, near, 0, 0, w, h)
                    }
                }
            } }
        }
    }

    fun release() {
        val worker = DepthWorker.handler
        val version = activity.incrementAndGet()
        worker.removeCallbacks(idle)
        // All earlier selections are cancelled before this is posted. Never close during inference.
        worker.post {
            if (activity.get() != version) return@post
            sessions.values.forEach { it.close() }
            runCatching { RenderBridgeNative.photoReleasePairs() } // the stereo pairs kept for the picture layer
            PhotoStereo.releaseColour()
        }
    }
}
