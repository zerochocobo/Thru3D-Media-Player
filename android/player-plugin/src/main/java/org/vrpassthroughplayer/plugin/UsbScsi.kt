package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object UsbScsi {
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
