package org.vrpassthroughplayer.plugin

import android.content.*
import android.os.*
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class VoiceEncoderClient(private val app: Context) : AutoCloseable {
    private val done=CountDownLatch(1)
    private val departed=CountDownLatch(1)
    private val closed=AtomicBoolean()
    @Volatile private var remote: Messenger?=null
    @Volatile private var success=false
    @Volatile private var bound=false
    private var connection: ServiceConnection?=null
    fun encode(model: File,input: File,output: File,active: ()->Boolean) {
        val reply=Messenger(Handler(Looper.getMainLooper()){m->success=m.what==200;done.countDown();true})
        val link=object: ServiceConnection {
            override fun onServiceConnected(name: ComponentName,binder: IBinder) {
                val service=Messenger(binder);remote=service
                runCatching {binder.linkToDeath({departed.countDown()},0)}
                if(closed.get()||!active()){runCatching {service.send(Message.obtain(null,2))};done.countDown();return}
                runCatching {
                    ParcelFileDescriptor.open(input,ParcelFileDescriptor.MODE_READ_ONLY).use {source ->
                        ParcelFileDescriptor.open(output,ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_READ_WRITE).use {target ->
                            val message=Message.obtain(null,1);message.replyTo=reply
                            message.data=Bundle().apply {putString("model",model.path);putParcelable("input",source);putParcelable("output",target)}
                            service.send(message)
                        }
                    }
                }.onFailure {done.countDown()}
            }
            override fun onServiceDisconnected(name: ComponentName){done.countDown()}
            override fun onNullBinding(name: ComponentName){done.countDown()}
            override fun onBindingDied(name: ComponentName){done.countDown()}
        }
        connection=link
        try {
            require(active());bound=app.bindService(Intent(app,VoiceCloneService::class.java),link,Context.BIND_AUTO_CREATE)
            check(bound);val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(45)
            while(!done.await(100,TimeUnit.MILLISECONDS)){check(active()&&!closed.get()&&System.nanoTime()<deadline){"voice_encoding_timeout"}}
            check(success&&active()&&!closed.get()) {"voice_encoding_failed"};PersonalVoiceStore.codes(output)
        } finally {close();check(departed.await(3,TimeUnit.SECONDS)||remote==null){"voice_encoder_still_running"}}
    }
    override fun close() {
        if(!closed.compareAndSet(false,true))return
        runCatching {remote?.send(Message.obtain(null,2))};if(bound)connection?.let {runCatching {app.unbindService(it)}}
        done.countDown()
    }
}
