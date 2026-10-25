package org.vrpassthroughplayer.plugin

import java.security.MessageDigest

/** Immutable OCR results, bounded and memory-only. Never identify a page by its URI alone. */
internal class ComicPageCache(private val limit: Int=4,private val byteLimit: Int=4*1024*1024) {
    private val entries=LinkedHashMap<String,String>(8,.75f,true)
    @Synchronized fun get(key: String)=entries[key]
    @Synchronized fun put(key: String,value: String){
        if(value.length*2>byteLimit)return
        entries[key]=value
        while(entries.size>limit||entries.values.sumOf {it.length*2}>byteLimit)entries.remove(entries.keys.first())
    }
    @Synchronized fun clear()=entries.clear()
    @Synchronized fun size()=entries.size
    companion object {
        fun key(width: Int,height: Int,rgb: ByteArray): String {
            val digest=MessageDigest.getInstance("SHA-256")
            digest.update("$width:$height:".toByteArray(Charsets.US_ASCII));digest.update(rgb)
            return digest.digest().joinToString(""){"%02x".format(it)}
        }
        fun speechKey(page: String,block: Int,voice: String,language: String)="$page:$block:$voice:$language"
    }
}
