package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** USB sessions have private URIs, never writable file paths. Only explicit browsing opens/reopens one. */
internal class UsbStorage(private val host: () -> Activity?, private val emit: (Int,String)->Unit, private val changed: ()->Unit) : Closeable {
    private val worker=Executors.newSingleThreadExecutor { Thread(it,"ThruUsbStorage") }
    private val sessions=linkedMapOf<String,Session>()
    private val waiting=mutableMapOf<String,MutableList<Pair<Int,String>>>()
    private var watched: Context?=null
    @Volatile private var closed=false
    private fun enqueue(task:()->Unit):Boolean {
        if(closed) return false
        return try { worker.execute(task); true } catch(_:RejectedExecutionException) { false }
    }
    private val action get() = (host()?.packageName ?: "org.vrpassthroughplayer")+".USB_STORAGE_PERMISSION"
    private class Session(val device: UsbDevice) {
        val token=UUID.randomUUID().toString()
        val root="usb://$token"
        val generation=AtomicInteger()
        @Volatile var active=false
        @Volatile var stopping=false
        var connection: UsbDeviceConnection?=null
        var face: UsbInterface?=null
        val blocks=linkedMapOf<Int,UsbBulkDevice>()
        val partitions=linkedMapOf<String,Pair<Int,UsbPartitions.Partition>>()
        val volumes=mutableSetOf<Long>()
        val mounted=mutableMapOf<String,Pair<Long,Int>>()
        val subtitleIdentities=mutableMapOf<String,String>()
        val streams=linkedMapOf<String,LocalStreamServer>()
        var stage="discovery"
        var scan=JSONObject()
    }
    private fun manager() = host()?.getSystemService(UsbManager::class.java) ?: throw IOException("USB unavailable")
    private fun face(device: UsbDevice) = (0 until device.interfaceCount).map(device::getInterface).firstOrNull {
        it.interfaceClass==UsbConstants.USB_CLASS_MASS_STORAGE && it.interfaceSubclass==6 && it.interfaceProtocol==80
    }
    private val receiver=object:BroadcastReceiver() {
        @Suppress("DEPRECATION") override fun onReceive(context: Context,intent: Intent) {
            val device=intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            if(intent.action==action) {
                val requests=synchronized(this@UsbStorage) { waiting.remove(device.deviceName).orEmpty().toList() }
                for((id,path) in requests) {
                    // Query the authoritative grant; immutable PendingIntents need no fill-in extras.
                    if(runCatching { manager().hasPermission(device) }.getOrDefault(false)) browse(id,path)
                    else emit(id,JSONObject().put("source","local").put("state","error").put("path",path).put("error","USB access denied").toString())
                }
            } else {
                val detached=if(intent.action==UsbManager.ACTION_USB_DEVICE_DETACHED) synchronized(this@UsbStorage) {
                    sessions[device.deviceName]?.also { it.active=false; it.stopping=true }
                } else null
                enqueue { runCatching {
                    detached?.let { s-> stop(s); synchronized(this@UsbStorage) { if(sessions[device.deviceName]===s) sessions.remove(device.deviceName) } }
                    roots(); changed()
                } }
            }
        }
    }
    @Synchronized private fun watch() {
        if(watched!=null || closed) return
        val context=host()?.applicationContext ?: return
        val filter=IntentFilter().apply { addAction(action); addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED); addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if(Build.VERSION.SDK_INT>=33) context.registerReceiver(receiver,filter,Context.RECEIVER_NOT_EXPORTED) else context.registerReceiver(receiver,filter)
        watched=context
    }
    fun roots(): JSONArray {
        val result=JSONArray(); if(closed) return result
        if(runCatching { watch() }.isFailure) return result
        val devices=runCatching { manager().deviceList.values.filter { face(it)!=null }.associateBy { it.deviceName } }.getOrElse { return result }
        val removed=mutableListOf<Session>()
        val cancelled=mutableListOf<Pair<Int,String>>()
        val present=synchronized(this) {
            if(closed) return result
            for(key in sessions.keys.toList()) if(key !in devices) {
                removed.add(sessions.remove(key)!!.also { it.active=false })
                cancelled.addAll(waiting.remove(key).orEmpty())
            }
            devices.map { (key,device)->sessions.getOrPut(key) { Session(device) } }
        }
        // Native close can wait for an in-flight transfer. Never hold the registry monitor
        // during that wait: detach/stop callbacks on Android's UI thread must stay responsive.
        removed.forEach { stop(it) }
        cancelled.forEach { (id,path)->replyError(id,path,"USB storage unavailable") }
        for(s in present) {
            result.put(JSONObject().put("id",s.root).put("title",runCatching { s.device.productName }.getOrNull()?.takeIf { it.isNotBlank() } ?: "USB storage")
                .put("volume",true).put("container",true).put("removable",true).put("managed_usb",true).put("read_only",true)
                .put("storage_access","usb")
                .put("can_delete",false).put("can_rename",false).put("active",s.active))
        }
        return result
    }
    private fun allRoots(): JSONArray {
        val context=host() ?: throw IOException("USB unavailable")
        val roots=LocalStorageVolumes.roots(context)
        val raw=roots(); for(i in 0 until raw.length()) roots.put(raw.get(i))
        return roots
    }
    @Synchronized private fun session(uri: String): Session {
        val parsed=Uri.parse(uri)
        require(parsed.scheme=="usb" && parsed.query==null && parsed.fragment==null && parsed.userInfo==null)
        return sessions.values.firstOrNull { it.token==parsed.authority } ?: throw IOException("USB storage unavailable")
    }
    private fun busySystemStorage(): Boolean = host()?.getSystemService(StorageManager::class.java)?.storageVolumes?.any {
        it.isRemovable && it.state !in listOf("unmounted","unmountable","removed","bad_removal")
    } ?: true
    private fun connect(s: Session) = synchronized(s) {
        check(!s.stopping && !closed) { "USB access stopped" }
        if(s.active && s.connection!=null) return@synchronized
        s.scan=JSONObject(); s.stage="permission"
        val manager=manager(); check(manager.hasPermission(s.device)) { "USB access denied" }
        check(manager.deviceList[s.device.deviceName]?.deviceId==s.device.deviceId) { "USB storage unavailable" }
        val f=face(s.device) ?: throw IOException("Unsupported USB device")
        val c=manager.openDevice(s.device) ?: throw IOException("USB storage unavailable")
        var claimed=false
        try {
            s.stage="claim"
            claimed=c.claimInterface(f,false)
            // Some kernels bind usb-storage even to an unmountable filesystem. Detach that
            // idle driver only after a conservative system-volume check, never a mounted one.
            if(!claimed && !busySystemStorage()) { Thread.sleep(350); if(!busySystemStorage()) claimed=c.claimInterface(f,true) }
            if(!claimed) throw IOException(if(busySystemStorage()) "USB device is in use; open a system-mounted entry" else "USB device is in use")
            s.connection=c; s.face=f; s.active=true
            s.stage="lun"
            val value=ByteArray(1)
            val got=c.controlTransfer(0xa1,0xfe,0,f.id,value,1,1000)
            val max=if(got==1) value[0].toInt() and 255 else 0
            if(max>15) throw IOException("Invalid USB LUN response")
            s.stage="scan"
            val scan=UsbProbe.scan(0..max, { s.active && !s.stopping && !closed }) { lun ->
                UsbBulkDevice(c,f,lun) { s.active && !s.stopping && !closed }.also { s.blocks[lun]=it }
            }
            s.scan=scan.json()
            scan.found.forEach { (lun,p) -> s.partitions["$lun-${p.first}"]=lun to p }
            if(PlaybackPrivacy.diagnostics) android.util.Log.i("ThruUsb", "scan ${s.scan}")
            if(s.partitions.isEmpty()) throw IOException(scan.error())
            s.stage="ready"
        } catch(e:Exception) {
            s.active=false; s.blocks.values.forEach { it.close() }; s.blocks.clear(); s.partitions.clear(); s.connection=null; s.face=null
            if(claimed) c.releaseInterface(f); c.close(); throw e
        }
    }
    private fun request(id: Int,path: String,s: Session,generation:Int?) {
        val first=synchronized(this) {
            check(!s.stopping && s.generation.get()==generation) { "USB access stopped" }
            val queue=waiting.getOrPut(s.device.deviceName){mutableListOf()}; queue.add(id to path); queue.size==1
        }
        if(first) host()?.runOnUiThread {
            if(!closed && s.generation.get()==generation && synchronized(this) { waiting[s.device.deviceName]?.isNotEmpty()==true }) try {
                val intent=Intent(action).setPackage(host()?.packageName).putExtra(UsbManager.EXTRA_DEVICE,s.device)
                val pending=PendingIntent.getBroadcast(host(),s.device.deviceId,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                manager().requestPermission(s.device,pending)
            } catch (_:Exception) {
                val queued=synchronized(this) { if(s.generation.get()==generation) waiting.remove(s.device.deviceName).orEmpty() else emptyList() }
                queued.forEach { (request,where)->replyError(request,where,"USB access denied") }
            }
        }
    }
    fun browse(id: Int,path: String) {
        if(closed) return
        val requested=runCatching { session(path) }.getOrNull()
        val generation=requested?.generation?.get()
        enqueue {
            try {
                roots(); val s=session(path)
                check(s===requested && s.generation.get()==generation && !s.stopping) { "USB access stopped" }
                if(!manager().hasPermission(s.device)) { request(id,path,s,generation); return@enqueue }
                emit(id,JSONObject().put("source","local").put("state","loading").put("path",path).put("error","Reading USB storage…").toString())
                connect(s)
                val entries=if(path.trimEnd('/')==s.root) synchronized(s) {
                    JSONArray().apply { s.partitions.forEach { (key,value)-> put(JSONObject().put("id",s.root+"/"+key).put("title",value.second.filesystem+" · "+(s.partitions.keys.indexOf(key)+1)).put("container",true).put("read_only",true).put("can_delete",false).put("can_rename",false)) } }
                } else { s.stage="filesystem"; directory(path,true).also { s.stage="ready" } }
                emit(id,JSONObject().put("source","local").put("state","ready").put("path",path).put("all_files",true).put("entries",entries).put("volumes",allRoots()).toString())
            } catch(e:Exception) {
                val s=runCatching { session(path) }.getOrNull()
                if(PlaybackPrivacy.diagnostics) android.util.Log.w("ThruUsb", "browse failed stage=${s?.stage ?: "discovery"} kind=${e.javaClass.simpleName}")
                emit(id,JSONObject().put("source","local").put("state","error").put("path",path).put("access_kind","none")
                    .put("error",e.message?.takeIf { it.isNotBlank() } ?: "USB storage unavailable")
                    .put("usb_stage",s?.stage ?: "discovery").put("usb_scan",s?.scan ?: JSONObject()).toString())
            }
        }
    }
    private fun replyError(id: Int,path: String,error: String) = emit(id,JSONObject().put("source","local").put("state","error").put("path",path).put("error",error).toString())
    internal class PartitionReader(val disk: UsbBlocks,val part: UsbPartitions.Partition,val alive: ()->Boolean) {
        private val cache=object:LinkedHashMap<Long,ByteArray>(64,0.75f,true) { override fun removeEldestEntry(eldest:MutableMap.MutableEntry<Long,ByteArray>?)=size>64 }
        val length=part.count*disk.sectorSize
        @Synchronized fun read(offset: Long,data: ByteArray): Int {
            if(!alive()) throw IOException("USB access stopped")
            require(offset>=0 && offset<=length && data.size<=length-offset)
            var at=offset; var out=0
            while(out<data.size) {
                if(!alive()) throw IOException("USB access stopped")
                val base=at/65536*65536
                val bytes=cache.getOrPut(base) { ByteArray(minOf(65536L,length-base).toInt()).also { disk.readBlocks(part.first+base/disk.sectorSize,it) } }
                val start=(at-base).toInt(); val n=minOf(data.size-out,bytes.size-start)
                bytes.copyInto(data,out,start,start+n); at+=n; out+=n
            }
            if(!alive()) throw IOException("USB access stopped")
            return out
        }
    }
    private data class Opened(val session:Session,val volume:Long,val path:String,val key:String)
    private fun mount(uri: String): Opened {
        check(UsbFsNative.available) { "USB storage unavailable" }
        val s=session(uri)
        return synchronized(s) {
            if(!s.active) throw IOException("USB access stopped")
            val parts=Uri.parse(uri).pathSegments
            require(parts.isNotEmpty() && parts.none { it=="." || it==".." || '/' in it || '\\' in it || '\u0000' in it })
            val (lun,part)=s.partitions[parts[0]] ?: throw IOException("USB partition unavailable")
            val disk=s.blocks[lun] ?: throw IOException("USB storage unavailable")
            val existing=s.mounted[parts[0]]
            val volume=existing?.first ?: PartitionReader(disk,part) { s.active && !closed }.let { reader ->
                UsbFsNative.mount(reader,reader.length,disk.sectorSize,part.filesystem=="NTFS")
            }
            s.mounted[parts[0]]=volume to ((existing?.second ?: 0)+1)
            s.volumes.add(volume)
            Opened(s,volume,"/"+parts.drop(1).joinToString("/"),parts[0])
        }
    }
    private fun release(open:Opened) = synchronized(open.session) {
        val existing=open.session.mounted[open.key]
        if(existing?.first==open.volume) {
            if(existing.second>1) open.session.mounted[open.key]=open.volume to existing.second-1
            else { UsbFsNative.closeVolume(open.volume); open.session.volumes.remove(open.volume); open.session.mounted.remove(open.key) }
        }
        Unit
    }
    private fun child(parent:String,name:String)=parent.trimEnd('/')+"/"+Uri.encode(name)
    private fun directory(uri:String,mediaOnly:Boolean):JSONArray {
        val open=mount(uri)
        return try {
            val raw=JSONArray(UsbFsNative.list(open.volume,open.path.toByteArray(Charsets.UTF_8)).toString(Charsets.UTF_8))
            val rows=(0 until raw.length()).map(raw::getJSONObject).filter { !it.getString("name").startsWith('.') && (it.getBoolean("directory") || !mediaOnly || MediaKinds.supportedFileName(it.getString("name"))) }
                .sortedWith(compareBy({ !it.getBoolean("directory") },{ it.getString("name").lowercase() }))
            JSONArray().apply { for(row in rows) {
                val name=row.getString("name"); val folder=row.getBoolean("directory"); val location=child(uri,name)
                put(JSONObject().put("id",location).put("uri",location).put("title",name).put("container",folder).put("size",row.getLong("size"))
                    .put("kind",if(folder) "folder" else MediaKinds.fileNameKind(name)).put("read_only",true).put("can_delete",false).put("can_rename",false))
            } }
        } finally { release(open) }
    }
    fun source(uri:String): StreamSource = object:StreamSource {
        private val opened=mount(uri)
        private val probe=try { UsbFsNative.open(opened.volume,opened.path.toByteArray(Charsets.UTF_8)) } catch(e:Exception) { release(opened); throw e }
        override val size=UsbFsNative.size(probe).also { UsbFsNative.closeFile(probe) }
        private val sourceClosed=AtomicBoolean(false)
        override fun open():StreamSource.Reader {
            check(!sourceClosed.get() && opened.session.active) { "USB access stopped" }
            val file=UsbFsNative.open(opened.volume,opened.path.toByteArray(Charsets.UTF_8))
            return object:StreamSource.Reader {
                override fun read(offset:Long,buffer:ByteArray,length:Int):Int { check(!sourceClosed.get() && opened.session.active) { "USB access stopped" }; return UsbFsNative.read(file,offset,buffer,minOf(length,1024*1024)) }
                override fun close() { UsbFsNative.closeFile(file) }
            }
        }
        override fun close() { if(sourceClosed.compareAndSet(false,true)) release(opened) }
    }
    fun siblings(uri:String):JSONArray = directory(uri.substringBeforeLast('/'),false)
    fun subtitleIdentity(uri:String):String {
        val s=session(uri)
        return synchronized(s) {
            check(s.active && !s.stopping && !closed) { "USB access stopped" }
            val parts=Uri.parse(uri).pathSegments
            val (lun,part)=s.partitions[parts.first()] ?: throw IOException("USB partition unavailable")
            val key=s.subtitleIdentities.getOrPut(parts.first()) {
                val disk=s.blocks[lun] ?: throw IOException("USB storage unavailable")
                val boot=ByteArray(disk.sectorSize).also { disk.readBlocks(part.first,it) }
                UsbSubtitleIdentity.partition(part,disk.sectorSize,boot)
            }
            "usb://stable/$key/"+parts.drop(1).joinToString("/") { Uri.encode(it) }
        }
    }
    fun sibling(uri:String,name:String)=child(uri.substringBeforeLast('/'),name)
    fun forgetStream(uri:String) {
        val values=synchronized(this) { sessions.values.toList() }
        values.forEach { s->synchronized(s) { s.streams.remove(uri) } }
    }
    fun stream(uri:String,server:LocalStreamServer):String {
        val s=session(uri)
        val source=source(uri)
        return synchronized(s) {
            try { check(s.active && !s.stopping) { "USB access stopped" }; server.publish(source,Uri.parse(uri).lastPathSegment ?: "video").also { s.streams[it]=server } }
            catch(e:Exception) { source.close(); throw e }
        }
    }
    fun stop(id:Int,path:String) {
        val s=runCatching { session(path) }.getOrNull()
        if(s==null || closed) {
            emit(id,JSONObject().put("source","local_eject").put("state","error").put("volume_id",path).put("error","USB storage unavailable").toString())
            return
        }
        s.generation.incrementAndGet()
        s.stopping=true; s.active=false // Invalidate callbacks immediately, before waiting for native readers.
        val cancelled=synchronized(this) { waiting.remove(s.device.deviceName).orEmpty().toList() }
        cancelled.forEach { (request,where)->replyError(request,where,"USB access stopped") }
        enqueue {
            try { stop(s); emit(id,JSONObject().put("source","local_eject").put("state","stopped").put("volume_id",s.root).put("unmounted",false).toString()); changed() }
            catch(e:Exception) { emit(id,JSONObject().put("source","local_eject").put("state","error").put("volume_id",s.root).put("error",e.message ?: "USB stop failed").toString()) }
        }
    }
    private fun stop(s:Session)=synchronized(s) {
        s.active=false
        s.streams.toMap().forEach { (uri,server)->server.revoke(uri) }; s.streams.clear()
        s.volumes.toList().forEach { UsbFsNative.closeVolume(it) }; s.volumes.clear(); s.mounted.clear()
        s.blocks.values.forEach { it.close() }; s.blocks.clear(); s.partitions.clear()
        s.connection?.let { c->s.face?.let { c.releaseInterface(it) }; c.close() }; s.connection=null; s.face=null; s.stopping=false
    }
    override fun close() {
        val values=synchronized(this) { if(closed) return; closed=true; sessions.values.toList().also { sessions.clear(); waiting.clear() } }
        values.forEach { it.active=false }
        worker.execute { values.forEach { stop(it) }; watched?.let { runCatching { it.unregisterReceiver(receiver) } }; watched=null }
        worker.shutdown()
    }
}
