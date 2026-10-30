package org.vrpassthroughplayer.plugin

/** ZipDepth video profiles. All headsets currently select 384x224 at LOW GPU priority.
 * The separately supplied 512x288 graph remains available for comparison, not the default. */
internal object VideoDepthProfiles {
    data class Profile(val shape: String, val asset: String)
    val QUALITY = Profile("512x288", "depth-mnn/depth.mnn")
    val COMPATIBLE = Profile("384x224", "depth-mnn/depth_compat.mnn")

    @Suppress("UNUSED_PARAMETER")
    fun forModel(model: String): Profile = COMPATIBLE
}
