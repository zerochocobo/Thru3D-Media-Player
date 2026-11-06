package org.vrpassthroughplayer.plugin

import android.view.Surface

/** JavaClassWrapper entry point. Only Godot passes surfaces; no method is exposed to pages. */
object WebBrowserSurfaceBridge {
    private class Release(val owner: WebBrowser, val generation: Long) { @Volatile var state = 0 }
    private val releases = java.util.concurrent.ConcurrentHashMap<Int,Release>()
    private val transfer = java.util.concurrent.Executors.newSingleThreadExecutor { task -> Thread(task,"BrowserSurfaceRelease").apply { isDaemon=true } }
    @Volatile private var browser: WebBrowser? = null
    internal fun install(value: WebBrowser) { browser = value }
    internal fun remove(value: WebBrowser) { if (browser === value) { browser = null;releases.clear() } }
    @JvmStatic fun configureViewport(lowEnd: Boolean): Boolean = browser?.configureViewport(lowEnd) ?: lowEnd
    @JvmStatic fun attach(surface: Surface, width: Int, height: Int, generation: Long): Boolean =
        browser?.attach(surface, width, height, generation) ?: false
    @JvmStatic fun detach(generation: Long) { browser?.detach(generation) }
    @JvmStatic fun detachBeforeSessionStop(generation: Long): Boolean = browser?.detachBeforeSessionStop(generation) ?: true
    @JvmStatic fun attachWindow(window: Int, surface: Surface, width: Int, height: Int, generation: Long): Boolean =
        browser?.attach(surface, width, height, generation, window) ?: false
    @JvmStatic fun detachWindowBeforeSessionStop(window: Int, generation: Long): Boolean =
        browser?.detachBeforeSessionStop(generation, window) ?: true
    @JvmStatic fun releaseWindowForResize(window: Int, generation: Long): Boolean =
        browser?.releaseForResize(generation, window) ?: true
    /** Godot's frame loop only queues/polls; the existing UI acknowledgement runs off-frame. */
    @JvmStatic fun requestWindowRelease(window: Int, generation: Long): Boolean {
        val owner=browser ?: return false
        if(window !in 1..4 || generation<=0) return false
        val old=releases[window]
        if(old?.owner===owner && old.generation==generation && old.state>=0) return true
        val request=Release(owner,generation);releases[window]=request
        transfer.execute {
            val ok=runCatching { owner.releaseForResize(generation,window) }.getOrDefault(false)
            request.state=if(ok && browser===owner) 1 else -1
        }
        return true
    }
    @JvmStatic fun windowReleaseState(window: Int,generation: Long): Int = releases[window]?.let {
        if(it.owner===browser && it.generation==generation) it.state else 0
    } ?: 0
}
