package org.vrpassthroughplayer.plugin

/** Foreground and queued recognition never infer concurrently on low-memory headsets.
 * Cancellation does not take this gate. Only worker threads may enter it. */
internal object ListeningWorkGate {
    val lock=Any()
    @Volatile var delegatedMedia=""
    @Volatile var delegatedLanguage=""
    @Volatile var delegatedTrack=-1
    @Volatile var delegatedPlaylist=-1
    fun delegated(media: String,language: String,track: Int,playlist: Int)=media.isNotEmpty() &&
        delegatedMedia==media && delegatedLanguage==language && delegatedTrack==track && delegatedPlaylist==playlist
}
