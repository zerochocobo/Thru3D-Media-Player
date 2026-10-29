package org.vrpassthroughplayer.plugin

/** Pure topology for window operations. Gecko applies one complete plan without intermediate tabs. */
internal data class WebBrowserWindowLayout(
    val tabs: List<Tab>, val selected: Map<Int, Int>, val focused: Int
) {
    data class Tab(val id: Int, val window: Int, val opener: Int = 0)

    fun close(ids: Set<Int>): WebBrowserWindowLayout = settle(tabs.filterNot { it.id in ids }, focused)

    fun move(ids: Set<Int>, destination: Int): WebBrowserWindowLayout {
        val moving = tabs.filter { it.id in ids }
        if (moving.isEmpty() || moving.any { it.window == destination }) return this
        // Appending retains both source order and the destination's current tab/playback.
        val next = tabs.filterNot { it.id in ids } + moving.map { it.copy(window = destination) }
        val sourceSelected = moving.firstOrNull { selected[it.window] == it.id }?.id ?: moving.first().id
        return settle(next, destination, selected + (destination to (selected[destination] ?: sourceSelected)))
    }

    private fun settle(next: List<Tab>, focus: Int, previous: Map<Int, Int> = selected): WebBrowserWindowLayout {
        val choices = next.groupBy { it.window }.mapValues { (window, items) ->
            val old = tabs.firstOrNull { it.id == previous[window] }
            items.firstOrNull { it.id == previous[window] }?.id
                ?: items.firstOrNull { it.id == old?.opener }?.id ?: items.last().id
        }
        return WebBrowserWindowLayout(next, choices, if (focus in choices) focus else choices.keys.minOrNull() ?: 1)
    }
}
