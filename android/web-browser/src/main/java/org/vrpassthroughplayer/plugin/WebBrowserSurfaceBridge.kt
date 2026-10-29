package org.vrpassthroughplayer.plugin

import android.view.Surface

/** JavaClassWrapper entry point. Only Godot passes surfaces; no method is exposed to pages. */
object WebBrowserSurfaceBridge {
    @Volatile private var browser: WebBrowser? = null
    internal fun install(value: WebBrowser) { browser = value }
    internal fun remove(value: WebBrowser) { if (browser === value) browser = null }
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
}
