package org.vrpassthroughplayer.plugin

import android.content.Context
import java.nio.ByteBuffer

/** Source-frame build only. GL methods run in an actual Godot draw callback.
 * The native worker shares its context and owns all MPV render calls; control
 * methods enqueue work for a separate ordinary-client thread.
 */
internal object MpvSourceNative {
    @JvmStatic external fun captureOwner(handle: Long): Long
    @JvmStatic external fun setPrivacy(enabled: Boolean)
    private val loaded = try { System.loadLibrary("quest_mpv"); true } catch (_: UnsatisfiedLinkError) { false }
    fun supported() = loaded && available()
    @JvmStatic private external fun available(): Boolean
    /** Starts paused; the caller must apply focus policy before setPlaying(true). */
    /** layerSurface: decode straight into a compositor layer swapchain (VideoLayerNative); frames then
     * carry only their identity (color_target "layer"). MVC has an explicit software Surface route;
     * unsupported ordinary software/rotated/Profile 5 sources report layer_compatible=false.
     * maxWidth > 0 scales the decoded color down to that width (aspect kept); 0 keeps the source size.
     * audioFiles: location/title pairs added as unselected audio tracks once the video loads. */
    @JvmStatic external fun create(context: Context, localPath: String, startMs: Int, hardware: Boolean, audio: Boolean,
                                   maxWidth: Int = 0, audioFiles: Array<String> = emptyArray(),
                                   subtitleFiles: Array<String> = emptyArray(), exactStart: Boolean = true,
                                   layerSurface: android.view.Surface? = null, softwareLayer: Boolean = false,
                                   layerWidth: Int = 4096, layerHeight: Int = 4096, isoInput: Boolean = false,
                                   tlsCaFile: String = MpvTlsTrust.prepare(context),
                                   networkInterleaveCompat: Boolean = false): Long
    /** ISO header/title preflight on the source worker; width, height, duration-us, MVC flag. */
    @JvmStatic external fun probeIso(path: String): LongArray
    /** Empty string when no completed image is available. Never waits for the GPU. */
    @JvmStatic external fun acquire(handle: Long): String
    /** Insert consumer-context fence after its last copy/draw; rejects double release. */
    @JvmStatic external fun release(handle: Long, producerToken: Long): Boolean
    @JvmStatic external fun setPlaying(handle: Long, playing: Boolean)
    /** Positive playback rate; media timestamps and subtitle timing remain in source time. */
    @JvmStatic external fun setSpeed(handle: Long, speed: Double): Boolean
    /** Coalesced control request. -1 auto, 0 disabled, or an actual track-list id; volume 0..100. */
    @JvmStatic external fun setAudio(handle: Long, trackId: Int, volume: Double, muted: Boolean): Boolean
    /** Per-video whisper enhancement: 0 off; 1..51 enable compression with continuous 0..50 boost; serial 0 rejects. */
    @JvmStatic external fun setWhisper(handle: Long, level: Int): Long
    /** Independent temporary multiplier; never changes the selected track or saved volume. */
    @JvmStatic external fun setNarrationGain(handle: Long, gain: Double): Boolean
    /** 0 rejected; positive coalesced command serial. -1 auto, 0 off, actual subtitle id. */
    @JvmStatic external fun setSubtitle(handle: Long, trackId: Int): Long
    /** Optional unselected subtitle, queued on MPV's control thread. Failure never stops video. */
    @JvmStatic external fun addSubtitleFile(handle: Long, location: String, title: String): Long
    /** Deferred unselected cloud companions; queued once after the first video frame. */
    @JvmStatic external fun addCompanions(handle: Long, audioFiles: Array<String>, subtitleFiles: Array<String>): Boolean
    @JvmStatic external fun subtitleFileStatus(handle: Long, request: Long): String
    /** Positive seconds delay captions; shares the subtitle command fence. */
    @JvmStatic external fun setSubtitleDelay(handle: Long, seconds: Double): Long
    /** Positive seconds play the audio later: Alpha plan B holds layer frames until their masks. */
    @JvmStatic external fun setAudioDelay(handle: Long, seconds: Double): Boolean
    /** Plain text in a separate UI layer; empty when no newer snapshot is available. */
    @JvmStatic external fun subtitleStatus(handle: Long, afterSequence: Long): String
    /** Cropped premultiplied RGBA for this exact bitmap version, empty if superseded. */
    @JvmStatic external fun subtitleBitmap(handle: Long, version: Long): ByteArray
    @JvmStatic external fun seek(handle: Long, positionMs: Long, exact: Boolean = true): Boolean
    /** Present at most fps source frames per second (0 = all), chosen by scheduled display time before rendering. */
    @JvmStatic external fun setFrameCap(handle: Long, fps: Int)
    /** Direct mode: publish MediaCodec images; Profile 5 always retains converted SDR RGBA. */
    @JvmStatic external fun setDirect(handle: Long, enabled: Boolean)
    /** Re-render a retained paused frame; its original frame ID/PTS/epoch remain unchanged. */
    @JvmStatic external fun requestFrame(handle: Long)
    /** Debug calibration only: 24 sparse RGBA samples, no full source readback. */
    @JvmStatic external fun readFrameCode(handle: Long, producerToken: Long, output: ByteBuffer)
    /** position_seconds is a playback clock observation, never a source-frame PTS. */
    @JvmStatic external fun status(handle: Long): String
    /** Cached playback metadata and transport fences; never locks renderer slots. */
    @JvmStatic external fun narrationStatus(handle: Long): String
    /** Begin teardown but retain status/handle until close, so cleanup can be checked. */
    @JvmStatic external fun requestClose(handle: Long)
    /** Asynchronous. Repeat until true. abandon is only for a dead owner context. */
    @JvmStatic external fun close(handle: Long, abandon: Boolean): Boolean
}
