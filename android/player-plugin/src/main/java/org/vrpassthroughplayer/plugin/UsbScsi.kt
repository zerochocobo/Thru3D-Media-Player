package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object UsbScsi {
    const val NO_MEDIUM="USB medium not present"
    /** Fixed-format sense: NOT READY / MEDIUM NOT PRESENT, e.g. an empty card-reader slot. */
    fun noMedium(sense:ByteArray?)=sense!=null && sense.size>12 && (sense[0].toInt() and 0x7e)==0x70 &&
        (sense[2].toInt() and 15)==2 && sense[12].toInt()==0x3a
    fun capacity(capacity10:ByteArray,capacity16:()->ByteArray):Pair<Int,Long> {
        var b=ByteBuffer.wrap(capacity10).order(ByteOrder.BIG_ENDIAN)
        var last=b.int.toLong() and 0xffffffffL
        var size=b.int
        if(last==0xffffffffL) { b=ByteBuffer.wrap(capacity16()).order(ByteOrder.BIG_ENDIAN); last=b.long; size=b.int }
        if(last<0 || last==Long.MAX_VALUE || size !in listOf(512,1024,2048,4096) || last+1>Long.MAX_VALUE/size) throw IOException("Unsupported USB capacity")
        return size to last+1
    }
    fun read(lba:Long,blocks:Int):ByteArray {
        require(lba>=0 && blocks>0 && lba<=Long.MAX_VALUE-blocks)
        return if(lba<=0xffffffffL && blocks<=65535 && lba+blocks-1<=0xffffffffL) ByteArray(10).also {
            it[0]=0x28; ByteBuffer.wrap(it).order(ByteOrder.BIG_ENDIAN).putInt(2,lba.toInt()).putShort(7,blocks.toShort())
        } else ByteArray(16).also { it[0]=0x88.toByte(); ByteBuffer.wrap(it).order(ByteOrder.BIG_ENDIAN).putLong(2,lba).putInt(10,blocks) }
    }
}
