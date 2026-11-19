package org.vrpassthroughplayer.plugin

import android.view.Surface
import java.util.concurrent.ConcurrentHashMap

/** Opaque login identity prevents late callbacks from attaching a previous account's Surface. */
object GeckoLoginSurfaceBridge {
    private val sessions = ConcurrentHashMap<String, GeckoLoginSession>()
    internal fun install(value: GeckoLoginSession) { sessions[value.id] = value }
    internal fun remove(value: GeckoLoginSession) { sessions.remove(value.id, value) }
    /** The player's own keyboard edits login fields (generic OpenXR runtimes may not show the system IME in VR). */
    @Volatile @JvmStatic var customKeyboard = false
        private set
    @JvmStatic fun keyboardMode(enabled: Boolean) { customKeyboard = enabled }
    @JvmStatic fun attach(id: String, surface: Surface, width: Int, height: Int, generation: Long): Boolean =
        sessions[id]?.attach(surface, width, height, generation) ?: false
    @JvmStatic fun detach(id: String, generation: Long): Boolean = sessions[id]?.detach(generation) ?: true
}
