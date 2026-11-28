package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * minSdk is 29, but `Os.fcntlInt/fcntlVoid/fcntlFlock` only became public in
 * API 30. Android 10 headsets (iQIYI A091) deny them at runtime, which broke
 * expanding the AirPlay window into the ordinary player and restarted the
 * window on every press. The pipe itself needs a device to run, so this guard
 * keeps the hidden calls out of the plugin sources.
 */
class AirplayPlayerPipeApiTest {
    @Test fun pluginSourcesAvoidFcntlHiddenOnApi29() {
        val root = File("src/main/java")
        assertTrue("plugin sources not found from ${File(".").absolutePath}", root.isDirectory)
        val offenders = root.walkTopDown().filter { it.isFile && it.extension in setOf("kt", "java") }
            .filter { file -> file.readLines().any { line ->
                !line.trimStart().startsWith("*") && !line.trimStart().startsWith("//") &&
                    Regex("""\bOs\.fcntl(Int|Void|Flock)\s*\(""").containsMatchIn(line)
            } }
            .map { it.name }.toList()
        assertTrue("API 30-only Os.fcntl* calls: $offenders", offenders.isEmpty())
    }
}
