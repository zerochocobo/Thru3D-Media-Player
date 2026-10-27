package org.vrpassthroughplayer.plugin

import org.json.JSONObject

internal object ListeningTaskPolicy {
    fun same(spec: ListeningTaskSpec,front: JSONObject)=front.optString("media")==spec.media
    fun delegated(spec: ListeningTaskSpec,front: JSONObject)=same(spec,front) && front.optBoolean("listening") &&
        front.optString("language")==spec.language && front.optInt("track",-1)==spec.track && front.optInt("playlist",-1)==spec.playlist
    fun blocked(spec: ListeningTaskSpec,front: JSONObject,active: Boolean,paused: Boolean,manual: Boolean,policy: String): String=when {
        !active || paused || manual -> "paused"
        front.optBoolean("protected_locked") -> "privacy_locked"
        policy=="idle"&&front.optBoolean("playing") -> "playback_priority"
        front.optBoolean("buffering") -> "playback_priority"
        front.optBoolean("listening")&&!delegated(spec,front) -> "playback_priority"
        spec.network&&front.optBoolean("network")&&front.optBoolean("playing")&&!same(spec,front) -> "playback_priority"
        else -> ""
    }
    /** Whether the reader must restart at [need]. It opens one settle window before
     * coverFrom; that pre-roll is on its way to the gap and must not count as behind it,
     * or every step reopens the source and the task never advances. */
    fun reopen(need: Double,through: Double,coverFrom: Double,readerFrom: Double)=
        through<0 || need>maxOf(through,coverFrom)+1 || need<readerFrom || through-readerFrom>=300
}
