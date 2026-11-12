package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.util.ArrayDeque

/** Bounded, in-memory startup evidence. Never accept TXT values, identities, PINs or key paths. */
internal class AirplayDiscoveryDiagnostics {
    private val events = ArrayDeque<String>()

    @Synchronized fun record(stage: String, generation: Long, state: String, port: Int,
        listening: Boolean, registrations: Int, code: Int? = null, failure: Throwable? = null): String {
        val event = JSONObject().put("stage", stage).put("generation", generation).put("state", state)
            .put("at_ms", System.nanoTime() / 1_000_000).put("port", port)
            .put("native_running", listening).put("registered_services", registrations)
        if (code != null) event.put("code", code)
        if (failure != null) {
            // A loader exception can include private paths; keep a category, never its message/stack.
            event.put("exception", failure.javaClass.simpleName)
            val message = failure.message.orEmpty()
            event.put("failure_kind", when {
                failure is UnsatisfiedLinkError && message.contains("cannot locate symbol", true) -> "missing_symbol"
                failure is UnsatisfiedLinkError && message.contains("not found", true) -> "missing_library_or_dependency"
                failure is UnsatisfiedLinkError -> "native_link"
                failure is SecurityException -> "permission"
                else -> "exception"
            })
        }
        val text = event.toString()
        events.addLast(text)
        while (events.size > 32) events.removeFirst()
        return text
    }

    /** Captured even when the original logcat startup lines have rolled out. Does not start JNI. */
    @Synchronized fun snapshot(): String = JSONObject().put("schema_version", 1)
        .put("events", JSONArray(events.map { JSONObject(it) })).toString()
}
