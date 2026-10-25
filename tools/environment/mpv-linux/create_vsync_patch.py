"""Generate 0006-mpv-layer-cadence.patch for vo_mediacodec_embed.c.

Compositor-layer playback lets MediaCodec render straight into the OpenXR surface swapchain, and
the compositor shows the newest buffer at each latch. mpv released each frame at its audio-clock
target, so with 59.94 fps on a 120 Hz panel the release time slowly drifts across a latch; near it,
about a millisecond of wake-up jitter flips frames between one and three refreshes (Quest 3: a
~1 s burst of ~24 uneven frames every ~11 s, docs/DISPLAY_PIPELINE.md).

The host now reports one predicted display time, the refresh period and the compositor's latch
lead. Each frame is assigned the latch slot after the previous one by round(target delta /
period), kept while it stays within half a period around the frame's natural slot, and released
half a period before that latch, so jitter of up to a quarter frame no longer changes the slot.
The rate difference then shows as a single repeated frame per drift cycle. The VO wakes 20 ms
early to make that possible; without fresh cadence data it waits for the original target.
"""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
NAME = 'video/out/vo_mediacodec_embed.c'
BASE_SHA256 = '4da09e0d69ee52b7e25429f4006e88e6db4273696f195ec67491ddb305f096ea'


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def edit(text):
    def rep(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise ValueError('Unexpected vo_mediacodec_embed.c layout: ' + old.splitlines()[0])
        text = text.replace(old, new)
    rep('''#include <libavcodec/mediacodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_mediacodec.h>

#include "common/common.h"
#include "vo.h"
#include "video/mp_image.h"
#include "video/hwdec.h"

struct priv {
    struct mp_image *next_image;
    struct mp_hwdec_ctx hwctx;
};
''', '''#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

#include <libavcodec/mediacodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_mediacodec.h>

#include "mpv/client.h"
#include "common/common.h"
#include "osdep/timer.h"
#include "vo.h"
#include "video/mp_image.h"
#include "video/hwdec.h"

// Quest compositor cadence (Thru3D patch 0006). The compositor shows the surface's newest buffer
// at each latch; releasing near a latch lets wake-up jitter flip frames between one and three
// refreshes. The host reports a predicted display time (CLOCK_MONOTONIC ns), the refresh period
// and the latch lead; releases then land half a period before a stable latch slot.
#define QUEST_MPV_VSYNC_API_VERSION 1
#define QUEST_VSYNC_WAKE_EARLY MP_TIME_MS_TO_NS(20)
#define QUEST_VSYNC_STALE MP_TIME_S_TO_NS(2)
static _Atomic int64_t quest_vsync_display;
static _Atomic int64_t quest_vsync_lead;
static _Atomic int64_t quest_vsync_period;
static _Atomic int64_t quest_vsync_updated;
// Locked releases, slot resyncs, late releases, releases without cadence data.
static _Atomic int64_t quest_vsync_stats[4];

static int64_t quest_monotonic_ns(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
}

MPV_EXPORT uint32_t mpv_quest_vsync_api_version(void) { return QUEST_MPV_VSYNC_API_VERSION; }

MPV_EXPORT void mpv_quest_vsync_update(int64_t display_ns, int64_t period_ns, int64_t lead_ns)
{
    bool valid = display_ns > 0 && period_ns >= MP_TIME_MS_TO_NS(5) && period_ns <= MP_TIME_MS_TO_NS(34) &&
                 lead_ns >= 0 && lead_ns < MP_TIME_MS_TO_NS(100);
    // Period last and first: a reader never pairs a new period with no display time.
    atomic_store(&quest_vsync_period, 0);
    atomic_store(&quest_vsync_display, display_ns);
    atomic_store(&quest_vsync_lead, lead_ns);
    atomic_store(&quest_vsync_updated, quest_monotonic_ns());
    atomic_store(&quest_vsync_period, valid ? period_ns : 0);
}

MPV_EXPORT void mpv_quest_vsync_stats(int64_t out[4])
{
    for (int i = 0; i < 4; i++)
        out[i] = atomic_load(&quest_vsync_stats[i]);
}

struct priv {
    struct mp_image *next_image;
    struct mp_hwdec_ctx hwctx;
    int64_t next_target;  // CLOCK_MONOTONIC time mpv wants next_image shown, 0 if unknown
    int64_t last_target;
    int64_t last_latch;   // latch the previous release aimed at
    int64_t last_period;
};
''')
    rep('''    hwdec_devices_add(vo->hwdec_devs, &p->hwctx);
    return 0;
}
''', '''    hwdec_devices_add(vo->hwdec_devs, &p->hwctx);
    return 0;
}

static void quest_sleep_until(int64_t when)
{
    struct timespec until = { .tv_sec = when / INT64_C(1000000000), .tv_nsec = when % INT64_C(1000000000) };
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, NULL) == EINTR) {}
}

// Monotonic time to release the next image. Without fresh cadence data: the frame's own target.
static int64_t quest_release_time(struct priv *p, int64_t now)
{
    int64_t target = p->next_target;
    int64_t period = atomic_load(&quest_vsync_period);
    int64_t display = atomic_load(&quest_vsync_display);
    int64_t lead = atomic_load(&quest_vsync_lead);
    int64_t age = now - atomic_load(&quest_vsync_updated);
    if (target <= 0 || period <= 0 || age < 0 || age > QUEST_VSYNC_STALE || llabs(target - now) > MP_TIME_S_TO_NS(1)) {
        p->last_latch = 0;
        atomic_fetch_add(&quest_vsync_stats[3], 1);
        return target > 0 ? target : now;
    }
    int64_t grid = display - lead;
    // The first latch at or after the target: where an unaligned release would land.
    int64_t natural = grid + (int64_t)ceil((double)(target - grid) / period) * period;
    int64_t latch = natural;
    if (p->last_latch > 0 && p->last_period == period) {
        int64_t step = llround((double)(target - p->last_target) / period);
        // Keep the slot pattern while the frame stays within half a period of its natural slot.
        int64_t locked = p->last_latch + step * period;
        locked = grid + llround((double)(locked - grid) / period) * period;
        int64_t drift = locked - target;
        if (step >= 1 && step <= 16 && drift >= -period / 2 && drift < period + period / 2)
            latch = locked;
        else
            atomic_fetch_add(&quest_vsync_stats[1], 1);
    }
    p->last_latch = latch;
    p->last_period = period;
    atomic_fetch_add(&quest_vsync_stats[0], 1);
    return latch - period / 2;
}
''')
    rep('''    AVMediaCodecBuffer *buffer = (AVMediaCodecBuffer *)p->next_image->planes[3];
    av_mediacodec_release_buffer(buffer, 1);
    mp_image_unrefp(&p->next_image);
}
''', '''    int64_t now = quest_monotonic_ns();
    int64_t release = quest_release_time(p, now);
    if (release > now + QUEST_VSYNC_WAKE_EARLY + MP_TIME_MS_TO_NS(20))
        release = now + QUEST_VSYNC_WAKE_EARLY + MP_TIME_MS_TO_NS(20);
    if (release > now)
        quest_sleep_until(release);
    else if (p->last_latch > 0 && now > release + MP_TIME_MS_TO_NS(1))
        atomic_fetch_add(&quest_vsync_stats[2], 1);
    p->last_target = p->next_target;

    AVMediaCodecBuffer *buffer = (AVMediaCodecBuffer *)p->next_image->planes[3];
    av_mediacodec_release_buffer(buffer, 1);
    mp_image_unrefp(&p->next_image);
}
''')
    rep('''    mp_image_t *mpi = NULL;
    if (!frame->redraw && !frame->repeat)
        mpi = mp_image_new_ref(frame->current);

    talloc_free(p->next_image);
    p->next_image = mpi;
''', '''    mp_image_t *mpi = NULL;
    if (!frame->redraw && !frame->repeat)
        mpi = mp_image_new_ref(frame->current);

    talloc_free(p->next_image);
    p->next_image = mpi;
    // frame->pts is the mp_time_ns() target; convert it to the cadence clock.
    p->next_target = mpi && !frame->display_synced && frame->pts > 0
        ? frame->pts - mp_time_ns() + quest_monotonic_ns() : 0;
''')
    rep('''static int reconfig(struct vo *vo, struct mp_image_params *params)
{
    return 0;
}
''', '''static int reconfig(struct vo *vo, struct mp_image_params *params)
{
    // Wake early; flip_page holds each release until its compositor slot (or the original target).
    vo_set_queue_params(vo, QUEST_VSYNC_WAKE_EARLY, 1, 2);
    struct priv *p = vo->priv;
    p->last_latch = 0;
    return 0;
}
''')
    return text


def main():
    if len(sys.argv) != 2: raise SystemExit('Usage: create_vsync_patch.py <pinned-mpv-source>')
    mpv = Path(sys.argv[1])
    source = (mpv/NAME).read_bytes()
    if sha_bytes(source) != BASE_SHA256:
        raise ValueError('vo_mediacodec_embed.c is not the pinned mpv source')
    before = source.decode()
    after = edit(before)
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                         'a/' + NAME, 'b/' + NAME, n=3))
    patch_path = DIRECTORY/'0006-mpv-layer-cadence.patch'
    patch_path.write_text(patch, newline='\n')
    subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=mpv, check=True)
    record = {
        'purpose': 'Release MediaCodec layer frames between compositor latches (59.94 fps on 120 Hz cadence bursts)',
        'base_files_sha256': {NAME: BASE_SHA256},
        'patched_files_sha256': {NAME: sha_bytes(after.encode())},
        'patch_sha256': sha_bytes(patch_path.read_bytes()),
        'api_version': 1,
        'inputs_sha256': {'tools/environment/mpv-linux/create_vsync_patch.py':
                          sha_bytes((ROOT/'tools/environment/mpv-linux/create_vsync_patch.py').read_bytes())},
    }
    (DIRECTORY/'layer-cadence-manifest.json').write_text(json.dumps(record, indent=2) + '\n', newline='\n')
    print('0006 layer cadence patch generated', record['patch_sha256'])


if __name__ == '__main__':
    main()
