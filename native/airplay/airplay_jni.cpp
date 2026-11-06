// Thru3D AirPlay mirror transport. Protocol: pinned UxPlay, GPL-3.0-or-later.
#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <memory>
#include <string>
#include <mutex>
#include <vector>
extern "C" {
#include "raop.h"
#include "logger.h"
#include "pairing.h"
#include "android_dnssd_shim.h"
#include "airplay_profile.h"
}

namespace {
struct Server {
    JavaVM* vm{}; jobject listener{}; jmethodID event{}, packet{};
    raop_t* raop{}; dnssd_t* dns{}; std::atomic<bool> closing{false};
    std::mutex clients_mutex; std::vector<std::string> clients;
};
struct Env {
    JavaVM* vm; JNIEnv* value{}; bool attached{};
    explicit Env(JavaVM* v): vm(v) {
        if (vm->GetEnv(reinterpret_cast<void**>(&value), JNI_VERSION_1_6) == JNI_EDETACHED) {
            attached = vm->AttachCurrentThread(&value, nullptr) == JNI_OK;
        }
    }
    ~Env() { if (value && value->ExceptionCheck()) value->ExceptionClear(); if (attached) vm->DetachCurrentThread(); }
};
void event(Server* s, const char* kind, const std::string& value = "") {
    if (s->closing.load()) return;
    Env env(s->vm); if (!env.value) return;
    auto k = env.value->NewStringUTF(kind); auto v = env.value->NewStringUTF(value.c_str());
    if (k && v) env.value->CallVoidMethod(s->listener, s->event, k, v);
    if (k) env.value->DeleteLocalRef(k); if (v) env.value->DeleteLocalRef(v);
}
void packet(Server* s, bool video, const unsigned char* data, int bytes, uint64_t ns, int codec) {
    if (s->closing.load() || !data || bytes <= 0 || bytes > 4*1024*1024) return;
    Env env(s->vm); if (!env.value) return;
    auto array = env.value->NewByteArray(bytes); if (!array) return;
    env.value->SetByteArrayRegion(array, 0, bytes, reinterpret_cast<const jbyte*>(data));
    env.value->CallVoidMethod(s->listener, s->packet, static_cast<jboolean>(video), array, static_cast<jlong>(ns), codec);
    env.value->DeleteLocalRef(array);
}
void video(void* cls, raop_ntp_t*, video_decode_struct* p) {
    if (p && p->data && p->data_len > 0 && !p->data[0]) packet(static_cast<Server*>(cls), true, p->data, p->data_len, p->ntp_time_local, p->is_h265 ? 265 : 264);
}
void audio(void* cls, raop_ntp_t*, audio_decode_struct* p) {
    if (p) packet(static_cast<Server*>(cls), false, p->data, p->data_len, p->ntp_time_local, p->ct);
}
void running(void* cls, bool on) { event(static_cast<Server*>(cls), on ? "mirror_start" : "mirror_stop", on ? "" : "transport_stopped"); }
void pin(void* cls, char* value) { event(static_cast<Server*>(cls), "pin", value ? value : ""); }
void size(void* cls, float*, float*, float* w, float* h) {
    event(static_cast<Server*>(cls), "size", std::to_string(static_cast<int>(*w)) + "x" + std::to_string(static_cast<int>(*h)));
}
void audioFormat(void* cls, unsigned char* ct, unsigned short* spf, bool*, bool*, uint64_t*) {
    event(static_cast<Server*>(cls), "audio_format", std::to_string(*ct) + ":" + std::to_string(*spf));
}
void volume(void* cls, float db) { event(static_cast<Server*>(cls), "volume", std::to_string(db)); }
void reset(void* cls, int value) { event(static_cast<Server*>(cls), "mirror_stop", "connection_reset_" + std::to_string(value)); }
void nop(void*) {}
void videoReset(void* cls, reset_type_t value) { event(static_cast<Server*>(cls), "mirror_stop", "video_reset_" + std::to_string(static_cast<int>(value))); }
void protocolLog(void*, int level, const char* message) {
    // PINs and pairing material are logged by upstream at INFO/DEBUG, never forward those.
    if (level <= LOGGER_ERR && message) __android_log_write(ANDROID_LOG_ERROR, "Thru3D-Airplay", message);
}
double initialVolume(void*) { return 0.0; }
int codec(void*, video_codec_t c) { return c == VIDEO_CODEC_H264 ? 0 : -1; }
void admit(void*, char*, char*, char*, bool* allowed) { *allowed = true; }
void registered(void* cls, const char*, const char* key, const char*) {
    auto s = static_cast<Server*>(cls); if (!key || strlen(key) > 128) return;
    std::lock_guard<std::mutex> lock(s->clients_mutex);
    if (s->clients.size() < 16) s->clients.emplace_back(key);
}
bool known(void* cls, const char* key) {
    auto s = static_cast<Server*>(cls); if (!key) return false;
    std::lock_guard<std::mutex> lock(s->clients_mutex);
    for (const auto& client: s->clients) if (client == key) return true;
    return false;
}
void destroy(Server* s, JNIEnv* env) {
    if (!s) return;
    s->closing.store(true);
    if (s->raop) { raop_stop_httpd(s->raop); raop_destroy(s->raop); }
    if (s->dns) dnssd_destroy(s->dns);
    if (s->listener) env->DeleteGlobalRef(s->listener);
    delete s;
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_AirplayNative_start(JNIEnv* env, jobject, jobject listener, jstring name, jbyteArray mac, jstring keyfile) {
    if (!listener || !mac || env->GetArrayLength(mac) != 6) return 0;
    auto s = std::make_unique<Server>(); env->GetJavaVM(&s->vm); s->listener = env->NewGlobalRef(listener);
    auto cls = env->GetObjectClass(listener);
    s->event = env->GetMethodID(cls, "event", "(Ljava/lang/String;Ljava/lang/String;)V");
    s->packet = env->GetMethodID(cls, "packet", "(Z[BJI)V"); env->DeleteLocalRef(cls);
    if (!s->event || !s->packet) { if (env->ExceptionCheck()) env->ExceptionClear(); destroy(s.release(), env); return 0; }
    raop_callbacks_t cb{}; cb.cls = s.get(); cb.video_process = video; cb.audio_process = audio;
    cb.video_report_size = size; cb.audio_get_format = audioFormat; cb.mirror_video_running = running;
    cb.conn_init = nop; cb.conn_destroy = nop; cb.conn_reset = reset; cb.video_pause = nop; cb.video_resume = nop;
    cb.conn_feedback = nop; cb.video_reset = videoReset;
    cb.audio_flush = nop; cb.video_flush = nop; cb.audio_stop_coverart_rendering = nop;
    cb.audio_set_volume = volume; cb.audio_set_client_volume = initialVolume;
    cb.display_pin = pin; cb.report_client_request = admit; cb.register_client = registered; cb.check_register = known;
    cb.video_set_codec = codec;
    s->raop = raop_init(&cb);
    if (!s->raop) { destroy(s.release(), env); return 0; }
    // UxPlay asserts on any enabled log message without a callback, including rejected PINs.
    raop_set_log_callback(s->raop, protocolLog, nullptr);
    raop_set_log_level(s->raop, LOGGER_ERR);
    char address[6]; env->GetByteArrayRegion(mac, 0, 6, reinterpret_cast<jbyte*>(address));
    char id[18]; snprintf(id, sizeof(id), "%02X:%02X:%02X:%02X:%02X:%02X", static_cast<unsigned char>(address[0]), static_cast<unsigned char>(address[1]), static_cast<unsigned char>(address[2]), static_cast<unsigned char>(address[3]), static_cast<unsigned char>(address[4]), static_cast<unsigned char>(address[5]));
    auto path = env->GetStringUTFChars(keyfile, nullptr); int result = raop_init2(s->raop, 0, id, path); env->ReleaseStringUTFChars(keyfile, path);
    if (result < 0) { destroy(s.release(), env); return 0; }
    const int code = random_pin();
    if (code < 0) { destroy(s.release(), env); return 0; }
    raop_set_plist(s->raop, "pin", code + 10000);
    auto title = env->GetStringUTFChars(name, nullptr); int dnsError{};
    s->dns = dnssd_init(title, static_cast<int>(strlen(title)), address, 6, &dnsError, 1); env->ReleaseStringUTFChars(name, title);
    if (!s->dns) { destroy(s.release(), env); return 0; }
    airplay_configure_profile(s->raop, s->dns);
    raop_set_dnssd(s->raop, s->dns);
    unsigned short port = 0;
    if (raop_start_httpd(s->raop, &port) < 0) { destroy(s.release(), env); return 0; }
    raop_set_port(s->raop, port); dnssd_register_raop(s->dns, port); dnssd_register_airplay(s->dns, port);
    event(s.get(), "port", std::to_string(port));
    for (int type = 0; type < 2; ++type) {
        const int count = type ? android_dnssd_get_airplay_txt_count(s->dns) : android_dnssd_get_raop_txt_count(s->dns);
        for (int i = 0; i < count; ++i) {
            auto key = type ? android_dnssd_get_airplay_txt_key(s->dns, i) : android_dnssd_get_raop_txt_key(s->dns, i);
            auto value = type ? android_dnssd_get_airplay_txt_val(s->dns, i) : android_dnssd_get_raop_txt_val(s->dns, i);
            event(s.get(), type ? "airplay_txt" : "raop_txt", std::string(key) + "=" + value);
        }
    }
    event(s.get(), "raop_name", android_dnssd_get_raop_servname(s->dns));
    return reinterpret_cast<jlong>(s.release());
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_AirplayNative_stop(JNIEnv* env, jobject, jlong handle) { destroy(reinterpret_cast<Server*>(handle), env); }
