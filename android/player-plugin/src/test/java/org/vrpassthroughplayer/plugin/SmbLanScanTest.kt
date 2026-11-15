package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

class SmbLanScanTest {
    private fun ip(text: String) = InetAddress.getByName(text) as Inet4Address

    @Test fun candidatesCoverTheSubnetWithoutOwnNetworkOrBroadcastAddresses() {
        val hosts = SmbLanScan.candidates(listOf(ip("192.168.31.185") to 24)).map { it.hostAddress }
        assertEquals(253, hosts.size)
        assertEquals("192.168.31.1", hosts.first())
        assertEquals("192.168.31.254", hosts.last())
        assertFalse("192.168.31.185" in hosts)
    }

    @Test fun widePrefixesScanOnlyTheLocal24AndNarrowOnesStayNarrow() {
        val wide = SmbLanScan.candidates(listOf(ip("10.1.2.3") to 16)).map { it.hostAddress }
        assertEquals(253, wide.size)
        assertTrue(wide.all { it.startsWith("10.1.2.") })
        val narrow = SmbLanScan.candidates(listOf(ip("10.0.0.18") to 28)).map { it.hostAddress }
        assertEquals((17..30).map { "10.0.0.$it" }.filter { it != "10.0.0.18" }, narrow)
    }

    @Test fun linkLocalPointToPointAndDuplicateSubnetsAreSkipped() {
        assertTrue(SmbLanScan.candidates(listOf(ip("169.254.10.2") to 16, ip("10.0.0.1") to 32)).isEmpty())
        val twice = SmbLanScan.candidates(listOf(ip("192.168.1.10") to 24, ip("192.168.1.11") to 24))
        assertEquals(252, twice.size)
    }

    @Test fun nodeStatusRequestEncodesTheWildcardName() {
        val packet = SmbLanScan.nodeStatusRequest(0x1234)
        assertEquals(50, packet.size)
        assertEquals(0x12, packet[0].toInt()); assertEquals(0x34, packet[1].toInt())
        assertEquals(1, packet[5].toInt())
        assertEquals(0x20, packet[12].toInt())
        assertEquals("CK" + "A".repeat(30), String(packet, 13, 32, Charsets.US_ASCII))
        assertEquals(0, packet[45].toInt())
        assertEquals(listOf(0, 0x21, 0, 1), (46..49).map { packet[it].toInt() })
    }

    private fun reply(vararg entries: Triple<String, Int, Boolean>, compressed: Boolean = false): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(0x12, 0x34, 0x84.toByte(), 0, 0, 0, 0, 1, 0, 0, 0, 0))
        if (compressed) out.write(byteArrayOf(0xc0.toByte(), 0x0c))
        else { out.write(0x20); out.write(("CK" + "A".repeat(30)).toByteArray()); out.write(0) }
        out.write(byteArrayOf(0, 0x21, 0, 1, 0, 0, 0, 0, 0, (1 + entries.size * 18).toByte()))
        out.write(entries.size)
        for ((name, suffix, group) in entries) {
            out.write(name.padEnd(15).toByteArray(Charsets.ISO_8859_1)); out.write(suffix)
            out.write(if (group) 0x84 else 0x04); out.write(0)
        }
        out.write(ByteArray(6)) // unit id
        return out.toByteArray()
    }

    @Test fun nodeStatusNamePrefersTheUniqueServerEntry() {
        val windows = reply(Triple("WORKGROUP", 0x00, true), Triple("DESKTOP-ABC", 0x00, false),
            Triple("DESKTOP-ABC", 0x20, false), Triple("WORKGROUP", 0x1e, true))
        assertEquals("DESKTOP-ABC", SmbLanScan.nodeStatusName(windows))
        assertEquals("NAS", SmbLanScan.nodeStatusName(reply(Triple("HOME", 0x20, true), Triple("NAS", 0x00, false), compressed = true)))
    }

    @Test fun malformedOrGroupOnlyRepliesHaveNoName() {
        assertNull(SmbLanScan.nodeStatusName(ByteArray(0)))
        assertNull(SmbLanScan.nodeStatusName(SmbLanScan.nodeStatusRequest(1)))
        assertNull(SmbLanScan.nodeStatusName(reply(Triple("WORKGROUP", 0x00, true))))
        assertNull(SmbLanScan.nodeStatusName(reply(Triple("DESKTOP-ABC", 0x20, false)).copyOf(60)))
    }

    /** Opt-in live check against this machine's LAN: SMB_LAN_SCAN=1. */
    @Test fun liveScanFindsLanSmbHosts() {
        assumeTrue(System.getenv("SMB_LAN_SCAN") == "1")
        val lans = NetworkInterface.getNetworkInterfaces().toList().filter {
            it.isUp && !it.isLoopback && it.supportsMulticast() && it.inetAddresses.toList().any { a -> a is Inet4Address }
        }
        SmbLanScan.log = { println(it) }
        val started = System.currentTimeMillis()
        val hosts = SmbLanScan.hosts(lans, 2500)
        println("445 open: $hosts in ${System.currentTimeMillis() - started} ms")
        println("names: ${SmbLanScan.names(hosts, 800)}")
    }
}
