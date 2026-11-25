package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Exported-log records for MPV sources that stall: a close that does not finish, an open given up
 * before its first frame, and a new open made while such a source still holds its slot.
 * Fixed labels, timings and MPV module names only: never addresses, titles or paths. */
internal object MpvSourceDiagnostics {
    const val STUCK_MS = 5000L
    /** Shorter waits are ordinary browsing (open, glance, pick another). */
    const val ABANDON_MS = 3000L
    private val schemes = setOf("file", "content", "usb", "smb", "dlna", "http", "https", "cloud", "medialib",
        "webvideo", "externalvideo", "airplayvideo")
    private val nativeFields = listOf("stage", "render_stage", "closing_ms", "layer", "hardware", "decoder",
        "recent_modules", "last_log_ms", "mediacodec_started_ms", "decoder_observed_ms", "layer_software_fallback",
        // The step the control thread is in, and the core's own log trail read on a separate client.
        "control_call", "control_call_ms", "core_recent_modules", "core_last_log_ms", "core_decoder",
        "core_decoder_observed_ms", "core_mediacodec_started_ms")

    fun scheme(uri: String): String = uri.substringBefore(':', "").lowercase().takeIf { it in schemes } ?: "other"

    /** Where a closing source waits, in the order its close proceeds: its own open task, a session still
     * holding its frames, the native core, then the layer producer that releases the Surface last. */
    fun closeStage(sourcePreparing: Boolean, attached: Boolean, nativeOpen: Boolean, nativeStage: String?): String = when {
        sourcePreparing -> "source_preparing"
        attached -> "session_attached"
        nativeOpen -> nativeStage?.takeIf { it.isNotBlank() } ?: "native"
        else -> "layer_producer"
    }

    fun abandoned(firstFrame: Boolean, elapsedMs: Long, reason: String): Boolean =
        !firstFrame && elapsedMs >= ABANDON_MS && reason != "shutdown"

    /** Startup marks, whole milliseconds since the open (at most 16, earliest kept). */
    fun startup(marks: Map<String, Double>): JSONObject = JSONObject().also { out ->
        marks.entries.sortedBy { it.value }.take(16).forEach { (stage, ms) -> out.put(stage, ms.toLong()) }
    }

    /** The native close-wait fields that name a stage, a decoder kind or MPV modules; nothing else is copied. */
    fun native(wait: JSONObject?): JSONObject? = wait?.let { source ->
        JSONObject().also { out -> nativeFields.filter(source::has).forEach { out.put(it, source.get(it)) } }
    }

    fun source(kind: String, uri: String, loadingPhase: String, layerRequested: Boolean, layer: Boolean,
               firstFrame: Boolean, startup: Map<String, Double>): JSONObject = JSONObject()
        .put("kind", kind).put("scheme", scheme(uri)).put("loading_phase", loadingPhase)
        .put("layer_requested", layerRequested).put("layer", layer).put("first_frame", firstFrame)
        .put("startup", startup(startup))
}
