package org.vrpassthroughplayer.plugin;

final class ComicOcrNative {
    static native long create(String directory);
    static native void cancel(long engine, long generation);
    static native byte[] analyze(long engine, byte[] rgb, int width, int height, long generation, boolean unrestricted);
    static native void destroy(long engine);
}
