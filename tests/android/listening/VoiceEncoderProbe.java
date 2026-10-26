package org.vrpassthroughplayer.plugin;

import java.io.File;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import org.json.JSONObject;

/** Separate process, as in the production :voice_clone service. No saved voice. */
public final class VoiceEncoderProbe {
    public static void main(String[] args) throws Exception {
        String root = args[0];
        System.load(root + "/libquest_narration.so");
        long job = VoiceCloneNative.createJob();
        try {
            VoiceCloneNative.extract(job, root + "/en.mkv", 0, "", 0, 3, root + "/reference.wav", false, -1);
        } finally { VoiceCloneNative.cancelJob(job); }
        VoiceCloneNative.encode(root + "/encoder/moss_audio_tokenizer_encode.onnx", root + "/reference.wav", root + "/reference.codes");
        byte[] raw = Files.readAllBytes(new File(root, "reference.codes").toPath());
        if (!"T3VOICE1".equals(new String(raw, 0, 8, "US-ASCII"))) throw new IllegalStateException("Invalid voice code header");
        ByteBuffer data = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        int frames = data.getInt(8);
        if (frames < 37 || frames > 125 || raw.length != 12 + frames*32) throw new IllegalStateException("Invalid encoded frames");
        data.position(12);
        while (data.hasRemaining()) if ((data.getShort() & 65535) >= 1024) throw new IllegalStateException("Invalid audio code");
        JSONObject report = new JSONObject().put("passed", true).put("frames", frames).put("scope", "Production extraction/encoder JNI in a separate process; no saved voice or service IPC test");
        Files.write(new File(root, "encoder-result.json").toPath(), report.toString(2).getBytes("UTF-8"));
        System.out.println("Separate-process voice encoder passed.");
    }
}
