/* Private ABI for bounded, nonblocking observation of data already used by playback. */
#ifndef QUEST_MPV_CAPTURE_H
#define QUEST_MPV_CAPTURE_H
#include <stdint.h>
#include "client.h"
#ifdef __cplusplus
extern "C" {
#endif
#define QUEST_MPV_CAPTURE_API_VERSION 2u
struct AVPacket;
struct AVCodecParameters;
/* Borrowed objects. Callback must only retain packet refs or copy bounded audio;
 * never do I/O, wait, call mpv, decode, synthesize or change the input stream. */
typedef void (*quest_capture_video_fn)(void *, uint64_t, int,
    const struct AVCodecParameters *, const struct AVPacket *);
typedef void (*quest_capture_audio_fn)(void *, uint64_t, const void *, int, int, int, int, int64_t, int64_t);
MPV_EXPORT uint32_t mpv_quest_capture_api_version(void);
MPV_EXPORT uint64_t mpv_quest_capture_owner(mpv_handle *);
/* One observer per process. A replacement waits only for in-flight callbacks. */
MPV_EXPORT void mpv_quest_capture_observe(quest_capture_video_fn, quest_capture_audio_fn, void *);
/* mpv internal callers: packet timestamps use microseconds; PCM is interleaved,
 * format=1 float32, 2 signed16, 3 signed32. Positive frames submit a device-frame
 * range. Zero frames reports an actually presented device frame and monotonic ns;
 * -1 discards queued, unheard data after the device has stopped/flushed;
 * -2 reanchors the presentation clock after a real device underrun. */
void mpv_quest_capture_video_feed(uint64_t, int, const struct AVCodecParameters *, const struct AVPacket *);
void mpv_quest_capture_audio_feed(uint64_t, const void *, int, int, int, int, int64_t, int64_t);
#ifdef __cplusplus
}
#endif
#endif
