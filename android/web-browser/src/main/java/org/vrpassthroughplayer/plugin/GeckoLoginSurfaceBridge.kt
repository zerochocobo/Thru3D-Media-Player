package org.vrpassthroughplayer.plugin

import android.view.Surface
import java.util.concurrent.ConcurrentHashMap

/** Opaque login identity prevents late callbacks from attaching a previous account's Surface. */
object GeckoLoginSurfaceBridge {
    private val sessions = ConcurrentHashMap<String, GeckoLoginSession>()
    internal fun install(value: GeckoLoginSession) { sessions[value.id] = value }
    internal fun remove(value: GeckoLoginSession) { sessions.remove(value.id, value) }
    @JvmStatic fun attach(id: String, surface: Surface, width: Int, height: Int, generation: Long): Boolean =
        sessions[id]?.attach(surface, width, height, generation) ?: false
    @JvmStatic fun detach(id: String, generation: Long): Boolean = sessions[id]?.detach(generation) ?: true
}
