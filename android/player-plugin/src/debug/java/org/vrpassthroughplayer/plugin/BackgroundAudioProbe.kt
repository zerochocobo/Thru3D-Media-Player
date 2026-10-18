package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Muted synthetic fixtures only; uses production import validation and music transport. */
internal object BackgroundAudioProbe {
    fun request(context: Context): Int {
        Thread({
            val report = JSONObject().put("audible_output_verified", false)
            val rows = JSONArray()
            try {
                for (name in listOf("stereo.flac", "surround.flac", "surround.dts", "dts.wav", "real-flac.flac", "real-dts.wav")) {
                    val source = File(context.filesDir, "fixtures/music-formats/$name")
                    val saved = source.inputStream().use { BackgroundAudioFiles.copy(it, File(context.filesDir, "background-audio"), source.extension,
                        source.length(), validate = { BackgroundAudioNative.validate(context, it) { false } }) }
                    val player = BackgroundAudioPlayback({ context })
                    try {
                        val id = player.load(saved.file.path, 0.0); check(id > 0)
                        fun waitFor(predicate: (JSONObject) -> Boolean): JSONObject {
                            val deadline = System.nanoTime() + 12_000_000_000L
                            while (true) {
                                val state = JSONObject(player.status()); check(state.optString("state") != "failed") { state.toString() }
                                if (predicate(state)) return state
                                check(System.nanoTime() < deadline) { "Timeout: $name $state" }; Thread.sleep(40)
                            }
                        }
                        val ready = waitFor { it.optString("state") == "ready" }
                        check(ready.optDouble("duration") > 5 && ready.optString("channels") == "stereo") { ready.toString() }
                        check(player.control(id, true, 0.0, -1.0))
                        waitFor { it.optDouble("position") > 0.25 }
                        player.control(id, false, 0.0, 2.0)
                        val paused = waitFor { it.optDouble("position") in 1.9..2.2 }
                        Thread.sleep(250)
                        check(kotlin.math.abs(JSONObject(player.status()).optDouble("position") - paused.optDouble("position")) < 0.1)
                        player.control(id, true, 0.0, ready.getDouble("duration") - 1.0)
                        val ended = waitFor { it.optString("state") == "ended" }
                        rows.put(JSONObject().put("fixture", name).put("ready", ready).put("ended", ended).put("pause_seek_eof", true))
                    } finally { player.close(); if (saved.created) BackgroundAudioFiles.remove(File(context.filesDir, "background-audio"), saved.file.path) }
                }
                val bad = File(context.filesDir, "fixtures/music-formats/invalid.flac")
                check(!BackgroundAudioNative.validate(context, bad) { false })
                report.put("state", "passed").put("invalid_rejected", true)
            } catch (error: Throwable) { report.put("state", "failed").put("error", error.toString()) }
            finally {
                report.put("fixtures", rows)
                File(context.filesDir, "diagnostics").mkdirs()
                File(context.filesDir, "diagnostics/music_formats.json").writeText(report.toString(2))
            }
        }, "Thru3DMusicProbe").start()
        return 1
    }
}
