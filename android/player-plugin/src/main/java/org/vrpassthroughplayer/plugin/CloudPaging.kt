package org.vrpassthroughplayer.plugin

/** Provider-tuned browse sizes, independent from legacy companion/queue readers. */
internal object CloudPaging {
    const val MAX_PAGE_SIZE = 1000
    fun defaultSize(provider: String): Int = when (provider) {
        CloudDrive.BAIDU -> 1000
        CloudDrive.QUARK -> 100
        else -> 200
    }
    fun size(provider: String, requested: Int): Int {
        val value = if (requested == 0) defaultSize(provider) else requested
        val cap = when (provider) {
            CloudDrive.BAIDU, CloudDrive.WEBDAV -> 1000
            CloudDrive.QUARK -> 100
            else -> 200
        }
        require(value in 1..cap) { "directory.request: unsupported page size" }
        return value
    }
    fun direct(provider: String) = provider in setOf(CloudDrive.OPEN115, CloudDrive.BAIDU, CloudDrive.WEBDAV)
}
