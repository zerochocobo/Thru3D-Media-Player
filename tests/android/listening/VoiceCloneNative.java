package org.vrpassthroughplayer.plugin;

final class VoiceCloneNative {
    interface ScanListener { boolean frames(double start, float[] probability, float[] rms, float[] peak, boolean finished); }
    static native long createJob();
    static native void cancelJob(long job);
    static native void scan(long job, String path, int stream, String ca, double start, double end, boolean disc, int playlist, String model, ScanListener listener);
    static native void extract(long job, String path, int stream, String ca, double start, double end, String output, boolean disc, int playlist);
    static native void encode(String model, String wav, String output);
}
