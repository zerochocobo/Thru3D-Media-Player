package org.vrpassthroughplayer.plugin

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Fallback SMB discovery that needs nothing from the server but an open TCP 445: Windows answers
 * WS-Discovery only on a Private network with Function Discovery Resource Publication running,
 * while a working share always accepts 445. Names come from a NetBIOS node status query (UDP 137)
 * when the host still answers one. Network calls block; the packet helpers are pure (JVM tested). */
internal object SmbLanScan {
    /** Diagnostics sink (android.util.Log on device; silent in JVM tests). */
    @Volatile var log: (String) -> Unit = {}

    /** Hosts on each local IPv4 subnet, own addresses excluded. Prefixes wider than /24 scan only
     * the /24 around the local address: a /16 would be 65k probes. Link-local is skipped. */
    fun candidates(local: List<Pair<Inet4Address, Int>>): List<Inet4Address> {
        val own = local.map { bits(it.first) }.toHashSet()
        val result = LinkedHashSet<Int>()
        for ((address, prefix) in local) {
            val ip = bits(address)
            if (address.isLinkLocalAddress || address.isLoopbackAddress || prefix !in 1..30) continue
            val width = prefix.coerceAtLeast(24)
            val mask = -1 shl (32 - width)
            val network = ip and mask
            val broadcast = network or mask.inv()
            for (host in network + 1 until broadcast) if (host !in own) result.add(host)
        }
        return result.map { address(it) }
    }

    /** Addresses that accepted a TCP connection on 445 within [timeoutMs] overall. */
    fun hosts(interfaces: List<NetworkInterface>, timeoutMs: Int): List<String> {
        val local = interfaces.flatMap { lan ->
            lan.interfaceAddresses.mapNotNull { a -> (a.address as? Inet4Address)?.let { it to a.networkPrefixLength.toInt() } }
        }
        val targets = candidates(local)
        if (targets.isEmpty()) return emptyList()
        val open = ConcurrentLinkedQueue<String>()
        val connectMs = 600
        // One short-lived thread per probe up to 256: a /24 finishes in a single connect timeout.
        val pool = Executors.newFixedThreadPool(targets.size.coerceAtMost(256)) { Thread(it, "QuestSmbScan").apply { isDaemon = true } }
        try {
            for (target in targets) pool.execute {
                runCatching { Socket().use { it.connect(InetSocketAddress(target, 445), connectMs) } }
                    .onSuccess { open.add(target.hostAddress) }
            }
            pool.shutdown()
            pool.awaitTermination(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        } finally { pool.shutdownNow() }
        log("smb scan: ${targets.size} probed, ${open.size} open on 445")
        val order = targets.withIndex().associate { it.value.hostAddress to it.index }
        return open.toList().sortedBy { order[it] }
    }

    /** NetBIOS names for [hosts] that reply within [timeoutMs]; missing hosts stay unnamed. */
    fun names(hosts: Collection<String>, timeoutMs: Int): Map<String, String> {
        if (hosts.isEmpty()) return emptyMap()
        val result = HashMap<String, String>()
        runCatching {
            DatagramSocket().use { socket ->
                socket.soTimeout = 200
                hosts.forEachIndexed { index, host ->
                    val request = nodeStatusRequest(0x5100 + index)
                    runCatching { socket.send(DatagramPacket(request, request.size, InetSocketAddress(host, 137))) }
                }
                val deadline = System.currentTimeMillis() + timeoutMs
                val buffer = ByteArray(1024)
                while (System.currentTimeMillis() < deadline && result.size < hosts.size) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                    val host = packet.address.hostAddress ?: continue
                    if (host in hosts) nodeStatusName(packet.data.copyOf(packet.length))?.let { result[host] = it }
                }
            }
        }
        log("smb names: ${result.size}/${hosts.size} answered NetBIOS")
        return result
    }

    /** NBSTAT query for the wildcard name "*" (RFC 1002 4.2.17). */
    fun nodeStatusRequest(id: Int): ByteArray {
        val name = ByteArray(16).also { it[0] = '*'.code.toByte() }
        val packet = ByteArray(12 + 34 + 4)
        packet[0] = (id shr 8).toByte(); packet[1] = id.toByte()
        packet[5] = 1 // QDCOUNT
        packet[12] = 0x20
        for (i in 0 until 16) {
            val b = name[i].toInt() and 0xff
            packet[13 + i * 2] = ('A'.code + (b shr 4)).toByte()
            packet[14 + i * 2] = ('A'.code + (b and 0x0f)).toByte()
        }
        // packet[45] = 0 ends the name; QTYPE NBSTAT 0x0021, QCLASS IN 0x0001.
        packet[47] = 0x21; packet[49] = 0x01
        return packet
    }

    /** The machine name from a node status reply: the unique Server (0x20) entry, else the unique
     * Workstation (0x00) one. Null for anything malformed. */
    fun nodeStatusName(reply: ByteArray): String? {
        fun u8(i: Int) = reply[i].toInt() and 0xff
        if (reply.size < 12 || u8(2) and 0x80 == 0 || (u8(6) shl 8 or u8(7)) == 0) return null
        var at = 12
        while (at < reply.size) {
            val length = u8(at)
            if (length and 0xc0 == 0xc0) { at += 2; break }
            at += 1 + length
            if (length == 0) break
        }
        at += 10 // TYPE, CLASS, TTL, RDLENGTH
        if (at >= reply.size) return null
        val count = u8(at++)
        val entries = (0 until count).mapNotNull { i ->
            val start = at + i * 18
            if (start + 18 > reply.size) return@mapNotNull null
            val name = String(reply, start, 15, Charsets.ISO_8859_1).trimEnd(' ', '\u0000')
            val group = u8(start + 16) and 0x80 != 0
            Triple(name, u8(start + 15), group)
        }.filter { !it.third && it.first.isNotEmpty() }
        return (entries.firstOrNull { it.second == 0x20 } ?: entries.firstOrNull { it.second == 0x00 })?.first
    }

    private fun bits(address: Inet4Address): Int = address.address.fold(0) { acc, b -> acc shl 8 or (b.toInt() and 0xff) }
    private fun address(bits: Int): Inet4Address = Inet4Address.getByAddress(
        byteArrayOf((bits ushr 24).toByte(), (bits ushr 16).toByte(), (bits ushr 8).toByte(), bits.toByte())) as Inet4Address
}
