package org.vrpassthroughplayer.plugin

/** A spontaneous MPV VO reset needs a new processing scope, never relabelled frames. */
internal class MpvSourceEpochGate(private val minimumEpoch: Long = 1) {
    enum class Action { ACCEPT, DROP, REVISE }
    @Volatile var epoch = 0L
        private set
    @Volatile private var pendingEpoch = 0L
    val revisionPending get() = pendingEpoch > 0
    val floorForNextGeneration get() = maxOf(minimumEpoch, epoch, pendingEpoch)

    init { require(minimumEpoch > 0) }

    fun observe(value: Long): Action {
        require(value > 0) { "Invalid source epoch" }
        if (value < minimumEpoch) return Action.DROP
        if (epoch == 0L) epoch = value
        if (value < epoch) return Action.DROP
        if (revisionPending) { pendingEpoch = maxOf(pendingEpoch, value); return Action.DROP }
        if (value == epoch) return Action.ACCEPT
        pendingEpoch = value
        return Action.REVISE
    }
}
