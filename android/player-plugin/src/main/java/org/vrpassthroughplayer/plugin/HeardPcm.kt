package org.vrpassthroughplayer.plugin

/** Bounded submitted PCM, indexed by AudioTrack frames. A generation callback is
 * never a recording source. Retain only enough for the 200 ms output queue. */
internal class HeardPcm(private val sink: (FloatArray,Int,Long,Float)->Unit) {
    private data class Part(val first: Long,val data: FloatArray,val offset: Int,val count: Int)
    private val submitted=java.util.ArrayDeque<Part>()
    private var heard=0L
    private var written=0L
    private var anchorNs: Long?=null
    private var anchorFrame=0L
    private val scratch=FloatArray(2048)
    fun discontinuity(){anchorNs=null}
    fun reset(){submitted.clear();heard=0;written=0;discontinuity()}
    fun write(source: FloatArray,offset: Int,count: Int) {
        if(count<=0)return
        submitted.addLast(Part(written,source,offset,count))
        written+=count/2
        // This is also used before recording starts, so an in-flight sentence can be captured.
        while(submitted.size>1&&submitted.first().first+submitted.first().count/2<written-48000)submitted.removeFirst()
    }
    fun present(frame: Long,frameNs: Long,nowNs: Long,gain: Float,recording: Boolean) {
        // A newer estimate may move backwards. It cannot make a frame unheard.
        val presented=maxOf(heard,(frame+(nowNs-frameNs)*48000/1_000_000_000).coerceIn(0,written))
        if(presented>heard&&anchorNs==null){anchorNs=frameNs;anchorFrame=frame}
        if(!recording){heard=presented;prune();return}
        var next=heard
        for(part in submitted) {
            val first=maxOf(next,part.first)
            val last=minOf(presented,part.first+part.count/2)
            var at=first
            while(at<last) {
                val count=minOf(1024L,last-at).toInt()
                val offset=part.offset+((at-part.first)*2).toInt()
                part.data.copyInto(scratch,0,offset,offset+count*2)
                sink(scratch,count*2,requireNotNull(anchorNs)+(at-anchorFrame)*1_000_000_000/48000,gain)
                at+=count
            }
            next=maxOf(next,last)
        }
        heard=presented;prune()
    }
    private fun prune(){while(submitted.isNotEmpty()&&submitted.first().first+submitted.first().count/2<=heard)submitted.removeFirst()}
}
