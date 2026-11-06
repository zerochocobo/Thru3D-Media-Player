package org.vrpassthroughplayer.plugin

/** A mask may only publish once, for the color token owned by this window/epoch. */
internal class WebBrowserMatteLease(private val owner: Long) {
    data class Ticket(val owner: Long, val epoch: Long, val frame: Long, val color: Long)
    private var epoch = 0L
    private var closed = false
    private var running: Ticket? = null
    private var lastFrame = -1L
    @Synchronized fun move(value: Long) { require(value >= epoch); epoch = value }
    @Synchronized fun begin(value: Long, frame: Long, color: Long): Ticket? {
        if (closed || running != null || value != epoch || frame <= lastFrame || color <= 0) return null
        return Ticket(owner,value,frame,color).also { running = it }
    }
    @Synchronized fun finish(ticket: Ticket): Boolean {
        if (running != ticket) return false
        running = null
        if (closed || ticket.epoch != epoch || ticket.owner != owner) return false
        lastFrame = ticket.frame; return true
    }
    @Synchronized fun close() { closed = true }
}
