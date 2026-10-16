package org.vrpassthroughplayer.plugin

/** Native workers check the current policy when committing, rather than when queued. */
internal object PlaybackPrivacy {
    @Volatile var mode = "all"
    @Volatile var protectedFavorites = false
    val networkHistory: Boolean get() = mode == "all" && !protectedFavorites
    val diagnostics: Boolean get() = mode == "all" && !protectedFavorites
}
