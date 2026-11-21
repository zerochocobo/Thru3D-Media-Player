// Independent packet-copy JNI. The same core runs in the host integration fixture.
#include "original_clip_core.h"
#include "embedded_cover_core.h"
#ifndef THRU3D_CAPTURE_HOST
#include "video_thumbnail_core.h"
#include <android/bitmap.h>
#include <android/sharedmem.h>
#include <jni.h>
#include <mutex>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unordered_map>
#include <unistd.h>
namespace {
std::mutex jobs_mutex;
std::unordered_map<int, std::shared_ptr<quest::capture::Control>> jobs;
std::string text(JNIEnv* env, jstring value) {
    if (!value) return "";
    const char* chars=env->GetStringUTFChars(value,nullptr);
    if (!chars) throw std::runtime_error("Capture source unavailable");
    std::string result(chars); env->ReleaseStringUTFChars(value,chars); return result;
}
jobject render_bitmap(JNIEnv* env, const AVFrame& decoded, int width, int height) {
    const auto type = env->FindClass("android/graphics/Bitmap");
    const auto config_type = env->FindClass("android/graphics/Bitmap$Config");
    if (!type || !config_type || env->ExceptionCheck()) return nullptr;
    const auto config_field = env->GetStaticFieldID(config_type,"ARGB_8888","Landroid/graphics/Bitmap$Config;");
    const auto create = env->GetStaticMethodID(type,"createBitmap","(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
    if (!config_field || !create || env->ExceptionCheck()) return nullptr;
    const auto config = env->GetStaticObjectField(config_type,config_field);
    const auto bitmap = env->CallStaticObjectMethod(type,create,width,height,config);
    if (!bitmap || env->ExceptionCheck()) return nullptr;
    AndroidBitmapInfo info{};
    void* pixels = nullptr;
    if (AndroidBitmap_getInfo(env,bitmap,&info)!=ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888 ||
        AndroidBitmap_lockPixels(env,bitmap,&pixels)!=ANDROID_BITMAP_RESULT_SUCCESS || !pixels)
        throw std::runtime_error("Could not capture source frame");
    try {
        quest::capture::frame_rgba(decoded,static_cast<uint8_t*>(pixels),int(info.stride),width,height);
    } catch (...) {
        AndroidBitmap_unlockPixels(env,bitmap);
        throw;
    }
    AndroidBitmap_unlockPixels(env,bitmap);
    return bitmap;
}
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_version(JNIEnv*,jclass) { return 1; }
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_cancel(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex);
    auto found=jobs.find(id); if (found!=jobs.end()) found->second->cancelled.store(true);
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_prepare(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex); jobs[id]=std::make_shared<quest::capture::Control>();
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_forget(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex); jobs.erase(id);
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_progress(JNIEnv*,jclass,jint id) {
    std::lock_guard<std::mutex> lock(jobs_mutex);
    const auto found = jobs.find(id);
    return found == jobs.end() ? -1 : found->second->progress.load();
}
extern "C" JNIEXPORT jobject JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_frame(JNIEnv* env,jclass,jint id,jstring source,jlong position,jstring ca) {
    try {
        std::shared_ptr<quest::capture::Control> control;
        { std::lock_guard<std::mutex> lock(jobs_mutex); auto found=jobs.find(id); if(found!=jobs.end())control=found->second; }
        if (!control) throw std::runtime_error("Could not capture source frame");
        control->deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
        auto decoded = quest::capture::source_frame(text(env,source),position,text(env,ca),*control);
        if (quest::capture::Control::interrupt(control.get())) throw std::runtime_error("Could not capture source frame");
        return render_bitmap(env, *decoded, decoded->width, decoded->height);
    } catch (const std::exception& failure) {
        if (!env->ExceptionCheck()) {
            const char* message = dynamic_cast<const std::bad_alloc*>(&failure) ||
                std::string(failure.what())=="Full resolution capture unavailable" ?
                "Full resolution capture unavailable" : "Could not capture source frame";
            const auto type=env->FindClass("java/lang/IllegalStateException");
            if(type)env->ThrowNew(type,message);
        }
        return nullptr;
    }
}
extern "C" JNIEXPORT jobject JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_thumbnail(
    JNIEnv* env, jclass, jobject input, jlong size, jint byte_limit, jlong max_pixels, jboolean seekable) {
    try {
        const auto type = env->GetObjectClass(input);
        const auto read = env->GetMethodID(type, "readAt", "(J[BI)I");
        const auto cancelled = env->GetMethodID(type, "isCancelled", "()Z");
        const auto decode_cover = env->GetMethodID(type, "decodeCover", "([B)Landroid/graphics/Bitmap;");
        const auto report = env->GetMethodID(type, "report", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
        const auto buffer = env->NewByteArray(quest::capture::ThumbnailInput::block);
        if (!read || !cancelled || !decode_cover || !report || !buffer || env->ExceptionCheck()) return nullptr;
        quest::capture::ThumbnailInput bounded{
            size, byte_limit,
            [&](int64_t offset, uint8_t* bytes, int length) {
                const int count = env->CallIntMethod(input, read, jlong(offset), buffer, jint(length));
                if (env->ExceptionCheck() || count < 0 || count > length) return -1;
                if (count > 0) env->GetByteArrayRegion(buffer, 0, count, reinterpret_cast<jbyte*>(bytes));
                return count;
            },
            [&] { return env->ExceptionCheck() || env->CallBooleanMethod(input, cancelled) == JNI_TRUE; },
            max_pixels, seekable == JNI_TRUE
        };
        const auto note = [&](const char* outcome) {
            if (!env->ExceptionCheck()) {
                env->CallVoidMethod(input, report, env->NewStringUTF(outcome),
                    env->NewStringUTF(bounded.format && bounded.format->iformat ? bounded.format->iformat->name : ""),
                    env->NewStringUTF(bounded.codec_id == AV_CODEC_ID_NONE ? "" : avcodec_get_name(bounded.codec_id)));
            }
        };
        if (!bounded.open() || quest::capture::ThumbnailInput::interrupt(&bounded)) {
            note(std::chrono::steady_clock::now() >= bounded.deadline ? "decode_deadline" : bounded.issue);
            return nullptr;
        }
        const auto embedded = quest::capture::find_embedded_cover(*bounded.format, 512 * 1024);
        if (embedded.data) {
            const auto bytes = env->NewByteArray(embedded.size);
            if (!bytes) return nullptr;
            env->SetByteArrayRegion(bytes, 0, embedded.size, reinterpret_cast<const jbyte*>(embedded.data));
            const auto cover = env->CallObjectMethod(input, decode_cover, bytes);
            if (cover) note("embedded_cover");
            if (cover || env->ExceptionCheck()) return cover;
        }
        const auto picture = quest::capture::thumbnail_frame(bounded);
        if (!picture || quest::capture::ThumbnailInput::interrupt(&bounded)) {
            note(std::chrono::steady_clock::now() >= bounded.deadline ? "decode_deadline" : bounded.issue);
            return nullptr;
        }
        const int edge = std::max(picture->width, picture->height);
        const int width = std::max(1, picture->width * 512 / edge);
        const int height = std::max(1, picture->height * 512 / edge);
        const auto bitmap = render_bitmap(env, *picture, width, height);
        note(bitmap ? "video_frame" : "bitmap_failed");
        return bitmap;
    } catch (...) {
        return nullptr;
    }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_thumbnailImageInput(JNIEnv* env, jclass, jbyteArray bytes) {
    const auto length = env->GetArrayLength(bytes);
    if (length <= 0 || length > 4 * 1024 * 1024) return -1;
    const int fd = ASharedMemory_create("media-library-preview", size_t(length));
    if (fd < 0) return -1;
    struct stat info{};
    // File-only image decoders reopen /proc/self/fd. An ashmem device is not reopenable
    // like a memfd, so Android's buffer decoder handles that case instead.
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size != length) { close(fd); return -1; }
    void* data = mmap(nullptr, size_t(length), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { close(fd); return -1; }
    env->GetByteArrayRegion(bytes, 0, length, static_cast<jbyte*>(data));
    munmap(data, size_t(length));
    if (env->ExceptionCheck()) { close(fd); return -1; }
    return fd;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_cover(JNIEnv* env,jclass,jint id,jstring source,jstring ca) {
    try {
        std::shared_ptr<quest::capture::Control> control;
        {std::lock_guard<std::mutex> lock(jobs_mutex);auto found=jobs.find(id);if(found!=jobs.end())control=found->second;}
        if(!control)return env->NewByteArray(0);
        const auto bytes=quest::capture::embedded_cover(text(env,source),text(env,ca),*control);
        auto result=env->NewByteArray(bytes.size());
        if(result&&!bytes.empty())env->SetByteArrayRegion(result,0,bytes.size(),reinterpret_cast<const jbyte*>(bytes.data()));
        return result;
    }catch(...){return env->NewByteArray(0);}
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_OriginalClipNative_export(JNIEnv* env,jclass,jint id,jstring source,
    jstring output,jlong start,jlong end,jint audio,jstring extra_audio,jstring ca,jstring mode) {
    std::shared_ptr<quest::capture::Control> control;
    { std::lock_guard<std::mutex> lock(jobs_mutex); auto found=jobs.find(id); if (found!=jobs.end()) control=found->second; }
    if (!control) return env->NewStringUTF("{\"state\":\"error\",\"error\":\"Clip export cancelled\"}");
    std::string result;
    try { result=quest::capture::clip(text(env,source),text(env,output),start,end,audio,text(env,extra_audio),text(env,ca),text(env,mode),*control); }
    catch (...) { result="{\"state\":\"error\",\"error\":\"Clip export failed\"}"; }
    return env->NewStringUTF(result.c_str());
}
#else
#include <iostream>
int main(int argc,char** argv) {
    if (argc!=6 && argc!=7) return 2;
    quest::capture::Control control;
    const auto result=quest::capture::clip(argv[1],argv[2],std::stoll(argv[3]),std::stoll(argv[4]),std::stoi(argv[5]),
        argc==7 ? argv[6] : "","","{\"version\":1,\"geometry\":3,\"stereo_sbs\":true}",control);
    std::cout<<result.substr(0,result.size()-1)<<",\"progress\":"<<control.progress.load()<<"}"<<'\n';
    return result.find("\"state\":\"saved\"")==std::string::npos ? 1 : 0;
}
#endif
