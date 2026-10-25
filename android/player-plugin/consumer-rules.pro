# Called by JNI through GetMethodID, including when the consuming APK uses R8.
-keepclassmembers class org.vrpassthroughplayer.plugin.UsbStorage$PartitionReader {
    public int read(long, byte[]);
}
-keep class org.vrpassthroughplayer.plugin.UsbFsNative { *; }
-keep class org.vrpassthroughplayer.plugin.NarrationNative { *; }
-keep class org.vrpassthroughplayer.plugin.VoiceCloneNative { *; }
-keep class * implements org.vrpassthroughplayer.plugin.VoiceCloneNative$ScanListener { *; }
-keep class org.vrpassthroughplayer.plugin.OriginalClipNative { *; }
-keep class org.vrpassthroughplayer.plugin.PipScreenshotNative { *; }
-keep class org.vrpassthroughplayer.plugin.PipClipNative { *; }
-keep class org.vrpassthroughplayer.plugin.LiveCaptureNative { *; }
-keep class org.vrpassthroughplayer.plugin.TiffPhotoNative { *; }
-keep class org.vrpassthroughplayer.plugin.HdrPhotoNative { *; }
-keepclassmembers class * implements org.vrpassthroughplayer.plugin.NarrationNative$Sink {
    public boolean onChunk(long, float[]);
}
