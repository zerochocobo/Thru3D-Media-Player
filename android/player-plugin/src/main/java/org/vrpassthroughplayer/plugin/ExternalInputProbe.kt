package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Window
import org.json.JSONArray
import org.json.JSONObject

/** Observes keys, gamepads and mice as they reach the activity window, before Godot or the
 *  system fallback (volume) sees them; never consumes an event. Evidence is codes and device
 *  classes only: printing keys are withheld and external device names are never recorded. */
internal class ExternalInputProbe private constructor(
    private val inner: Window.Callback, private val emit: (String) -> Unit) : Window.Callback by inner {
    private val axes = HashMap<String, Int>()
    private val hovered = HashMap<Int, Long>()

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.repeatCount == 0) runCatching { emit(key(event).toString()) }
        return inner.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        runCatching { motion(event) }
        return inner.dispatchGenericMotionEvent(event)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        runCatching { if (event.isFromSource(InputDevice.SOURCE_MOUSE)) mouse(event) }
        return inner.dispatchTouchEvent(event)
    }

    /** Raw key and scan codes tell a vendor remap (PICO head control) from the key it replaced. */
    private fun key(event: KeyEvent): JSONObject = JSONObject().put("kind", "key").put("layer", "android")
        .put("action", if (event.action == KeyEvent.ACTION_DOWN) "down" else "up")
        .put("code", keyCode(KeyEvent.keyCodeToString(event.keyCode), event.isPrintingKey))
        .put("keycode", if (event.isPrintingKey) 0 else event.keyCode).put("scan", if (event.isPrintingKey) 0 else event.scanCode)
        .put("source", sourceNames(event.source)).put("device", event.deviceId)
        .put("canceled", event.isCanceled).put("system", event.isSystem)

    private fun motion(event: MotionEvent) {
        if (event.isFromSource(InputDevice.SOURCE_MOUSE)) return mouse(event)
        if (event.actionMasked != MotionEvent.ACTION_MOVE) return
        if (!event.isFromSource(InputDevice.SOURCE_JOYSTICK) && !event.isFromSource(InputDevice.SOURCE_GAMEPAD)) return
        for (axis in AXES) {
            val id = "${event.deviceId}/$axis"
            val previous = axes[id] ?: 0
            val state = axisState(previous, event.getAxisValue(axis))
            if (state == previous) continue
            axes[id] = state
            emit(JSONObject().put("kind", "axis").put("layer", "android").put("axis", MotionEvent.axisToString(axis))
                .put("state", state).put("source", sourceNames(event.source)).put("device", event.deviceId).toString())
        }
    }

    /** Buttons are what matter; movement only proves a pointer exists, at most every two seconds. */
    private fun mouse(event: MotionEvent) {
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> "down"; MotionEvent.ACTION_UP -> "up"
            MotionEvent.ACTION_BUTTON_PRESS -> "button_press"; MotionEvent.ACTION_BUTTON_RELEASE -> "button_release"
            MotionEvent.ACTION_SCROLL -> "scroll"
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_MOVE -> "move"
            else -> return
        }
        if (action == "move") {
            val now = android.os.SystemClock.uptimeMillis()
            if (now - (hovered[event.deviceId] ?: Long.MIN_VALUE / 2) < MOVE_INTERVAL_MS) return
            hovered[event.deviceId] = now
        }
        emit(JSONObject().put("kind", "mouse").put("layer", "android").put("action", action)
            .put("buttons", event.buttonState).put("source", sourceNames(event.source)).put("device", event.deviceId).toString())
    }

    companion object {
        private val AXES = intArrayOf(MotionEvent.AXIS_X, MotionEvent.AXIS_Y, MotionEvent.AXIS_Z, MotionEvent.AXIS_RZ,
            MotionEvent.AXIS_RX, MotionEvent.AXIS_RY, MotionEvent.AXIS_HAT_X, MotionEvent.AXIS_HAT_Y,
            MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_BRAKE, MotionEvent.AXIS_GAS)
        private const val MOVE_INTERVAL_MS = 2000L
        private val SOURCES = listOf(InputDevice.SOURCE_KEYBOARD to "keyboard", InputDevice.SOURCE_DPAD to "dpad",
            InputDevice.SOURCE_GAMEPAD to "gamepad", InputDevice.SOURCE_JOYSTICK to "joystick",
            InputDevice.SOURCE_MOUSE to "mouse", InputDevice.SOURCE_MOUSE_RELATIVE to "mouse_relative",
            InputDevice.SOURCE_TOUCHSCREEN to "touchscreen", InputDevice.SOURCE_TOUCHPAD to "touchpad",
            InputDevice.SOURCE_TRACKBALL to "trackball", InputDevice.SOURCE_STYLUS to "stylus",
            InputDevice.SOURCE_ROTARY_ENCODER to "rotary")
        private var listener: InputManager.InputDeviceListener? = null

        fun sourceNames(source: Int): JSONArray {
            val names = JSONArray()
            for ((mask, name) in SOURCES) if (source and mask == mask) names.put(name)
            return names
        }

        /** Unknown vendor codes stay numeric ("1001"); a printing key could be typed text. */
        fun keyCode(name: String, printing: Boolean): String = if (printing) "printable" else name

        /** Hysteresis keeps a resting stick near the threshold from flooding the log. */
        fun axisState(previous: Int, value: Float): Int = when {
            !value.isFinite() -> 0
            value > 0.6f -> 1
            value < -0.6f -> -1
            previous != 0 && value * previous > 0.4f -> previous
            else -> 0
        }

        private fun device(device: InputDevice, event: String): JSONObject {
            val record = JSONObject().put("kind", "device").put("layer", "android").put("event", event)
                .put("device", device.id).put("source", sourceNames(device.sources))
                .put("vendor", device.vendorId).put("product", device.productId)
                .put("external", device.isExternal).put("virtual", device.isVirtual)
                .put("keyboard", when (device.keyboardType) {
                    InputDevice.KEYBOARD_TYPE_ALPHABETIC -> "alphabetic"
                    InputDevice.KEYBOARD_TYPE_NON_ALPHABETIC -> "non_alphabetic"; else -> "none" })
            // Built-in names identify hardware ("gpio-keys"); paired devices may carry a person's name.
            if (!device.isExternal) record.put("name", device.name)
            return record
        }

        fun install(activity: Activity, emit: (String) -> Unit) = activity.runOnUiThread {
            val window = activity.window ?: return@runOnUiThread
            val current = window.callback ?: return@runOnUiThread
            if (current is ExternalInputProbe) return@runOnUiThread
            window.callback = ExternalInputProbe(current, emit)
            val input = activity.getSystemService(InputManager::class.java) ?: return@runOnUiThread
            for (id in input.inputDeviceIds) input.getInputDevice(id)?.let { runCatching { emit(device(it, "present").toString()) } }
            val watch = object : InputManager.InputDeviceListener {
                override fun onInputDeviceAdded(id: Int) { input.getInputDevice(id)?.let { runCatching { emit(device(it, "added").toString()) } } }
                override fun onInputDeviceRemoved(id: Int) {
                    runCatching { emit(JSONObject().put("kind", "device").put("layer", "android").put("event", "removed").put("device", id).toString()) }
                }
                override fun onInputDeviceChanged(id: Int) { input.getInputDevice(id)?.let { runCatching { emit(device(it, "changed").toString()) } } }
            }
            input.registerInputDeviceListener(watch, Handler(Looper.getMainLooper()))
            listener = watch
        }

        fun close(activity: Activity) = activity.runOnUiThread {
            val window = activity.window
            (window?.callback as? ExternalInputProbe)?.let { window.callback = it.inner }
            listener?.let { activity.getSystemService(InputManager::class.java)?.unregisterInputDeviceListener(it) }
            listener = null
        }
    }
}
