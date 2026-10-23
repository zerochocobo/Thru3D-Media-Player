package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Rect
import android.view.Window
import android.view.WindowManager
import android.webkit.WebView
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/** Keep the host window out of the system IME before Chromium processes input focus. */
internal open class RayKeyboardWebView(context: Context, window: Window) : WebView(context) {
    private val imeGate = gate(window)
    private var inputPaused = false

    override fun onCheckIsTextEditor() = false

    override fun onFocusChanged(focused: Boolean, direction: Int, previous: Rect?) {
        if (focused && !inputPaused) imeGate.acquire(this)
        super.onFocusChanged(focused, direction, previous)
        if (!focused) imeGate.release(this)
    }

    override fun onPause() {
        inputPaused = true
        clearFocus()
        imeGate.release(this)
        super.onPause()
    }

    override fun onResume() {
        inputPaused = false
        if (hasFocus()) imeGate.acquire(this)
        super.onResume()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        imeGate.release(this)
    }

    override fun destroy() {
        inputPaused = true
        imeGate.release(this)
        super.destroy()
    }

    companion object {
        private val gates = WeakHashMap<Window, RayKeyboardImeGate>()
        private fun gate(window: Window): RayKeyboardImeGate = gates.getOrPut(window) {
            // Do not keep the WeakHashMap's window key alive through its value.
            val reference = WeakReference(window)
            val flag = WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM
            RayKeyboardImeGate(
                { ((reference.get()?.attributes?.flags ?: 0) and flag) != 0 },
                { blocked -> reference.get()?.let { if (blocked) it.addFlags(flag) else it.clearFlags(flag) } }
            )
        }
    }
}
