package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import org.godotengine.godot.plugin.GodotPlugin
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Exercise the production input View after detachment, without loading a page or typing. */
internal object LoginInputLifecycleProbe {
    fun run(): JSONObject {
        val ui = Handler(Looper.getMainLooper())
        val ready = CountDownLatch(1)
        val views = mutableListOf<View>()
        var owner: GeckoLoginSession? = null
        var checks = 0
        var error: String? = null
        ui.post {
            try {
                val plugin = DiagnosticRequests.current() ?: error("Plugin unavailable")
                val getter = GodotPlugin::class.java.getDeclaredMethod("getActivity").apply { isAccessible = true }
                val activity = getter.invoke(plugin) as Activity
                val login = GeckoLoginSession({ activity }) { url, _ -> url }; owner = login
                val type = GeckoLoginSession::class.java.declaredClasses.single { it.simpleName == "LoginInput" }
                val constructor = type.declaredConstructors.single().apply { isAccessible = true }
                val root = activity.window.decorView as ViewGroup
                repeat(8) {
                    val view = constructor.newInstance(login, activity) as View
                    check(view.handler == null); checks++
                    root.addView(view, ViewGroup.LayoutParams(1, 1))
                    try { check(view.handler != null); checks++ } finally { root.removeView(view) }
                    check(view.handler == null); checks++
                    views.add(view)
                }
                login.close()
            } catch (failure: Throwable) { error = failure.javaClass.simpleName }
            finally { ready.countDown() }
        }
        check(ready.await(5, TimeUnit.SECONDS))
        // The receiver worker stands in for the late GeckoInputConnection callback.
        if (error == null) try {
            for (view in views) repeat(4) { check(view.handler == null); checks++ }
        } catch (failure: Throwable) { error = failure.javaClass.simpleName }
        if (error != null) ui.post { owner?.close() }
        return JSONObject().put("passed", error == null && checks == 56).put("checks", checks)
            .put("error_type", error ?: "").put("scope", "Production LoginInput attach/detach and late getHandler; no credentials or page interaction")
    }
}
