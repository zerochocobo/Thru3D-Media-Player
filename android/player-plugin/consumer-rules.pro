# Called by JNI through GetMethodID, including when the consuming APK uses R8.
-keepclassmembers class org.vrpassthroughplayer.plugin.UsbStorage$PartitionReader {
    public int read(long, byte[]);
}
-keep class org.vrpassthroughplayer.plugin.UsbFsNative { *; }
-keep class org.vrpassthroughplayer.plugin.NarrationNative { *; }
-keepclassmembers class * implements org.vrpassthroughplayer.plugin.NarrationNative$Sink {
    public boolean onChunk(long, float[]);
}
