package org.vrpassthroughplayer.plugin;

import java.io.File;
import java.nio.file.Files;
import org.json.JSONArray;
import org.json.JSONObject;

/** Real inference with production JNI libraries sharing the APK's one ORT.
 * Runs outside the player, never changes settings or plays synthesized audio.
 */
public final class SharedOnnxProbe {
    private static JSONObject memory() throws Exception {
        JSONObject result = new JSONObject();
        for (String line : Files.readAllLines(new File("/proc/self/status").toPath())) {
            if (line.startsWith("VmRSS:") || line.startsWith("VmHWM:") || line.startsWith("Threads:")) {
                String[] fields = line.trim().split("\\s+");
                result.put(fields[0].replace(":", ""), Long.parseLong(fields[1]));
            }
        }
        return result;
    }
    private static JSONObject vad(String root) throws Exception {
        long job = VoiceCloneNative.createJob();
        final int[] count = {0};
        final boolean[] done = {false};
        try {
            VoiceCloneNative.scan(job, root + "/ja.mkv", 0, "", 0, 4, false, -1, root + "/vad/silero_vad.onnx", (start, probability, rms, peak, finished) -> {
                for (float p : probability) if (!Float.isFinite(p) || p < 0 || p > 1) throw new IllegalStateException("Invalid VAD probability");
                count[0] += probability.length;
                done[0] |= finished;
                return true;
            });
            if (count[0] == 0 || !done[0]) throw new IllegalStateException("VAD scan incomplete");
            return new JSONObject().put("frames", count[0]).put("finished", true);
        } finally { VoiceCloneNative.cancelJob(job); }
    }
    private static JSONObject ocr(String root) throws Exception {
        long engine = ComicOcrNative.create(root + "/comic");
        if (engine <= 0) throw new IllegalStateException("OCR model failed");
        try {
            ComicOcrNative.cancel(engine, 1);
            byte[] rgb = Files.readAllBytes(new File(root, "ocr.rgb").toPath());
            JSONObject result = new JSONObject(new String(ComicOcrNative.analyze(engine, rgb, 640, 320, 1, true), "UTF-8"));
            if (!"ready".equals(result.optString("state")) || result.optInt("detected_count") == 0 || result.optInt("recognition_runs") == 0)
                throw new IllegalStateException("OCR inference failed: " + result);
            return result;
        } finally { ComicOcrNative.destroy(engine); }
    }
    private static JSONObject narration(String root) throws Exception {
        return narration(root, false);
    }
    private static JSONObject narration(String root, boolean recovery) throws Exception {
        long engine = NarrationNative.create(root + "/narration");
        final long[] samples = {0};
        final double[] energy = {0};
        try {
            NarrationNative.cancel(engine, 1);
            NarrationNative.Sink sink = (epoch, pcm) -> {
                for (float value : pcm) {
                    if (!Float.isFinite(value)) throw new IllegalStateException("Nonfinite narration output");
                    energy[0] += (double)value * value;
                }
                samples[0] += pcm.length;
                return true;
            };
            JSONObject result = new JSONObject(recovery
                ? NarrationNative.synthesizePrecisionConfigured(engine, "Hello, welcome.", "Adam", 1, 250, 0, true, sink)
                : NarrationNative.synthesize(engine, "Hello, welcome.", "Adam", 1, sink));
            if (!result.getBoolean("eos") || result.getBoolean("cancelled") || samples[0] <= 0 || energy[0] <= 0)
                throw new IllegalStateException("Narration inference failed: " + result);
            if (recovery && !result.getBoolean("precision_model_loaded")) throw new IllegalStateException("Precision model was not exercised");
            return result.put("samples", samples[0]);
        } finally { NarrationNative.destroy(engine); }
    }
    public static void main(String[] args) throws Exception {
        String root = args[0];
        JSONObject report = new JSONObject();
        report.put("initial_memory", memory());
        boolean baseline = args.length > 1 && args[1].equals("baseline");
        boolean asrFirst = args.length > 1 && args[1].equals("asr-first");
        // Exercise the existing consumer before and after Moonshine in one process.
        System.load(root + "/libquest_narration.so");
        if (!asrFirst) {
            report.put("narration_before", narration(root));
            report.put("narration_repeat", narration(root));
        }
        Files.write(new File(root, "progress.json").toPath(), report.toString(2).getBytes("UTF-8"));
        if (!baseline) System.load(root + "/libquest_listening.so");
        JSONArray languages = new JSONArray();
        for (String language : baseline ? new String[]{} : new String[]{"zh", "en", "ja"}) {
            long begin = System.nanoTime();
            long engine = ListeningNative.create(root + "/listening/" + language, language);
            JSONObject loadedMemory = memory();
            if (engine <= 0) throw new IllegalStateException("Listening model failed: " + language);
            JSONArray events = new JSONArray();
            try {
                ListeningNative.open(engine, root + "/" + language + ".mkv", 0, "", 0, false, -1);
                boolean eof = false;
                int cueCount = 0;
                double through = 0;
                for (int step = 0; step < 180 && !eof; ++step) {
                    JSONObject result = new JSONObject(ListeningNative.step(engine));
                    double end = result.getDouble("through");
                    if (end < through || end > through + 1.01) throw new IllegalStateException("Invalid media clock");
                    through = end;
                    JSONArray cues = result.getJSONArray("cues");
                    for (int i = 0; i < cues.length(); ++i) {
                        JSONObject cue = cues.getJSONObject(i);
                        if (cue.getString("text").trim().isEmpty() || cue.getDouble("start") < 0 || cue.getDouble("end") > through + .01)
                            throw new IllegalStateException("Invalid recognized cue");
                        ++cueCount;
                    }
                    events.put(result);
                    eof = result.optBoolean("eof");
                }
                if (!eof || cueCount == 0) throw new IllegalStateException("No complete recognition: " + language);
                if (language.equals("ja")) {
                    report.put("narration_with_asr", narration(root));
                    report.put("ocr_with_asr", ocr(root));
                    report.put("vad_with_asr", vad(root));
                }
                ListeningNative.cancel(engine);
                boolean cancelled = false;
                try { ListeningNative.step(engine); } catch (RuntimeException expected) { cancelled = true; }
                if (!cancelled) throw new IllegalStateException("Listening cancellation failed");
                languages.put(new JSONObject().put("language", language).put("seconds", (System.nanoTime()-begin)/1e9)
                    .put("events", events).put("cancelled", true).put("loaded_memory", loadedMemory));
            } finally { ListeningNative.destroy(engine); }
            report.put("memory_after_" + language, memory());
        }
        report.put("listening", languages);
        Files.write(new File(root, "progress.json").toPath(), report.toString(2).getBytes("UTF-8"));
        report.put("comic", ocr(root));
        report.put("vad_after", vad(root));
        Files.write(new File(root, "progress.json").toPath(), report.toString(2).getBytes("UTF-8"));
        report.put("narration_after", narration(root));
        report.put("narration_precision", narration(root, true));
        report.put("final_memory", memory());
        report.put("passed", true).put("scope", "Standalone production JNI shared-ORT inference; not player UI/timing quality");
        Files.write(new File(root, "result.json").toPath(), report.toString(2).getBytes("UTF-8"));
        System.out.println(baseline ? "Baseline: narration twice, OCR and narration again passed." : "Shared ONNX: narration, three ASR languages, OCR and narration again passed.");
    }
}
