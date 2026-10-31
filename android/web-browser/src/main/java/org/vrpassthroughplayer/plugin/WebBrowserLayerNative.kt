package org.vrpassthroughplayer.plugin

import android.view.Surface

/** Called on Godot's frame thread. Detach Gecko before destroying a producer. */
object WebBrowserLayerNative {
    init { System.loadLibrary("quest_video_layer") }
    @JvmStatic external fun create(id: Int, instance: Long, session: Long, getProc: Long, width: Int, height: Int): Surface?
    @JvmStatic external fun destroy(id: Int)
    @JvmStatic external fun update(id: Int, space: Long, values: FloatArray): Long
}
