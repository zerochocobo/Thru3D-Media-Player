package org.vrpassthroughplayer.plugin

import java.io.Closeable

/** Worker-only random access to the existing media lease. No speculative HTTP body. */
internal class ListeningInput(private val length: Long, private val reader: StreamSource.Reader,
                              private val sourceSnapshot: () -> Map<String,Long> = {emptyMap()},
                              private val read: (StreamSource.Reader, Long, ByteArray, Int) -> Int) : Closeable {
    @Volatile private var closed = false
    @Volatile var bytesRead=0L
        private set
    @Volatile var readCalls=0L
        private set
    @Volatile var readNanos=0L
        private set
    @Volatile var offset=0L
        private set
    val snapshot: () -> Map<String,Long> = {sourceSnapshot()+reader.counters().mapKeys {"reader_"+it.key}}
    fun size(): Long = length
    fun readAt(offset: Long, buffer: ByteArray): Int {
        check(!closed)
        require(offset in 0..length && buffer.isNotEmpty())
        if(offset==length)return -1
        val began=System.nanoTime();readCalls++;this.offset=offset
        try { return read(reader,offset,buffer,minOf(buffer.size.toLong(),length-offset).toInt()).also { if(it>0)bytesRead+=it } }
        finally {readNanos+=System.nanoTime()-began}
    }
    override fun close() { if(!closed){closed=true;reader.close()} }
}
