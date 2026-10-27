package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

/** Shared text/coverage store for playback and whole-film jobs; no audio or URLs. */
internal class ListeningCueCache(private val directory: File?, val key: String, val network: Boolean) {
    private val cues=ArrayList<ListeningPolicy.Cue>()
    private val covered=ArrayList<DoubleArray>()
    private val hashes=HashMap<String,String>()
    private fun hash(text: String)=hashes.getOrPut(text){sha256(text)}
    private val translations=linkedMapOf<String,MutableMap<String,String>>()
    private val ioLock=Any()
    private var revision=0L
    private var originalRevision=0L
    private var savedRevision=0L
    private var written=0L
    private var terminal=-1.0
    @Volatile var revoked=false
        private set
    @Volatile var error=""
        private set
    val instance=serial.incrementAndGet()
    val persistent get()=directory!=null
    @Synchronized fun coveredEnd(at: Double): Double? = if(revoked)null else covered.firstOrNull{at>=it[0] && at<it[1]}?.get(1)
    @Synchronized fun coveredSeconds(duration: Double)=covered.sumOf{(minOf(duration,it[1])-maxOf(0.0,it[0])).coerceAtLeast(0.0)}
    @Synchronized fun firstGap(duration: Double,from: Double=0.0): Double {
        var at=from.coerceIn(0.0,duration)
        for(span in covered){if(span[0]>at+0.000001)break;if(span[1]>at)at=span[1]}
        return minOf(at,duration)
    }
    @Synchronized fun complete(duration: Double)=!revoked && error.isEmpty() && duration>0 && terminal>=duration && firstGap(duration)>=duration && (!persistent || savedRevision>=originalRevision)
    @Synchronized fun analyzed(duration: Double)=!revoked && duration>0 && terminal>=duration && firstGap(duration)>=duration
    @Synchronized fun count()=cues.size
    @Synchronized fun cues(from: Double,to: Double): List<ListeningPolicy.Cue> {
        if(revoked)return emptyList()
        var low=0;var high=cues.size
        while(low<high){val mid=(low+high) ushr 1;if(cues[mid].start<from-15)low=mid+1 else high=mid}
        val result=ArrayList<ListeningPolicy.Cue>()
        for(i in low until cues.size){val cue=cues[i];if(cue.start>=to)break;if(cue.end>from)result.add(cue)}
        return result
    }
    @Synchronized fun add(cue: ListeningPolicy.Cue) {
        if(revoked || error=="cache_full")return
        // Resuming with context may move a completed line's boundary slightly.
        if(cues(maxOf(0.0,cue.start-15),cue.end+15).any{it.text==cue.text && minOf(it.end,cue.end)-maxOf(it.start,cue.start)>minOf(it.end-it.start,cue.end-cue.start)*0.8})return
        val at=cues.binarySearchBy(cue.start){it.start}.let{if(it<0)-it-1 else it}
        if(at<cues.size && cues[at].start==cue.start && cues[at].end==cue.end){if(cues[at]==cue)return;cues[at]=cue}
        else{if(cues.size>=MAX_CUES){error="cache_full";return};cues.add(at,cue)}
        originalRevision=++revision
    }
    @Synchronized fun cover(start: Double,end: Double) {
        if(revoked || error=="cache_full" || !(end>start) || start<0 || !start.isFinite() || !end.isFinite())return
        if(covered.any{it[0]<=start && it[1]>=end})return
        var a=start;var b=end;val iterator=covered.iterator()
        while(iterator.hasNext()){val span=iterator.next();if(span[1]>=a && span[0]<=b){a=minOf(a,span[0]);b=maxOf(b,span[1]);iterator.remove()}}
        covered.add(covered.indexOfFirst{it[0]>a}.let{if(it<0)covered.size else it},doubleArrayOf(a,b));originalRevision=++revision
    }
    /** Only after decoder/resampler/recognizer have all drained a real EOF. */
    @Synchronized fun finish(end: Double,duration: Double,audioEnd: Double=duration) {
        if(revoked || !end.isFinite() || end<0 || duration<=0 || !duration.isFinite())return
        if(!audioEnd.isFinite() || audioEnd<=0 || end+0.25<audioEnd){error="source_incomplete";return}
        cover(minOf(end,duration),duration) // A valid audio track can end before video.
        if(terminal!=duration){terminal=duration;originalRevision=++revision}
    }
    @Synchronized fun translation(text: String,target: String)=if(revoked)"" else translations[target]?.get(hash(text)).orEmpty()
    @Synchronized fun translate(text: String,target: String,value: String): Boolean {
        if(revoked || target.isEmpty() || target.length>16 || !target.all{it.isLetter()||it=='-'} || value.isBlank() || value.length>2000 || cues.none{it.text==text})return false
        if(!translations.containsKey(target) && translations.size>=8){error="cache_full";return false}
        val values=translations.getOrPut(target){linkedMapOf()};val hash=hash(text)
        if(values[hash]!=value){values[hash]=value;++revision};return true
    }
    @Synchronized fun translated(target: String)=if(target.isEmpty())0 else cues.count{translation(it.text,target).isNotEmpty()}
    @Synchronized fun pending(target: String,limit: Int=32)=cues.asSequence().filter{translation(it.text,target).isEmpty()}.distinctBy{it.text}.take(limit).toList()
    @Synchronized fun rows(items: List<ListeningPolicy.Cue>,target: String)=JSONArray(items.map{it.json().put("translation",translation(it.text,target))})
    @Synchronized fun translationsSaved()=!persistent || revision==savedRevision
    @Synchronized fun retry(){if(error in setOf("source_incomplete","cache_write_error"))error=""}
    @Synchronized fun snapshot(force: Boolean): String? {
        if(revoked || directory==null || revision==savedRevision || (!force && System.nanoTime()-written<WRITE_INTERVAL_NS))return null
        return JSONObject().put("schema",SCHEMA).put("key",key).put("network",network).put("revision",revision)
            .put("terminal",terminal).put("covered",JSONArray(covered.map{JSONArray().put(it[0]).put(it[1])}))
            .put("cues",JSONArray(cues.map{JSONArray().put(it.start).put(it.end).put(it.text)}))
            .put("translation_schema",1).put("translations",JSONObject(translations.mapValues{JSONObject(it.value)})).toString()
    }
    fun flush(force: Boolean=false): Boolean=synchronized(ioLock){val json=snapshot(force);if(json==null)error.isEmpty() else write(json)}
    fun write(json: String): Boolean=synchronized(ioLock){
        val dir=directory ?: return@synchronized true
        val bytes=json.toByteArray(Charsets.UTF_8)
        if(bytes.size>MAX_BYTES){error="cache_full";return@synchronized false}
        val stamp=runCatching{JSONObject(json).getLong("revision")}.getOrDefault(-1)
        if(synchronized(this){revoked || stamp<savedRevision})return@synchronized false
        try{
            check(dir.isDirectory || dir.mkdirs());val temporary=File(dir,"$key.json.tmp")
            temporary.outputStream().use{it.write(bytes);it.fd.sync()}
            if(revoked){temporary.delete();return@synchronized false}
            Files.move(temporary.toPath(),File(dir,"$key.json").toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE)
            synchronized(this){savedRevision=stamp;written=System.nanoTime();if(error=="cache_write_error")error=""};true
        }catch(_:Exception){error="cache_write_error";false}
    }
    fun invalidate(){revoked=true}
    fun revoke(){invalidate();synchronized(ioLock){synchronized(this){cues.clear();covered.clear();translations.clear();hashes.clear()}}}

