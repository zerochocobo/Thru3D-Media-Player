package org.vrpassthroughplayer.plugin

import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.*
import java.io.File
import java.util.concurrent.Executors

/** One encoding per private process. Parent acknowledges the result before the process exits. */
class VoiceCloneService : Service() {
    private val executor=Executors.newSingleThreadExecutor {Thread(it,"VoiceReferenceEncoder")}
    private var started=false
    private fun finishProcess() {
        stopSelf()
        if(Application.getProcessName().endsWith(":voice_clone"))Process.killProcess(Process.myPid())
    }
    private val messenger=Messenger(Handler(Looper.getMainLooper()){ message ->
        when(message.what) {
            2 -> finishProcess()
            1 -> if(!started) {
                started=true
                @Suppress("DEPRECATION") val input=message.data.getParcelable<ParcelFileDescriptor>("input")
                @Suppress("DEPRECATION") val output=message.data.getParcelable<ParcelFileDescriptor>("output")
                val model=message.data.getString("model").orEmpty();val reply=message.replyTo
                executor.execute {
                    val ok=runCatching {
                        require(Application.getProcessName().endsWith(":voice_clone"))
                        val file=File(model).canonicalFile;require(file.path.startsWith(filesDir.canonicalPath+File.separator)&&file.isFile)
                        require(input!=null&&output!=null)
                        VoiceCloneNative.encode(file.path,"/proc/self/fd/${input.fd}","/proc/self/fd/${output.fd}")
                    }.isSuccess
                    runCatching {input?.close();output?.close();reply.send(Message.obtain(null,if(ok)200 else 500))}
                    Handler(Looper.getMainLooper()).postDelayed({finishProcess()},5000)
                }
            }
        };true
    })
    override fun onBind(intent: Intent)=messenger.binder
    override fun onUnbind(intent: Intent): Boolean {finishProcess();return false}
    override fun onDestroy(){executor.shutdownNow();super.onDestroy()}
}
