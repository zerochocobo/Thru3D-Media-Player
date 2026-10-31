package org.vrpassthroughplayer.plugin

import org.json.JSONObject

internal interface AccountWebLogin {
    fun open()
    fun snapshot(): JSONObject
    fun frame(): ByteArray
    fun action(action: String, x: Float, y: Float, text: String)
    fun pause(value: Boolean)
    fun close()
}
