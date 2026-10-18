package org.vrpassthroughplayer.plugin;

import android.content.*;
import android.graphics.ImageFormat;
import android.media.Image;
import android.media.ImageReader;
import android.opengl.*;
import android.os.*;
import android.view.Surface;
import dalvik.system.PathClassLoader;
import org.json.*;
import java.io.*;
import java.lang.reflect.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Standalone component acceptance. No APK installation, media modification or pixels recorded.
 * The controller must close the normal app before the optional cloud test to avoid a second DB owner. */
public class MediaPlaybackCompatibility {
    private static ClassLoader appLoader;
    private static final JSONArray upstreamRanges = new JSONArray();
    private static class ObservedConnection extends java.net.HttpURLConnection {
        private final java.net.HttpURLConnection original;
        ObservedConnection(java.net.HttpURLConnection original) { super(original.getURL()); this.original = original; }
        public void connect() throws IOException { original.connect(); }
        public void disconnect() { original.disconnect(); }
        public boolean usingProxy() { return original.usingProxy(); }
        public void setConnectTimeout(int value) { original.setConnectTimeout(value); }
        public void setReadTimeout(int value) { original.setReadTimeout(value); }
        public void setInstanceFollowRedirects(boolean value) { original.setInstanceFollowRedirects(value); }
        public void setUseCaches(boolean value) { original.setUseCaches(value); }
        public void setRequestProperty(String key, String value) { original.setRequestProperty(key, value); }
        public String getHeaderField(String key) { return original.getHeaderField(key); }
        public InputStream getInputStream() throws IOException { return original.getInputStream(); }
        public int getResponseCode() throws IOException {
            long start = System.nanoTime();
            JSONObject row = new JSONObject();
            try {
                row.put("range", original.getRequestProperty("Range"));
                synchronized (upstreamRanges) { if (upstreamRanges.length() < 4096) upstreamRanges.put(row); }
                int status = original.getResponseCode();
                synchronized (upstreamRanges) { row.put("status", status).put("headers_ms", (System.nanoTime() - start) / 1e6); }
                return status;
            } catch (org.json.JSONException error) { throw new IOException(error); }
        }
    }
    private static Class<?> type(String name) throws Exception { return appLoader.loadClass("org.vrpassthroughplayer.plugin." + name); }
    private static Object singleton(String name) throws Exception { return type(name).getField("INSTANCE").get(null); }
    private static Object call(Object object, String name, Object... args) throws Exception {
        for (Method method : object.getClass().getMethods()) if (method.getName().equals(name) && method.getParameterCount() == args.length) {
            try { return method.invoke(object, args); } catch (IllegalArgumentException ignored) { }
        }
        throw new NoSuchMethodException(name);
    }
    /** Instrument only this probe's newly owned lease. Never print endpoint,
     * credentials or tokens; delegate connection properties and IO unchanged. */
    private static AtomicInteger countUpstreamConnections(Object server, String url) throws Exception {
        Field sources = server.getClass().getDeclaredField("sources"); sources.setAccessible(true);
        String token = java.net.URI.create(url).getPath().split("/")[1];
        Object source = ((java.util.Map<?, ?>) sources.get(server)).get(token);
        if (source.getClass().getSimpleName().equals("AdaptiveInterleaveSource")) {
            Field inner = source.getClass().getDeclaredField("source"); inner.setAccessible(true); source = inner.get(source);
        }
        AtomicInteger attempts = new AtomicInteger();
        for (String name : new String[]{"linkConnection", "connect"}) {
            Field field = source.getClass().getDeclaredField(name); field.setAccessible(true);
            final Object original = field.get(source);
            if (original == null) continue;
            Object observed = Proxy.newProxyInstance(field.getType().getClassLoader(), new Class<?>[]{field.getType()}, (proxy, method, args) -> {
                if (method.getName().equals("invoke")) attempts.incrementAndGet();
                try {
                    Object result = method.invoke(original, args);
                    return method.getName().equals("invoke") && result instanceof java.net.HttpURLConnection
                        ? new ObservedConnection((java.net.HttpURLConnection) result) : result;
                }
                catch (InvocationTargetException error) { throw error.getCause(); }
            });
            field.set(source, observed);
            return attempts;
        }
        throw new IllegalStateException("Upstream connection hook unavailable");
    }
    private static void close(long handle) throws Exception {
        MpvSourceNative.requestClose(handle);
        for (int i = 0; i < 200; i++) {
            if (MpvSourceNative.close(handle, false)) return;
            Thread.sleep(50);
        }
        throw new IllegalStateException("Native close timed out");
    }
    private static long create(Context context, String url, String ca, Surface surface, boolean sequential, int position) {
        long handle = MpvSourceNative.create(context, url, position, true, true, 0, new String[0], new String[0],
            true, surface, false, 8192, 4096, false, ca, sequential);
        MpvSourceNative.setAudio(handle, -1, 0, true);
        MpvSourceNative.setPlaying(handle, true);
        return handle;
    }
    public static void main(String[] args) throws Exception {
        // native-directory, source-URI, label, duration-seconds, initial-layer, exercise-controls, [start-ms]
        if ((args.length != 6 && args.length != 7) || !args[2].matches("[A-Za-z0-9_-]{1,64}") || Integer.parseInt(args[3]) < 1 || Integer.parseInt(args[3]) > 180)
            throw new IllegalArgumentException("Probe arguments");
        int initialPosition = args.length == 7 ? Integer.parseInt(args[6]) : 0;
        if (initialPosition < 0) throw new IllegalArgumentException("Position");
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread"); Object thread = at.getMethod("systemMain").invoke(null);
        Context system = (Context) at.getMethod("getSystemContext").invoke(thread);
        Context raw = system.createPackageContext("com.wapok.thru3d", Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY);
        Context context = new ContextWrapper(raw) { public Context getApplicationContext() { return this; } };
        // Probe production classes and their APK dependencies must share one
        // loader. Mixing the APK's old StreamSource with a new AudioReadSpan
        // makes a cache test fail before any media has been read.
        String productionDex = System.getProperty("media.compat.production.dex");
        appLoader = productionDex == null ? context.getClassLoader() : new PathClassLoader(
            productionDex + File.pathSeparator + raw.getApplicationInfo().sourceDir,
            raw.getApplicationInfo().nativeLibraryDir + File.pathSeparator +
                raw.getApplicationInfo().sourceDir + "!/lib/arm64-v8a",
            ClassLoader.getSystemClassLoader().getParent());
        Class.forName("android.security.keystore2.AndroidKeyStoreProvider").getMethod("install").invoke(null);
        JSONObject report = new JSONObject().put("label", args[2]).put("stage", "starting");
        File output = new File(context.getCacheDir(), "media-compat-" + args[2] + ".json");
        Object server = null; AtomicInteger upstreamConnections = null; long handle = 0; ImageReader images = null; HandlerThread drain = null;
        EGLDisplay display = null; EGLContext gl = null; EGLSurface surface = null;
        try {
            String url = args[1];
            if (url.startsWith("cloud://")) {
                if (!new File(context.getNoBackupFilesDir(), "cloud-accounts-v2.bin").isFile()) throw new IllegalStateException("Existing account required");
                Object cloud = singleton("CloudLibrary"); call(cloud, "start", context);
                server = type("LocalStreamServer").getConstructor().newInstance();
                url = (String) call(cloud, "playable", url, server);
                upstreamConnections = countUpstreamConnections(server, url);
            }
            boolean sequential = Boolean.getBoolean("media.compat.force.sequential"), policyChecked = sequential;
            if (sequential && server != null && Boolean.getBoolean("media.compat.sequential.reuse"))
                report.put("sequential_transport_reuse", call(server, "enableInterleaveCache", url));
            report.put("sequential", sequential).put("diagnostic_force_sequential", sequential)
                .put("leading_audio_bytes", 0).put("metadata_probe_ms", 0).put("policy_diagnostic", "not_requested");
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY); int[] versions = new int[2];
            if (!EGL14.eglInitialize(display, versions, 0, versions, 1)) throw new Exception("EGL initialize");
            EGLConfig[] configs = new EGLConfig[1]; int[] count = new int[1];
            if (!EGL14.eglChooseConfig(display, new int[]{EGL14.EGL_RENDERABLE_TYPE, 64, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_NONE}, 0, configs, 0, 1, count, 0) || count[0] == 0) throw new Exception("EGL config");
            gl = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE}, 0);
            surface = EGL14.eglCreatePbufferSurface(display, configs[0], new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
            if (!EGL14.eglMakeCurrent(display, surface, surface, gl)) throw new Exception("EGL current");
            System.load(args[0] + "/libquest_mpv.so");
            AtomicInteger drained = new AtomicInteger();
            drain = new HandlerThread("MediaCompatDrain"); drain.start();
            images = ImageReader.newInstance(8192, 4096, ImageFormat.PRIVATE, 3);
            images.setOnImageAvailableListener(r -> { try (Image image = r.acquireLatestImage()) { if (image != null) drained.incrementAndGet(); } catch (Exception ignored) { } }, new Handler(drain.getLooper()));
            boolean layer = Boolean.parseBoolean(args[4]); boolean controls = Boolean.parseBoolean(args[5]);
            String ca = (String) call(singleton("MpvTlsTrust"), "prepare", context);
            handle = create(context, url, ca, layer ? images.getSurface() : null, sequential, initialPosition);
            int fallbackCount = 0, readPolicyRestarts = 0; long tickets = 0; long start = System.nanoTime(); double firstFrame = -1;
            double lastSnapshot = -1; boolean seekForward = false, seekBack = false, audioOff = false, audioOn = false;
            boolean far = args[2].endsWith("-far"); double forwardReady = -1, backReady = -1; long forwardFrames = 0, backFrames = 0;
            int forwardTarget = 1200000;
            JSONArray snapshots = new JSONArray(); report.put("snapshots", snapshots);
            while ((System.nanoTime() - start) / 1e9 < Integer.parseInt(args[3])) {
                String acquired = MpvSourceNative.acquire(handle);
                if (acquired != null && !acquired.isEmpty()) {
                    JSONObject ticket = new JSONObject(acquired);
                    MpvSourceNative.release(handle, ticket.getLong("producer_token")); tickets++;
                }
                double elapsed = (System.nanoTime() - start) / 1e9;
                if (elapsed - lastSnapshot >= .5) {
                    JSONObject status = new JSONObject(MpvSourceNative.status(handle));
                    JSONObject details = status.optJSONObject("details");
                    JSONObject snapshot = new JSONObject().put("seconds", elapsed).put("tickets", tickets).put("images", drained.get()).put("source", status);
                    if (upstreamConnections != null) snapshot.put("upstream_connection_attempts", upstreamConnections.get());
                    if (server != null) {
                        Object readCache = call(server, "interleaveCacheStats", url);
                        if (readCache instanceof java.util.Map) snapshot.put("read_cache", new JSONObject((java.util.Map) readCache));
                    }
                    snapshots.put(snapshot); lastSnapshot = elapsed;
                    synchronized (upstreamRanges) { report.put("upstream_ranges", new JSONArray(upstreamRanges.toString())); }
                    if (firstFrame < 0 && (drained.get() > 0 || tickets > 0)) firstFrame = elapsed;
                    if (status.optBoolean("network_interleave_suspect") && !policyChecked && !sequential) {
                        policyChecked = true;
                        Class<?> function = appLoader.loadClass("kotlin.jvm.functions.Function0");
                        Object cancelled = Proxy.newProxyInstance(function.getClassLoader(), new Class<?>[]{function}, (proxy, method, values) -> false);
                        Object policy = singleton("Mp4InterleavePolicy");
                        long probeStart = System.nanoTime();
                        Object decision = call(policy, "inspectHttp", url, cancelled);
                        sequential = (Boolean) call(decision, "getSequential");
                        report.put("sequential", sequential).put("leading_audio_bytes", call(decision, "getLeadingAudioBytes"))
                            .put("policy_diagnostic", call(decision, "getDiagnostic")).put("metadata_probe_ms", (System.nanoTime() - probeStart) / 1e6);
                        if (sequential) {
                            report.put("interleave_failure_observed", status); readPolicyRestarts++;
                            close(handle); handle = 0;
                            int position = details == null ? initialPosition : (int) Math.max(initialPosition, details.optDouble("position_seconds", 0) * 1000);
                            handle = create(context, url, ca, layer ? images.getSurface() : null, true, position);
                            firstFrame = -1; tickets = 0; drained.set(0);
                        } else {
                            if ((Boolean) call(decision, "getRegionCache") && server != null)
                                report.put("region_cache_enabled", call(server, "enableInterleaveCache", url, call(decision, "getAudioChunks")));
                            MpvSourceNative.setPlaying(handle, true);
                        }
                    }
                    if (layer && !status.optBoolean("layer_compatible", true)) {
                        if (fallbackCount++ != 0) throw new Exception("Repeated layer fallback");
                        report.put("layer_failure_observed", status);
                        close(handle); handle = 0; layer = false;
                        handle = create(context, url, ca, null, sequential, initialPosition);
                    }
                    if (status.optString("state").equals("failed")) throw new Exception("Native playback failed");
                    System.out.println("MEDIA_COMPAT " + args[2] + " t=" + elapsed + " frames=" + (drained.get() + tickets) + " position=" + (details == null ? "" : details.optString("position_seconds")) + " sequential=" + sequential + " fallback=" + fallbackCount);
                    if (controls && firstFrame >= 0 && (!args[2].startsWith("mp4-") || sequential)) {
                        double played = elapsed - firstFrame;
                        if (!seekForward && played >= 2) {
                            if (far && details != null)
                                forwardTarget = (int) Math.max(10000, Math.min(1200000,
                                    details.optDouble("duration_seconds", 1220) * 1000 - 20000));
                            forwardFrames = drained.get() + tickets;
                            seekForward = MpvSourceNative.seek(handle, far ? forwardTarget : 8000, true);
                        }
                        if (far && details != null && seekForward && forwardReady < 0 && details.optDouble("position_seconds") >= forwardTarget / 1000.0 - 1 &&
                            status.optLong("last_source_epoch") >= status.optLong("epoch_floor") &&
                            !details.optString("paused_for_cache").equals("yes") && drained.get() + tickets > forwardFrames) forwardReady = elapsed;
                        if (!seekBack && (far ? forwardReady >= 0 && elapsed - forwardReady >= 2 : played >= 4)) {
                            backFrames = drained.get() + tickets;
                            seekBack = MpvSourceNative.seek(handle, far ? 10000 : 2000, false);
                        }
                        if (far && details != null && seekBack && backReady < 0 && details.optDouble("position_seconds") >= 9 && details.optDouble("position_seconds") < 20 &&
                            status.optLong("last_source_epoch") >= status.optLong("epoch_floor") &&
                            !details.optString("paused_for_cache").equals("yes") && drained.get() + tickets > backFrames) backReady = elapsed;
                        if (!audioOff && (far ? backReady >= 0 && elapsed - backReady >= 2 : played >= 6)) { MpvSourceNative.setAudio(handle, 0, 0, true); audioOff = true; }
                        if (!audioOn && (far ? backReady >= 0 && elapsed - backReady >= 3 : played >= 7)) { MpvSourceNative.setAudio(handle, -1, 0, true); audioOn = true; }
                    }
                    report.put("stage", "running");
                    try (FileWriter writer = new FileWriter(output)) { writer.write(report.toString()); }
                }
                Thread.sleep(10);
            }
            if (firstFrame < 0 || drained.get() + tickets == 0)
                throw new IllegalStateException("No decoded output before probe deadline");
            if (controls && !(seekForward && seekBack && audioOff && audioOn && (!far || forwardReady >= 0 && backReady >= 0)))
                throw new IllegalStateException("Playback controls did not recover decoded output");
            report.put("stage", "complete").put("fallback_count", fallbackCount).put("first_frame_seconds", firstFrame)
                .put("read_policy_restarts", readPolicyRestarts)
                .put("initial_position_ms", initialPosition).put("far_forward_verified", forwardReady >= 0).put("far_back_verified", backReady >= 0)
                .put("tickets", tickets).put("images_drained", drained.get()).put("controls_exercised", seekForward && seekBack && audioOff && audioOn);
            if (upstreamConnections != null) report.put("upstream_connection_attempts", upstreamConnections.get());
        } catch (Throwable error) {
            Throwable cause = error instanceof InvocationTargetException ? ((InvocationTargetException) error).getCause() : error;
            report.put("stage", "failed").put("error_type", cause.getClass().getName())
                .put("error_message", String.valueOf(cause.getMessage()).replaceAll("https?://[^\\s]+", "<url>"));
            System.out.println("MEDIA_COMPAT_ERROR " + report.optString("error_type") + " " + report.optString("error_message"));
        } finally {
            if (handle != 0) { close(handle); report.put("closed", true); }
            if (server != null) call(server, "close");
            if (images != null) images.close(); if (drain != null) drain.quitSafely();
            if (display != null) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                if (surface != null) EGL14.eglDestroySurface(display, surface);
                if (gl != null) EGL14.eglDestroyContext(display, gl);
                EGL14.eglTerminate(display);
            }
            try (FileWriter writer = new FileWriter(output)) { writer.write(report.toString()); }
        }
        System.exit(report.optString("stage").equals("complete") ? 0 : 1);
    }
}

/** JNI ABI mirror, compiled with the probe so it never loads an older APK's create signature. */
class MpvSourceNative {
    static native long create(Context context, String path, int position, boolean hardware, boolean audio, int width,
        String[] audioFiles, String[] subtitleFiles, boolean exact, Surface surface, boolean softwareLayer, int layerWidth,
        int layerHeight, boolean iso, String ca, boolean sequential);
    static native String status(long handle);
    static native String acquire(long handle);
    static native boolean release(long handle, long token);
    static native void setPlaying(long handle, boolean playing);
    static native boolean setAudio(long handle, int track, double volume, boolean mute);
    static native boolean seek(long handle, long position, boolean exact);
    static native void requestClose(long handle);
    static native boolean close(long handle, boolean abandon);
}
