package org.vrpassthroughplayer.plugin

import android.net.LocalServerSocket
import android.os.Handler
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Explicitly enabled, ephemeral ADB-local channel. Never writes raw captures to files/logs. */
internal class FixtureMemoryBridge(name: String, handler: Handler, request: (JSONObject) -> JSONObject) : AutoCloseable {
    private val server = LocalServerSocket(name)
    @Volatile private var closed = false
    init {
        Thread({
            while (!closed) {
                val socket = try { server.accept() } catch (_: Exception) { break }
                socket.use {
                    runCatching {
                        it.soTimeout = 5000
                        val input = it.inputStream
                        val bytes = java.io.ByteArrayOutputStream()
                        while (bytes.size() <= 4096) {
                            val next = input.read()
                            if (next < 0 || next == 10) break
                            bytes.write(next)
                        }
                        require(bytes.size() in 1..4096)
                        val command = JSONObject(bytes.toString("UTF-8"))
                        val done = CountDownLatch(1)
                        var response = JSONObject().put("ok",false)
                        handler.post {
                            try { if (!closed) response = request(command) }
                            catch (_: Exception) { response = JSONObject().put("ok",false) }
                            finally { done.countDown() }
                        }
                        check(done.await(4,TimeUnit.SECONDS))
                        val body = response.toString().toByteArray(Charsets.UTF_8)
                        require(body.size <= 256*1024)
                        it.outputStream.write(body);it.outputStream.flush()
                    }
                }
            }
        },"FixtureMemoryBridge").apply { isDaemon=true;start() }
    }
    override fun close() { closed=true;runCatching { server.close() } }
}
