package org.vrpassthroughplayer.plugin

/** UI-thread load ordering: a login document starts only on an active, sized display. */
internal class GeckoLoginLoad {
    private var initialUrl: String? = null
    private var reload = false
    private var closed = false
    private var documentStarted = false

    fun open(url: String) { if (!closed) initialUrl = url }
    fun resize() { if (!closed) reload = true }
    fun close() { closed = true; initialUrl = null; reload = false }

    fun ready(attached: Boolean, paused: Boolean, load: (String) -> Unit, refresh: () -> Unit) {
        if (closed || !attached || paused) return
        val first = initialUrl
        val refreshPending = reload
        initialUrl = null; reload = false
        if (first != null) load(first) else if (refreshPending) refresh()
    }

    // Gecko publishes its empty initial document independently of our queued load.
    // Observer callbacks must not route it through OAuth policy or stop the real request.
    fun placeholder(url: String?) = url == "about:blank"
    fun allowPlaceholderRequest() = !closed && !documentStarted
    fun started(url: String) { if (!placeholder(url)) documentStarted = true }
}
