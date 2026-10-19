package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.io.File

internal object NarrationAssets {
    private val stores=java.util.concurrent.ConcurrentHashMap<String,PersonalVoiceStore>()
    fun prepare(app: Context, clone: Boolean=false, active: ()->Boolean): File {
        val manifest=app.assets.open(if(clone)"narration/clone_model.json" else "narration/model.json").bufferedReader().use {JSONObject(it.readText())}
        val name=manifest.getString("directory");val root=File(app.filesDir,name).canonicalFile
        require(root.path.startsWith(app.filesDir.canonicalPath+File.separator))
        NarrationModels.ensure(root,manifest.getJSONObject("files"),{app.assets.open("$name/$it")},active,{})
        return root
    }
    fun voices(app: Context): PersonalVoiceStore {
        val root=File(app.filesDir,"narration/voices").canonicalFile
        return stores.computeIfAbsent(root.path){PersonalVoiceStore(root)}
    }
}
