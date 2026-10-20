/* Appended to client.c. No allocation or disk access on the audio callback. */
static pthread_rwlock_t quest_capture_gate = PTHREAD_RWLOCK_INITIALIZER;
static quest_capture_video_fn quest_capture_video;
static quest_capture_audio_fn quest_capture_audio;
static void *quest_capture_opaque;

MPV_EXPORT uint32_t mpv_quest_capture_api_version(void) { return QUEST_MPV_CAPTURE_API_VERSION; }
MPV_EXPORT uint64_t mpv_quest_capture_owner(mpv_handle *ctx)
{
    static _Atomic uint64_t serial = 1;
    if (!ctx) return 0;
    uint64_t value = atomic_load(&ctx->mpctx->global->quest_capture_id);
    if (!value) {
        uint64_t next = atomic_fetch_add(&serial, 1);
        if (atomic_compare_exchange_strong(&ctx->mpctx->global->quest_capture_id, &value, next))
            value = next;
    }
    return value;
}
MPV_EXPORT void mpv_quest_capture_observe(quest_capture_video_fn video,
                                        quest_capture_audio_fn audio, void *opaque)
{
    pthread_rwlock_wrlock(&quest_capture_gate);
    quest_capture_video = video;
    quest_capture_audio = audio;
    quest_capture_opaque = opaque;
    pthread_rwlock_unlock(&quest_capture_gate);
}
void mpv_quest_capture_video_feed(uint64_t owner, int stream,
    const struct AVCodecParameters *codec, const struct AVPacket *packet)
{
    if (pthread_rwlock_tryrdlock(&quest_capture_gate)) return;
    if (quest_capture_video) quest_capture_video(quest_capture_opaque, owner, stream, codec, packet);
    pthread_rwlock_unlock(&quest_capture_gate);
}
void mpv_quest_capture_audio_feed(uint64_t owner, const void *data, int frames,
                                 int rate, int channels, int format, int64_t frame, int64_t ns)
{
    if (pthread_rwlock_tryrdlock(&quest_capture_gate)) return;
    if (quest_capture_audio) quest_capture_audio(quest_capture_opaque, owner, data, frames, rate, channels, format, frame, ns);
    pthread_rwlock_unlock(&quest_capture_gate);
}
