package org.vrpassthroughplayer.plugin

/** UI-thread leases: two embedded web panels must not restore each other's IME flag. */
internal class RayKeyboardImeGate(
    private val isBlocked: () -> Boolean,
    private val setBlocked: (Boolean) -> Unit
) {
    private val owners = mutableSetOf<Any>()
    private var wasBlocked = false

    fun acquire(owner: Any) {
        if (owner in owners) return
        if (owners.isEmpty()) wasBlocked = isBlocked()
        owners.add(owner)
        setBlocked(true)
    }

    fun release(owner: Any) {
        if (!owners.remove(owner)) return
        if (owners.isEmpty()) setBlocked(wasBlocked)
    }
}
