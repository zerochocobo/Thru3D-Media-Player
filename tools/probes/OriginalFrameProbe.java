import android.graphics.Bitmap;
import android.media.MediaMetadataRetriever;
import java.io.FileOutputStream;
import java.lang.reflect.InvocationTargetException;

/** Run with app_process under the Debug application's uid and APK class path.
 * Exercises the packaged JNI fallback against an explicitly supplied synthetic fixture.
 * No playback, settings, history, MediaStore or account access. */
public final class OriginalFrameProbe {
    public static void main(String[] args) throws Exception {
        try {
            // app_process has no Application by default; current Android's fd conversion needs one.
            android.os.Looper.prepareMainLooper();
            Class<?> threadType = Class.forName("android.app.ActivityThread");
            Object thread = threadType.getMethod("systemMain").invoke(null);
            android.content.Context context = (android.content.Context) threadType.getMethod("getSystemContext").invoke(thread);
            context = context.createPackageContext("com.wapok.thru3d", android.content.Context.CONTEXT_IGNORE_SECURITY);
            android.app.Application application = new android.app.Application();
            java.lang.reflect.Method attach = android.content.ContextWrapper.class.getDeclaredMethod("attachBaseContext", android.content.Context.class);
            attach.setAccessible(true); attach.invoke(application, context);
            java.lang.reflect.Field initial = threadType.getDeclaredField("mInitialApplication");
            initial.setAccessible(true); initial.set(thread, application);
            run(args);
        } catch (Throwable failure) {
            failure.printStackTrace(System.err);
            System.exit(1);
        }
    }
    private static void run(String[] args) throws Exception {
        if (args.length == 5 && args[3].equals("compose-benchmark")) {
            System.load(args[4]);
            MediaMetadataRetriever retriever = new MediaMetadataRetriever();
            Bitmap bitmap = null;
            try {
                retriever.setDataSource(args[0]);
                MediaMetadataRetriever.BitmapParams params = new MediaMetadataRetriever.BitmapParams();
                params.setPreferredConfig(Bitmap.Config.ARGB_8888);
                bitmap = android.os.Build.VERSION.SDK_INT >= 30 ?
                    retriever.getFrameAtTime(Long.parseLong(args[1]), MediaMetadataRetriever.OPTION_CLOSEST_SYNC, params) :
                    retriever.getFrameAtTime(Long.parseLong(args[1]), MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
                if (bitmap == null) throw new IllegalStateException("No keyframe");
                float[] window = {50,0,0, 0,50,0, 0,0,50, 0,0,1.5f,
                    -.0315f,0,1.5f, .0315f,0,1.5f, .7f,.42f, .025f,.04f,
                    0,0,-1, 1,0,0, 0,1,0, .3f,.18f, 0,-1,1};
                long start = System.nanoTime();
                boolean saved = (Boolean)Class.forName("org.vrpassthroughplayer.plugin.PipScreenshotNative")
                    .getDeclaredMethod("compose", Bitmap.class, Bitmap[].class, String.class, int[].class,
                        float[].class, java.util.function.BooleanSupplier.class)
                    .invoke(null, bitmap, new Bitmap[0], args[2], new int[]{1,1,0,0,0,180}, window,
                        (java.util.function.BooleanSupplier)() -> false);
                if (!saved) throw new IllegalStateException("Composition failed");
                System.out.println("{\"state\":\"saved\",\"width\":" + bitmap.getWidth() + ",\"height\":" + bitmap.getHeight() +
                    ",\"elapsed_ms\":" + (System.nanoTime()-start)/1000000 + ",\"bytes\":" + new java.io.File(args[2]).length() + "}");
            } finally { if (bitmap != null) bitmap.recycle(); retriever.release(); }
            return;
        }
        if (args.length == 4 && (args[3].equals("encode-benchmark") || args[3].equals("encode-jpeg-benchmark"))) {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND);
            long start = System.nanoTime();
            MediaMetadataRetriever retriever = new MediaMetadataRetriever();
            Bitmap bitmap = null;
            try {
                retriever.setDataSource(args[0]);
                long ready = System.nanoTime();
                MediaMetadataRetriever.BitmapParams params = new MediaMetadataRetriever.BitmapParams();
                params.setPreferredConfig(Bitmap.Config.ARGB_8888);
                bitmap = android.os.Build.VERSION.SDK_INT >= 30 ?
                    retriever.getFrameAtTime(Long.parseLong(args[1]), MediaMetadataRetriever.OPTION_CLOSEST_SYNC, params) :
                    retriever.getFrameAtTime(Long.parseLong(args[1]), MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
                long decoded = System.nanoTime();
                if (bitmap == null) throw new IllegalStateException("No keyframe");
                System.out.println("{\"stage\":\"frame\",\"setup_ms\":" + (ready-start)/1000000 +
                    ",\"decode_ms\":" + (decoded-ready)/1000000 + ",\"width\":" + bitmap.getWidth() + ",\"height\":" + bitmap.getHeight() + "}");
                boolean jpegOnly = args[3].equals("encode-jpeg-benchmark");
                int[] qualities = jpegOnly ? new int[]{95, 98, 100} : new int[]{100, 95, 90, 100};
                for (int i = 0; i < qualities.length; ++i) {
                    boolean png = !jpegOnly && (i == 0 || i == 3);
                    java.io.File file = new java.io.File(args[2] + (png ? ".png" : "-" + qualities[i] + ".jpg"));
                    long encodeStart = System.nanoTime();
                    try (FileOutputStream output = new FileOutputStream(file)) {
                        if (!bitmap.compress(png ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG, qualities[i], output))
                            throw new IllegalStateException("Encode failed");
                    }
                    System.out.println("{\"stage\":\"encode\",\"format\":\"" + (png ? "png" : "jpeg") + "\",\"quality\":" + qualities[i] +
                        ",\"elapsed_ms\":" + (System.nanoTime()-encodeStart)/1000000 + ",\"bytes\":" + file.length() + "}");
                }
            } finally { if (bitmap != null) bitmap.recycle(); retriever.release(); }
            return;
        }
        if (args.length == 4 && args[3].startsWith("system")) {
            MediaMetadataRetriever retriever = new MediaMetadataRetriever();
            try {
                retriever.setDataSource(args[0]);
                int[] options = args[3].equals("system-pair") ?
                    new int[]{MediaMetadataRetriever.OPTION_CLOSEST, MediaMetadataRetriever.OPTION_CLOSEST_SYNC} :
                    new int[]{args[3].equals("system-sync") ? MediaMetadataRetriever.OPTION_CLOSEST_SYNC : MediaMetadataRetriever.OPTION_CLOSEST};
                for (int option : options) {
                    long start = System.nanoTime();
                    MediaMetadataRetriever.BitmapParams params = new MediaMetadataRetriever.BitmapParams();
                    params.setPreferredConfig(Bitmap.Config.ARGB_8888);
                    Bitmap bitmap = android.os.Build.VERSION.SDK_INT >= 30 ?
                        retriever.getFrameAtTime(Long.parseLong(args[1]), option, params) :
                        retriever.getFrameAtTime(Long.parseLong(args[1]), option);
                    System.out.println("{\"state\":\"" + (bitmap == null ? "empty" : "saved") + "\",\"width\":" +
                        (bitmap == null ? 0 : bitmap.getWidth()) + ",\"height\":" + (bitmap == null ? 0 : bitmap.getHeight()) +
                        ",\"option\":" + option + ",\"elapsed_ms\":" + (System.nanoTime() - start) / 1000000 + "}");
                    if (bitmap != null) {
                        try (FileOutputStream output = new FileOutputStream(args[2])) {
                            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) throw new IllegalStateException("PNG failed");
                        } finally { bitmap.recycle(); }
                    }
                }
            } finally { retriever.release(); }
            return;
        }
        if (args.length < 3) throw new IllegalArgumentException("fixture, position_us, output PNG required");
        if (args.length == 4) System.load(args[3]);
        Class<?> nativeType = Class.forName("org.vrpassthroughplayer.plugin.OriginalClipNative");
        int id = 700001;
        nativeType.getDeclaredMethod("prepare", int.class).invoke(null, id);
        Bitmap bitmap = null;
        long start = System.nanoTime();
        try {
            bitmap = (Bitmap) nativeType.getDeclaredMethod("frame", int.class, String.class, long.class, String.class)
                .invoke(null, id, args[0], Long.parseLong(args[1]), "");
            if (bitmap == null) throw new IllegalStateException("No source frame");
            try (FileOutputStream output = new FileOutputStream(args[2])) {
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) throw new IllegalStateException("PNG failed");
            }
            System.out.println("{\"state\":\"saved\",\"width\":" + bitmap.getWidth() + ",\"height\":" + bitmap.getHeight()
                + ",\"elapsed_ms\":" + (System.nanoTime() - start) / 1000000 + "}");
        } catch (InvocationTargetException error) {
            throw new IllegalStateException(error.getCause().getClass().getSimpleName());
        } finally {
            if (bitmap != null) bitmap.recycle();
            nativeType.getDeclaredMethod("forget", int.class).invoke(null, id);
        }
    }
}
