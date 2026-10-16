package org.vrpassthroughplayer.plugin

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import java.io.Closeable
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Read-only BOT/SCSI adaptation following libaums' command/data/status sequencing.
 * Upstream: magnusja/libaums 57fa4826, Copyright 2014 mjahnen, Apache-2.0.
 * No write, mode-select, format, repair, or forced interface-claim operation is exposed. */
internal class UsbBulkDevice(private val connection: UsbDeviceConnection, private val face: UsbInterface, private val lun: Int, private val alive: ()->Boolean = { true }) : UsbBlocks, Closeable {
    private val input: UsbEndpoint = (0 until face.endpointCount).map(face::getEndpoint).first { it.direction==UsbConstants.USB_DIR_IN && it.type==UsbConstants.USB_ENDPOINT_XFER_BULK }
    private val output: UsbEndpoint = (0 until face.endpointCount).map(face::getEndpoint).first { it.direction==UsbConstants.USB_DIR_OUT && it.type==UsbConstants.USB_ENDPOINT_XFER_BULK }
    private var sequence=0
    @Volatile private var closed=false
    override var sectorSize=512; private set
    override var sectorCount=0L; private set
    init {
        var failure: Exception?=null
        for(attempt in 0..3) {
            try {
                command(byteArrayOf(0x00,0,0,0,0,0),0)
                val cap=command(byteArrayOf(0x25,0,0,0,0,0,0,0,0,0),8)
                val (size,count)=UsbScsi.capacity(cap) {
                    val c=ByteArray(16); c[0]=0x9e.toByte(); c[1]=0x10; c[13]=32
                    command(c,32)
                }
                sectorSize=size; sectorCount=count; failure=null; break
            } catch(e: IOException) {
                if(!alive()) throw e
                failure=e
                runCatching { command(byteArrayOf(3,0,0,0,18,0),18) }
                if(attempt<3) Thread.sleep(150)
            }
        }
        if(failure!=null) throw failure
    }
    private fun transfer(endpoint: UsbEndpoint, bytes: ByteArray, count: Int) {
        var at=0
        while(at<count) {
            if(closed || !alive() || Thread.currentThread().isInterrupted) throw IOException("USB storage unavailable")
            val chunk=minOf(count-at,16*1024)
            val got=connection.bulkTransfer(endpoint,bytes,at,chunk,2000)
            if(got<=0) throw IOException("USB transfer failed")
            at+=got
        }
    }
    private fun command(cdb: ByteArray, bytes: Int): ByteArray = synchronized(connection) {
        if(closed || !alive()) throw IOException("USB access stopped")
        // All supported opcodes are either data-in or non-mutating readiness queries.
        require((cdb[0].toInt() and 255) in listOf(0x00,0x03,0x25,0x28,0x88,0x9e))
        val tag=++sequence
        val cbw=ByteBuffer.allocate(31).order(ByteOrder.LITTLE_ENDIAN)
        cbw.putInt(0x43425355).putInt(tag).putInt(bytes).put(if(bytes>0) 0x80.toByte() else 0).put(lun.toByte()).put(cdb.size.toByte()).put(cdb)
        try {
            transfer(output,cbw.array(),31)
            val data=ByteArray(bytes); if(bytes>0) transfer(input,data,bytes)
            val status=ByteArray(13); transfer(input,status,13)
            val csw=ByteBuffer.wrap(status).order(ByteOrder.LITTLE_ENDIAN)
            if(csw.int!=0x53425355 || csw.int!=tag || csw.int!=0 || csw.get().toInt()!=0) throw IOException("USB command failed")
            data
        } catch(e: Exception) {
            if(closed || !alive()) throw e
            // Discard a broken command; never retry a partially consumed data phase as a new read.
            connection.controlTransfer(0x21,0xff,0,face.id,null,0,1000)
            for(endpoint in listOf(input,output)) connection.controlTransfer(2,1,0,endpoint.address,null,0,1000)
            throw e
        }
    }
    @Synchronized override fun readBlocks(lba: Long,data: ByteArray) {
        require(lba>=0 && data.size%sectorSize==0 && lba<=sectorCount && data.size/sectorSize<=sectorCount-lba)
        if(data.isEmpty()) return
        var offset=0; var sector=lba
        while(offset<data.size) {
            val n=minOf(data.size-offset,512*1024); val blocks=n/sectorSize
            val c=UsbScsi.read(sector,blocks)
            command(c,n).copyInto(data,offset); offset+=n; sector+=blocks
        }
    }
    override fun close() { closed=true }
}
