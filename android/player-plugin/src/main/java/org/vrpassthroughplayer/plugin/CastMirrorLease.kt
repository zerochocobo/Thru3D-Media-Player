package org.vrpassthroughplayer.plugin

/** AirPlay and Miracast share the existing mirror decoder and its two rotation surfaces. */
internal class CastMirrorLease {
    data class Ticket(val protocol: String, val epoch: Long)
    private var serial = 0L
    @Volatile var current: Ticket? = null; private set
    @Synchronized fun claim(protocol: String): Ticket? {
        require(protocol in setOf("AirPlay", "Miracast"))
        if (current != null) return null
        return Ticket(protocol, ++serial).also { current = it }
    }
    @Synchronized fun release(protocol: String, epoch: Long): Boolean {
        if (current != Ticket(protocol, epoch)) return false
        current = null
        return true
    }
    fun matches(protocol: String, epoch: Long) = current == Ticket(protocol, epoch)
}
