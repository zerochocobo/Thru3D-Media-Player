package org.vrpassthroughplayer.plugin

import android.content.Context
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong

/** Foreground and preloads share the DepthWorker's single photo session. */
internal object PhotoDepthRuntime {
    const val IDLE_MS = 60_000L
    private val session by lazy { PhotoDepthSession(DepthNative::close) }
    private val idle = Runnable { session.close() }
    private val activity = AtomicLong()

    /** The model session is resident: optional work need not budget for building it. */
    fun alive(): Boolean = session.alive()

    fun <T> run(context: Context, checkCurrent: () -> Unit, process: (Long, Boolean) -> T): T {
        val worker = DepthWorker.handler
        activity.incrementAndGet()
        worker.removeCallbacks(idle)
        try {
            return session.use({ ModelPreparationGate.run {
                checkCurrent()
                DepthNative.createPhoto(context.assets, PhotoDepthInput.cacheDirectory(context).path)
            } }, process)
        } finally { worker.postDelayed(idle, IDLE_MS) }
    }

    /** Photo viewing (re)opened: build the session beside the first file's IO/colour decode, not after it.
     * Counting this as activity first voids a release posted by the previous picture's close. The first
     * inference of a new session is ~0.4 s slower on Quest 3, so run one on blank input unless real work waits. */
    fun warm(context: Context, busy: () -> Boolean) {
        val worker = DepthWorker.handler
        activity.incrementAndGet()
        worker.post {
            if (busy()) return@post
            runCatching { synchronized(BackgroundResourceBudget.photoWorkLock) {
                run(context, {}) { handle, reused ->
                    if (!reused && !busy()) {
                        val w = PhotoDepthInput.WIDTH; val h = PhotoDepthInput.HEIGHT
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
        worker.post { if (activity.get() == version) session.close() }
    }
}
