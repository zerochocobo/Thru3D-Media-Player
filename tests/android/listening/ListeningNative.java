package org.vrpassthroughplayer.plugin;

/** Signatures of the production JNI bridge, for the standalone device probe. */
final class ListeningNative {
    static native long create(String directory, String language);
    static native void open(long engine, String path, int track, String ca, double start, boolean disc, int playlist);
    static native String step(long engine);
    static native void cancel(long engine);
    static native void destroy(long engine);
}
