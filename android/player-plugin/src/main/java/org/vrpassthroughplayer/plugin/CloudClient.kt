package org.vrpassthroughplayer.plugin

internal interface CloudClient {
    fun page(path: String, offset: Int = 0, refresh: Boolean = false): CloudPage
    /** A provider-wide order applied before paging. Null means that order is unavailable;
     * directory browsing must never enumerate the folder to manufacture a sorted page. */
    fun orderedPage(path: String, offset: Int, refresh: Boolean, order: String): CloudPage? = null
    fun list(path: String): List<CloudFile>
    fun find(path: String): CloudFile
    /** Browsed identities are read-only hints, verified by the playback endpoint. */
    fun findForPlayback(path: String, selected: CloudFile?): CloudFile = find(path)
    /** Native same-directory search where available, otherwise recover the original parent.
     * Called on the companion worker after the first frame, including cold history opens. */
    fun companions(path: String, pageFiles: List<CloudFile>): List<CloudFile> =
        list(path.substringBeforeLast('/').ifEmpty { "/" })
    /** Fresh direct-sibling search for management checks; null keeps legacy adapters compatible. */
    fun freshMatches(parent: String, queries: List<String>): List<CloudFile>? = null
    /** Identity read-back after an uncertain write; null is a legacy-only fallback. */
    fun containsObject(file: CloudFile): Boolean? = null
    fun resolve(file: CloudFile): CloudLink
    val canDelete: Boolean get() = false
    val canRename: Boolean get() = false
    // A writable implementation must resolve the path fresh and verify this expected
    // identity/metadata before its one provider write. Success means provider-confirmed.
    fun remove(path: String, file: CloudFile) { throw IllegalStateException("File deletion unavailable for this source") }
    fun rename(path: String, file: CloudFile, newName: String) { throw IllegalStateException("Rename unavailable for this source") }
}
