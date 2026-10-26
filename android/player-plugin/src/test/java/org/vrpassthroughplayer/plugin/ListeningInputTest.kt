package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class ListeningInputTest {
    @Test fun directInputUsesAudioReaderAndHonorsRevokedMediaLease() {
        var audioOpens=0;var closed=0
        val source=object:StreamSource {
            override val size=1000L
            override fun open():StreamSource.Reader=error("ordinary HTTP reader should not be used")
            override fun openAudio():StreamSource.Reader {audioOpens++;return object:StreamSource.Reader {
                override fun read(offset:Long,buffer:ByteArray,length:Int):Int {buffer.fill(42,0,length);return length}
                override fun close(){closed++}
            }}
        }
        LocalStreamServer().use {server ->
            val url=server.publish(source,"owned.mp4")
            server.listeningInput(url)!!.use {input ->
                assertEquals(1,audioOpens);val bytes=ByteArray(20)
                assertEquals(20,input.readAt(10,bytes));assertArrayEquals(ByteArray(20){42},bytes)
                server.revoke(url)
                assertThrows(IllegalStateException::class.java){input.readAt(0,bytes)}
            }
        }
        assertEquals(1,closed)
    }
    @Test fun exactDemandAndReaderLifetime() {
        var closed=0;val requests=mutableListOf<Pair<Long,Int>>()
        val reader=object:StreamSource.Reader {
            override fun read(offset: Long,buffer: ByteArray,length: Int): Int {
                requests.add(offset to length)
                repeat(length){buffer[it]=((offset+it)%251).toByte()};return length
            }
            override fun close(){closed++}
        }
        val input=ListeningInput(1000,reader){r,at,b,n->r.read(at,b,n)}
        val bytes=ByteArray(13)
        assertEquals(13,input.readAt(700,bytes));assertEquals(listOf(700L to 13),requests)
        assertArrayEquals(ByteArray(13){((700+it)%251).toByte()},bytes)
        assertEquals(3,input.readAt(997,bytes));assertEquals(-1,input.readAt(1000,bytes))
        assertEquals(2,requests.size);assertEquals(1000,input.size())
        input.close();input.close();assertEquals(1,closed)
        assertThrows(IllegalStateException::class.java){input.readAt(0,bytes)}
    }
}
