package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import java.security.MessageDigest

/** Accessed under the controller lock. A translated page never falls back to original audio. */
internal class ComicSpeechRouting {
    data class Text(val text: String,val language: String,val suffix: String)
    private var epoch=0L
    private var mode=""
    var language="";private set
    val translated get()=language.isNotEmpty()
    private val rows=HashMap<Pair<Int,Int>,Text>()
    fun page(value: Long){epoch=value;rows.clear()}
    fun mode(value: String,target: String): Boolean {
        require(target.isEmpty()||target in NarrationPolicy.languages)
        if(value==mode&&target==language)return false
        mode=value;language=target;rows.clear();return true
    }
    fun update(pageEpoch: Long,version: String,values: JSONArray): Boolean {
        if(!translated||pageEpoch!=epoch||version!=mode)return false
        val next=HashMap<Pair<Int,Int>,Text>()
        for(i in 0 until values.length()){
            val row=values.getJSONObject(i);val page=row.getInt("page");val id=row.getInt("id")
            val text=row.getString("text").trim()
            require(page in 0..1&&id>=0&&text.isNotEmpty()&&text.codePointCount(0,text.length)<=2000)
            val digest=MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString(""){"%02x".format(it)}
            require(next.put(page to id,Text(text,language,":translated:$language:$digest"))==null)
        }
        rows.clear();rows.putAll(next);return true
    }
    fun resolve(page: Int,id: Int,original: String,originalLanguage: String): Text? =
        if(translated)rows[page to id] else Text(original,originalLanguage,"")
}
