#include <jni.h>
#include <mpv/client.h>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <string>
#include "live/live_capture.h"

void quest_mpv_initialize_android(JNIEnv*, jobject);
namespace {
// Each handle belongs to exactly one Java worker; it never shares the video player.
struct Audio {
    mpv_handle* core = nullptr;
    bool loaded = false, ended = false, failed = false;
    uint64_t capture_owner = 0;
    double duration = 0, position = 0;
    ~Audio() { quest::live::source_closing(capture_owner); if (core) mpv_terminate_destroy(core); quest::live::source_close(capture_owner); }
};
void check(int value) { if (value < 0) throw std::runtime_error("Audio decoder unavailable"); }
double number(mpv_handle* core, const char* key, double fallback = 0) {
    double result = fallback;
    if (mpv_get_property(core, key, MPV_FORMAT_DOUBLE, &result) < 0 || !std::isfinite(result)) return fallback;
    return result;
}
std::string quoted_property(mpv_handle* core, const char* key) {
    char* raw = mpv_get_property_string(core, key);
    std::string value = "\"";
    if (raw) for (const unsigned char c : std::string(raw)) {
        if (c == '"' || c == '\\') value += '\\';
        if (c >= 32) value += static_cast<char>(c);
    }
    mpv_free(raw); return value + '"';
}
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_BackgroundAudioNative_open(JNIEnv* env, jclass, jobject context, jstring path, jboolean probe, jstring tls_ca_file) {
    try {
        quest_mpv_initialize_android(env, context);
        auto audio = std::make_unique<Audio>(); audio->core = mpv_create();
        if (!audio->core || !path) return 0;
        auto option = [&](const char* name, const char* value) { check(mpv_set_option_string(audio->core, name, value)); };
        option("config", "no"); option("load-scripts", "no"); option("terminal", "no");
        option("vid", "no"); option("sid", "no"); option("audio-display", "no");
        option("audio-channels", "stereo"); option("audio-spdif", "");
        option("ao", probe ? "null" : "aaudio"); option("volume", "0");
        option("pause", "yes"); option("idle", "yes"); option("keep-open", "no");
        option("cache", "no"); option("demuxer-max-bytes", "4MiB");
        option("demuxer-readahead-secs", "1"); option("ytdl", "no");
        option("network-timeout", "10"); option("tls-verify", "yes");
        if (tls_ca_file) {
            const char* ca = env->GetStringUTFChars(tls_ca_file, nullptr);
            if (!ca) return 0;
            const std::string ca_path(ca); env->ReleaseStringUTFChars(tls_ca_file, ca);
            if (!ca_path.empty()) option("tls-ca-file", ca_path.c_str());
        }
        check(mpv_initialize(audio->core));
        audio->capture_owner = quest::live::source_open(audio->core);
        const char* raw = env->GetStringUTFChars(path, nullptr);
        if (!raw) return 0;
        std::string source(raw); env->ReleaseStringUTFChars(path, raw);
        const char* command[] = {"loadfile", source.c_str(), nullptr};
        check(mpv_command(audio->core, command));
        return reinterpret_cast<jlong>(audio.release());
    } catch (...) { return 0; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_BackgroundAudioNative_status(JNIEnv* env, jclass, jlong handle) {
    auto* audio = reinterpret_cast<Audio*>(handle);
    if (!audio) return env->NewStringUTF("{\"state\":\"failed\"}");
    for (int i = 0; i < 64; ++i) {
        const auto* event = mpv_wait_event(audio->core, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        // AUDIO_RECONFIG confirms decoded audio, rather than accepting a file extension.
        if (event->event_id == MPV_EVENT_AUDIO_RECONFIG && number(audio->core, "audio-params/samplerate") > 0) audio->loaded = true;
        if (event->event_id == MPV_EVENT_END_FILE) {
            const auto* end = static_cast<const mpv_event_end_file*>(event->data);
            audio->ended = end->reason == MPV_END_FILE_REASON_EOF;
            audio->failed = !audio->ended || !audio->loaded || end->error < 0;
        }
    }
    audio->duration = number(audio->core, "duration", audio->duration);
    audio->position = number(audio->core, "time-pos", audio->position);
    int seekable = 0;
    mpv_get_property(audio->core, "seekable", MPV_FORMAT_FLAG, &seekable);
    const auto state = audio->failed ? "failed" : audio->ended ? "ended" : audio->loaded ? "ready" : "loading";
    std::string json = "{\"state\":\"" + std::string(state) + "\",\"position\":" + std::to_string(audio->position) +
        ",\"duration\":" + std::to_string(audio->duration) + ",\"seekable\":" + (seekable ? "true" : "false") + ",\"codec\":" + quoted_property(audio->core, "audio-codec-name") +
        ",\"channels\":" + quoted_property(audio->core, "audio-out-params/channels") +
        ",\"sample_rate\":" + std::to_string(number(audio->core, "audio-params/samplerate")) + "}";
    return env->NewStringUTF(json.c_str());
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_BackgroundAudioNative_control(JNIEnv*, jclass, jlong handle, jboolean playing, jdouble volume, jdouble seek) {
    auto* audio = reinterpret_cast<Audio*>(handle);
    if (!audio || !std::isfinite(volume) || volume < 0 || volume > 100 || !std::isfinite(seek)) return false;
    try {
        check(mpv_set_property(audio->core, "volume", MPV_FORMAT_DOUBLE, &volume));
        if (seek >= 0) {
            const auto position = std::to_string(seek);
            const char* command[] = {"seek", position.c_str(), "absolute+exact", nullptr};
            check(mpv_command(audio->core, command)); audio->position = seek;
        }
        int pause = playing ? 0 : 1; check(mpv_set_property(audio->core, "pause", MPV_FORMAT_FLAG, &pause));
        return true;
    } catch (...) { return false; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_BackgroundAudioNative_close(JNIEnv*, jclass, jlong handle) {
    delete reinterpret_cast<Audio*>(handle);
}