    companion object {
        const val SCHEMA=2
        const val SETTLE_SECONDS=8.0 // 6s VAD limit plus bounded input/update context.
        private const val MAX_CUES=20000
        private const val MAX_BYTES=8*1024*1024
        private const val WRITE_INTERVAL_NS=15_000_000_000L
        private val serial=AtomicLong()
        private val shared=linkedMapOf<String,WeakReference<ListeningCueCache>>()
        fun directory(files: File)=File(files,"listening-cues")
        fun key(media: String,duration: Double,language: String,model: String,track: Int=-1,playlist: Int=-1)=
            sha256("$SCHEMA|$media|${"%.3f".format(java.util.Locale.ROOT,duration)}|$language|$model|$track|$playlist")
        fun modelIdentity(manifest: JSONObject,language: String): String {
            val files=manifest.getJSONObject("models").getJSONObject(language).getJSONObject("files")
            return sha256(manifest.optString("revision")+"|"+files.keys().asSequence().sorted().joinToString("|"){it+":"+files.getJSONObject(it).getString("sha256")})
        }
        @Synchronized fun obtain(directory: File?,key: String,network: Boolean): ListeningCueCache {
            val id="${directory?.absolutePath ?: "memory"}:$key";shared.entries.removeAll{it.value.get()==null}
            return shared[id]?.get()?.takeIf{!it.revoked} ?: load(directory,key,network).also{shared[id]=WeakReference(it)}
        }
        @Synchronized fun find(key: String,instance: Long)=shared.values.mapNotNull{it.get()}.firstOrNull{!it.revoked && it.key==key && it.instance==instance}
        fun load(directory: File?,key: String,network: Boolean): ListeningCueCache {
            val cache=ListeningCueCache(directory,key,network);val file=directory?.let{File(it,"$key.json")} ?: return cache
            if(!file.isFile || file.length()>MAX_BYTES)return cache
            runCatching{
                val json=JSONObject(file.readText());require(json.getInt("schema")==SCHEMA && json.getString("key")==key)
                val spans=json.getJSONArray("covered");require(spans.length()<=MAX_CUES)
                for(i in 0 until spans.length()){val s=spans.getJSONArray(i);val a=s.getDouble(0);val b=s.getDouble(1);require(a.isFinite()&&b.isFinite()&&a>=0&&b>a);cache.cover(a,b)}
                val rows=json.getJSONArray("cues");require(rows.length()<=MAX_CUES)
                for(i in 0 until rows.length()){val r=rows.getJSONArray(i);val cue=ListeningPolicy.Cue.parse(JSONObject().put("start",r.getDouble(0)).put("end",r.getDouble(1)).put("text",r.getString(2)));require(cue!=null);cache.add(cue)}
                val translated=if(json.optInt("translation_schema")==1)json.optJSONObject("translations") ?: JSONObject() else JSONObject();require(translated.length()<=8)
                for(target in translated.keys()){
                    val values=translated.getJSONObject(target);require(values.length()<=MAX_CUES);val map=linkedMapOf<String,String>()
                    for(hash in values.keys()){val value=values.getString(hash);require(hash.matches(Regex("[a-f0-9]{64}"))&&value.isNotBlank()&&value.length<=2000);map[hash]=value}
                    cache.translations[target]=map
                }
                cache.terminal=json.optDouble("terminal",-1.0);require(cache.terminal.isFinite())
                cache.revision=maxOf(cache.revision,json.optLong("revision"));cache.originalRevision=cache.revision;cache.savedRevision=cache.revision
            }.onFailure{cache.cues.clear();cache.covered.clear();cache.translations.clear();cache.terminal=-1.0;cache.revision=0;cache.originalRevision=0;cache.savedRevision=0}
            return cache
        }
        @Synchronized fun clear(files: File,networkOnly: Boolean): Boolean {
            shared.values.mapNotNull{it.get()}.filter{!networkOnly||it.network}.forEach{it.revoke()};shared.entries.removeAll{it.value.get()?.revoked!=false}
            var ok=true
            for(file in directory(files).listFiles().orEmpty()){
                if(networkOnly && !runCatching{JSONObject(file.readText()).optBoolean("network",true)}.getOrDefault(true))continue
                if(file.exists()&&!file.delete())ok=false
            };return ok
        }
        private fun sha256(value: String)=MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString(""){"%02x".format(it)}
    }
}
