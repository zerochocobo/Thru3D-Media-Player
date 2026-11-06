package org.vrpassthroughplayer.plugin

import android.view.Surface

/** Called on Godot's frame thread. Detach Gecko before destroying a producer. */
object WebBrowserLayerNative {
    init { System.loadLibrary("quest_video_layer") }
    @JvmStatic external fun create(id: Int, instance: Long, session: Long, getProc: Long, width: Int, height: Int): Surface?
    @JvmStatic external fun destroy(id: Int)
    @JvmStatic external fun surface(id: Int): Surface?
    @JvmStatic external fun producerSize(id: Int, width: Int, height: Int): Boolean
    @JvmStatic external fun update(id: Int, space: Long, values: FloatArray): Long
    @JvmStatic external fun updateEye(id: Int, space: Long, values: FloatArray, eye: Int): Long
    @JvmStatic external fun updateEyeAlpha(id: Int, space: Long, values: FloatArray, eye: Int, alpha: Boolean): Long
}
