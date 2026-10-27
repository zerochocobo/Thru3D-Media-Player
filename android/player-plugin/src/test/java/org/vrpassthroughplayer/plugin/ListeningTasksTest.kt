package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ListeningTasksTest {
    private fun spec(network: Boolean=true)=ListeningTaskSpec("ab".repeat(32),"cloud://account/file","Film","ja","zh-Hans",120.0,1,-1,false,0.0,true,network)
    private fun front(media: String="another",network: Boolean=true)=JSONObject().put("media",media).put("playing",true).put("network",network)
    private fun blocked(s: ListeningTaskSpec,f: JSONObject,policy: String="playback")=ListeningTaskPolicy.blocked(s,f,true,false,false,policy)
    @Test fun networkPlaybackPreemptsOnlyConflictingBackgroundReads() {
        assertEquals("playback_priority",blocked(spec(),front()))
        assertEquals("",blocked(spec(),front(spec().media)))
        assertEquals("",blocked(spec(),front(network=false)))
        assertEquals("",blocked(spec(false),front()))
        assertEquals("playback_priority",blocked(spec(false),front(network=false),"idle"))
        assertEquals("playback_priority",blocked(spec(false),front(network=false).put("buffering",true)))
        assertEquals("privacy_locked",blocked(spec(false),front(network=false).put("protected_locked",true)))
    }
    @Test fun asrDelegationRequiresMatchingFilmLanguageTrackAndPlaylist() {
        val s=spec();val f=front(s.media).put("listening",true).put("language","ja").put("track",1).put("playlist",-1)
        assertTrue(ListeningTaskPolicy.delegated(s,f));assertEquals("",blocked(s,f))
        for((key,value) in listOf("language" to "en","track" to 2,"playlist" to 3,"media" to "other")){
            val different=JSONObject(f.toString()).put(key,value)
            assertFalse(ListeningTaskPolicy.delegated(s,different));assertEquals("playback_priority",blocked(s,different))
        }
        assertEquals("paused",ListeningTaskPolicy.blocked(s,f,false,false,false,"playback"))
        assertEquals("paused",ListeningTaskPolicy.blocked(s,f,true,true,false,"playback"))
    }
    @Test fun readerPreRollDoesNotReopenTheSource() {
        val need=100.0;val readerFrom=need-ListeningCueCache.SETTLE_SECONDS
        assertTrue(ListeningTaskPolicy.reopen(need,-100.0,0.0,0.0))
        assertFalse(ListeningTaskPolicy.reopen(need,readerFrom,need,readerFrom))
        assertFalse(ListeningTaskPolicy.reopen(need,readerFrom+5,need,readerFrom))
        assertTrue(ListeningTaskPolicy.reopen(need+30,readerFrom+5,need,readerFrom))
        assertTrue(ListeningTaskPolicy.reopen(readerFrom-1,readerFrom+5,need,readerFrom))
        assertTrue(ListeningTaskPolicy.reopen(need+200,readerFrom+300,need,readerFrom))
    }
    @Test fun descriptorsKeepStableSourcesAndNeverPersistSignedUrlsOrPrivateJobs() {
        val s=spec();assertEquals(s,ListeningTaskSpec.parse(s.json()));assertTrue(s.durable)
        assertFalse(s.copy(uri="https://example.invalid/film?token=signed").durable)
        assertFalse(s.copy(persist=false).durable)
        assertEquals("",ListeningTaskSpec.parse(s.json().put("language","zh").put("target","zh-Hans")).target)
        assertThrows(IllegalArgumentException::class.java){ListeningTaskSpec.parse(s.json().put("track",-1))}
        assertThrows(IllegalArgumentException::class.java){ListeningTaskSpec.parse(s.json().put("duration",0))}
    }
    @Test fun retainedInputSurvivesForegroundLeaseReleaseAndClosesExactlyOnce() {
        var closed=0
        val source=object: StreamSource {
            override val size=16L
            override fun open()=object: StreamSource.Reader {
                override fun read(offset: Long,buffer: ByteArray,length: Int): Int {check(closed==0);buffer[0]=42;return 1}
                override fun close() {}
            }
            override fun close(){closed++}
        }
        LocalStreamServer().use { server->
            val foreground=server.publish(source,"film.mp4")
            val background=server.retain(foreground)!!
            server.revoke(foreground);assertEquals(0,closed)
            server.listeningInput(background)!!.use{reader->val buffer=ByteArray(1);assertEquals(1,reader.readAt(0,buffer));assertEquals(42,buffer[0].toInt())}
            server.revoke(background);assertEquals(1,closed)
            assertNull(server.retain(background))
        }
        assertEquals(1,closed)
    }
    @Test fun applicationQueueDeduplicatesBoundsAndKeepsExplicitPauseUntilResume() {
        ListeningTasks({null},{it},{null},{null},{},{},{null},{_,_->}).use { queue->
            val deadline=System.nanoTime()+2_000_000_000
            while(!JSONObject(queue.status()).getBoolean("loaded")&&System.nanoTime()<deadline)Thread.sleep(5)
            assertTrue(JSONObject(queue.status()).getBoolean("loaded"))
            assertTrue(queue.command(JSONObject().put("operation","pause_all")))
            assertTrue(queue.enqueue(spec()));assertTrue(queue.enqueue(spec()))
            fun rows()=JSONObject(queue.status()).getJSONArray("jobs")
            assertEquals(1,rows().length())
            val id=rows().getJSONObject(0).getString("id")
            assertTrue(queue.command(JSONObject().put("operation","pause").put("id",id)))
            assertEquals("paused",rows().getJSONObject(0).getString("state"))
            assertTrue(queue.command(JSONObject().put("operation","context").put("media","different")))
            assertEquals("paused",rows().getJSONObject(0).getString("state"))
            assertTrue(queue.enqueue(spec().copy(target="en")))
            assertEquals(2,rows().length())
            assertTrue(queue.command(JSONObject().put("operation","cancel").put("id",id)))
            assertEquals("cancelled",rows().getJSONObject(0).getString("state"))
            assertTrue(queue.command(JSONObject().put("operation","clear_done")))
            assertEquals(1,rows().length())
            repeat(31){assertTrue(queue.enqueue(spec().copy(media="%064x".format(it))))}
            assertFalse(queue.enqueue(spec().copy(media="ff".repeat(32))))
            assertEquals(32,rows().length())
            queue.clear(true);assertEquals(0,rows().length())
            assertTrue(queue.enqueue(spec()))
            queue.command(JSONObject().put("operation","context").put("memory","none"))
            assertEquals("Privacy downgrade removes persistent descriptors",0,rows().length())
            assertTrue(queue.enqueue(spec().copy(persist=false)))
            queue.command(JSONObject().put("operation","context").put("protected_locked",true))
            assertEquals("Locked protected queue cannot expose session titles",0,rows().length())
        }
    }
}
