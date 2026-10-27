/* Seekable Blu-ray MVC ISO demux bridge. LGPL-2.1-or-later. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include <errno.h>
#include <stddef.h>
#include <pthread.h>
#include <libbluray/bluray.h>
#include <libbluray/keys.h>
#include <libbluray/overlay.h>
#include <libbluray/clpi_data.h>
#include <libbluray/filesystem.h>
#include <udfread/udfread.h>
#include <udfread/blockinput.h>
#include "libavutil/avstring.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/stereo3d.h"
#include "libavutil/time.h"
#include "avformat.h"
#include "demux.h"
#include "internal.h"
#include "url.h"

int avformat_thru3d_bd_probe(const char *url, int *width, int *height, int64_t *duration, int *mvc);
int avformat_thru3d_bd_titles(const char *url, int playlist, int *width, int *height, int64_t *duration,
                              int *mvc, int *selected, char *json, int capacity);
int avformat_thru3d_bd_titles_v2(const char *url, int playlist, int *width, int *height, int64_t *duration,
                               int *mvc, int *selected, char *json, int capacity,
                               int (*interrupt)(void *), void *opaque);
int avformat_thru3d_bd_menu_state(char *json, int capacity);
int avformat_thru3d_bd_menu_overlay(uint64_t version, uint8_t *rgba, int capacity, int *rect);
int avformat_thru3d_bd_menu_input(int kind, int x, int y);
/* Pinned libbluray 1.4.1's internal CPI lookup, linked statically in this library. */
uint32_t clpi_lookup_spn(const CLPI_CL *cl, uint32_t timestamp, int before, uint8_t stc_id);
CLPI_CL *thru3d_clpi_from_file(BD_FILE_H *file);

typedef struct PacketNode {
    AVPacket *packet;
    struct PacketNode *next;
} PacketNode;

typedef struct BdMvc BdMvc;
#define SECTOR_CACHE_BLOCKS 32
#define SECTOR_CACHE_SLOTS 128
typedef struct SectorCache {
    int lba;
    int bytes;
    uint8_t data[SECTOR_CACHE_BLOCKS * 2048];
} SectorCache;
typedef struct IsoInput {
    udfread_block_input input;
    BdMvc *owner;
} IsoInput;

typedef struct MvcClip {
    char dependent_id[6];
    int64_t size;
} MvcClip;

/* One CLIPINF listing with each clip's base stream size, read once per title. */
typedef struct MvcCandidate {
    char id[6];
    int64_t size;
} MvcCandidate;

struct BdMvc {
    const AVClass *class;
    int header_only;
    int playlist;
    /* HDMV disc menu session: libbluray navigation, not a seekable title. */
    int menu;
    int menu_probing;
    int menu_started;      /* a menu was reached; data before it is skipped */
    /* While skipping, the current playlist's data is kept so a menu shown inside
       First Play still gets its background picture from the playlist start. */
    uint8_t *replay;
    int replay_size, replay_pos, replay_overflow;
    int menu_called;       /* a menu call was issued from a title First Play started */
    int menu_bdj;          /* navigation reached a BD-J title */
    int menu_restarts;
    int menu_top_reached;
    uint32_t menu_last_still;
    int64_t menu_probe_started;
    int64_t still_until; /* 0: no still; INT64_MAX: until skipped */
    int64_t menu_offset, menu_max_out, menu_epoch_raw;
    unsigned menu_epoch;
    int64_t *menu_last_raw;
    unsigned *menu_stream_epoch;
    BLURAY_TITLE_INFO *menu_title;
    int is_mvc;
    int title_stream;
    int packet_clip;
    int clip_tag_pending;
    MvcClip *mvc_clips;
    MvcCandidate *candidates;
    unsigned candidate_count;
    int candidates_ready;
    int64_t *clip_offsets;
    SectorCache *sector_cache;
    unsigned cache_cursor;
    AVFormatContext *outer, *inner;
    AVIOContext *stream_io;
    BLURAY *disc;
    BLURAY_TITLE_INFO *title;
    udfread *udf;
    IsoInput input;
    UDFFILE *ssif, *base;
    UDFFILE *dependent;
    CLPI_CL *base_index, *dependent_index;
    int64_t size, origin, end;
    int base_pid, dependent_pid, video_stream, width, height;
    int *stream_map;
    unsigned mapped_streams;
    PacketNode *views[2];
    int64_t queued_bytes;
    int64_t first_pair_dts;
    uint64_t paired;
    uint64_t packets;
    uint64_t reads;
};

static int64_t ssif_position(BdMvc *s, UDFFILE *file, int64_t position);
static const BLURAY_CLIP_INFO *reference_clip(const BLURAY_TITLE_INFO *title);
static int map_late_streams(BdMvc *s);
static void menu_close(BdMvc *s);

static int64_t index_seek(BD_FILE_H *file, int64_t offset, int32_t whence)
{
    return udfread_file_seek(file->internal, offset, whence);
}

static int64_t index_tell(BD_FILE_H *file)
{
    return udfread_file_tell(file->internal);
}

static int64_t index_read(BD_FILE_H *file, uint8_t *buffer, int64_t size)
{
    return size < 0 || size > 1024*1024 ? -1 : udfread_file_read(file->internal, buffer, size);
}

static CLPI_CL *read_index(BdMvc *s, const char *name)
{
    UDFFILE *file = udfread_file_open(s->udf, name);
    int64_t size;
    CLPI_CL *index;
    if (!file) return NULL;
    size = udfread_file_size(file);
    if (size <= 0 || size > 1024*1024) { udfread_file_close(file); return NULL; }
    BD_FILE_H reader = {.internal = file, .seek = index_seek, .tell = index_tell, .read = index_read};
    index = thru3d_clpi_from_file(&reader);
    udfread_file_close(file);
    return index;
}

static int disc_blocks(void *opaque, void *buffer, int lba, int blocks)
{
    BdMvc *s = opaque;
    int ret;
    if (ff_check_interrupt(&s->outer->interrupt_callback)) return 0;
    if (lba < 0 || blocks <= 0 || blocks > 8192 ||
        !s->outer->pb)
        return 0;
    /* UDF/playlist scans revisit tiny filesystem sectors. Bound the cache at
       8 MiB so these seeks do not each reconnect to the cloud download stream. */
    int aligned = lba - lba % SECTOR_CACHE_BLOCKS;
    int skip = (lba - aligned) * 2048;
    if (blocks <= SECTOR_CACHE_BLOCKS && skip + blocks * 2048 <= SECTOR_CACHE_BLOCKS * 2048) {
        if (!s->sector_cache) s->sector_cache = av_calloc(SECTOR_CACHE_SLOTS, sizeof(*s->sector_cache));
        if (!s->sector_cache) return 0;
        SectorCache *entry = NULL;
        for (unsigned i = 0; i < SECTOR_CACHE_SLOTS; i++)
            if (s->sector_cache[i].bytes > skip && s->sector_cache[i].lba == aligned) {
                entry = &s->sector_cache[i]; break;
            }
        if (!entry) {
            entry = &s->sector_cache[s->cache_cursor++ % SECTOR_CACHE_SLOTS];
            entry->bytes = 0;
            if (avio_seek(s->outer->pb, (int64_t)aligned * 2048, SEEK_SET) < 0) return 0;
            ret = avio_read(s->outer->pb, entry->data, sizeof(entry->data));
            if (ret <= skip) return 0;
            entry->lba = aligned; entry->bytes = ret;
        }
        int available = FFMIN(blocks, (entry->bytes - skip) / 2048);
        if (available <= 0) return 0;
        memcpy(buffer, entry->data + skip, available * 2048);
        return available;
    }
    if (avio_seek(s->outer->pb, (int64_t)lba * 2048, SEEK_SET) < 0) return 0;
    ret = avio_read(s->outer->pb, buffer, blocks * 2048);
    return ret > 0 ? ret / 2048 : 0;
}

static int udf_blocks(udfread_block_input *input, uint32_t lba, void *buffer, uint32_t blocks, int flags)
{
    IsoInput *source = (IsoInput *)input;
    if (lba > INT_MAX || blocks > INT_MAX)
        return 0;
    return disc_blocks(source->owner, buffer, lba, blocks);
}

static int stream_read(void *opaque, uint8_t *buffer, int size)
{
    BdMvc *s = opaque;
    ssize_t count = s->title_stream ? bd_read(s->disc, buffer, size) : udfread_file_read(s->ssif, buffer, size);
    if (!count && s->is_mvc && udfread_file_tell(s->ssif) < s->size) return AVERROR(EIO);
    if (s->reads++ < 4)
        av_log(s->outer, AV_LOG_VERBOSE, "Blu-ray read %d -> %zd bytes\n", size, count);
    return count < 0 ? AVERROR(EIO) : count ? count : AVERROR_EOF;
}

static int64_t stream_seek(void *opaque, int64_t offset, int whence)
{
    BdMvc *s = opaque;
    if (whence == AVSEEK_SIZE)
        return s->size;
    if (s->title_stream) {
        whence &= ~AVSEEK_FORCE;
        if (whence == SEEK_CUR) offset += bd_tell(s->disc);
        else if (whence == SEEK_END) offset += s->size;
        else if (whence != SEEK_SET) return AVERROR(EINVAL);
        if (offset < 0 || offset > s->size) return AVERROR(EINVAL);
        return bd_seek(s->disc, offset);
    }
    return udfread_file_seek(s->ssif, offset, whence & ~AVSEEK_FORCE);
}

static void clear_views(BdMvc *s)
{
    for (int eye = 0; eye < 2; eye++) {
        while (s->views[eye]) {
            PacketNode *node = s->views[eye];
            s->views[eye] = node->next;
            av_packet_free(&node->packet);
            av_free(node);
        }
    }
    s->queued_bytes = 0;
    s->first_pair_dts = AV_NOPTS_VALUE;
}

static void close_transport(BdMvc *s)
{
    avformat_close_input(&s->inner);
    if (s->stream_io) {
        av_freep(&s->stream_io->buffer);
        avio_context_free(&s->stream_io);
    }
    av_freep(&s->stream_map);
    s->mapped_streams = 0;
}

static void close_clip(BdMvc *s)
{
    if (s->base) udfread_file_close(s->base);
    if (s->dependent) udfread_file_close(s->dependent);
    if (s->base_index) bd_free_clpi(s->base_index);
    if (s->dependent_index) bd_free_clpi(s->dependent_index);
    if (s->ssif) udfread_file_close(s->ssif);
    s->base = s->ssif = s->dependent = NULL;
    s->base_index = s->dependent_index = NULL;
}

static int close_disc(AVFormatContext *context)
{
    BdMvc *s = context->priv_data;
    if (s->menu) menu_close(s);
    clear_views(s);
    close_transport(s);
    close_clip(s);
    if (s->udf) udfread_close(s->udf);
    if (s->title) bd_free_title_info(s->title);
    if (s->disc) bd_close(s->disc);
    s->base = s->ssif = s->dependent = NULL;
    s->base_index = s->dependent_index = NULL;
    s->udf = NULL; s->title = NULL; s->disc = NULL;
    av_freep(&s->stream_map);
    av_freep(&s->clip_offsets);
    av_freep(&s->mvc_clips);
    av_freep(&s->candidates);
    av_freep(&s->sector_cache);
    return 0;
}

static int index_has_pid(CLPI_CL *index, int pid)
{
    if (!index) return 0;
    if (!index->cpi.num_stream_pid && index->cpi_ss.num_stream_pid) {
        index->cpi = index->cpi_ss;
        index->cpi_ss = (CLPI_CPI){0};
    }
    for (unsigned i = 0; i < index->cpi.num_stream_pid; i++)
        if (index->cpi.entry[i].pid == pid) return 1;
    return 0;
}

/* A dependent PID alone is not an association: a disc can contain many MVC
   clips. Match the logical streams to this SSIF's physical allocation first. */
static int dependency_in_ssif(BdMvc *s, UDFFILE *file)
{
    int64_t bytes = udfread_file_size(file);
    if (bytes <= 0 || bytes != s->size - udfread_file_size(s->base)) return 0;
    return ssif_position(s, file, 0) >= 0 && ssif_position(s, file, bytes - 1) >= 0;
}

static int list_candidates(BdMvc *s)
{
    UDFDIR *directory;
    struct udfread_dirent entry;
    unsigned examined = 0;
    char path[128];
    if (s->candidates_ready) return 0;
    directory = udfread_opendir(s->udf, "BDMV/CLIPINF");
    if (!directory) return AVERROR_INVALIDDATA;
    while (udfread_readdir(directory, &entry)) {
        UDFFILE *file;
        MvcCandidate *grown;
        if (++examined > 8192) { udfread_closedir(directory); return AVERROR(ENOSYS); }
        if (strlen(entry.d_name) != 10 || strcmp(entry.d_name + 5, ".clpi")) continue;
        snprintf(path, sizeof(path), "BDMV/STREAM/%.5s.m2ts", entry.d_name);
        file = udfread_file_open(s->udf, path);
        if (!file) continue;
        grown = av_realloc_array(s->candidates, s->candidate_count + 1, sizeof(*grown));
        if (!grown) { udfread_file_close(file); udfread_closedir(directory); return AVERROR(ENOMEM); }
        s->candidates = grown;
        memcpy(grown[s->candidate_count].id, entry.d_name, 5);
        grown[s->candidate_count].id[5] = 0;
        grown[s->candidate_count++].size = udfread_file_size(file);
        udfread_file_close(file);
    }
    udfread_closedir(directory);
    s->candidates_ready = 1;
    return 0;
}

static int select_mvc_clip(BdMvc *s, unsigned number)
{
    BLURAY_CLIP_INFO *clip = &s->title->clips[number];
    MvcClip *known = &s->mvc_clips[number];
    char path[128];
    close_clip(s);
    s->packet_clip = number;
    s->origin = clip->in_time; s->end = clip->out_time;
    snprintf(path, sizeof(path), "BDMV/STREAM/SSIF/%s.ssif", clip->clip_id);
    s->ssif = udfread_file_open(s->udf, path);
    snprintf(path, sizeof(path), "BDMV/STREAM/%s.m2ts", clip->clip_id);
    s->base = udfread_file_open(s->udf, path);
    snprintf(path, sizeof(path), "BDMV/CLIPINF/%s.clpi", clip->clip_id);
    s->base_index = read_index(s, path);
    if (!s->ssif || !s->base || !index_has_pid(s->base_index, s->base_pid))
        return AVERROR_INVALIDDATA;
    s->size = udfread_file_size(s->ssif);
    if (s->size <= 0 || udfread_file_size(s->base) <= 0 || udfread_file_size(s->base) >= s->size ||
        (known->size && known->size != s->size)) return AVERROR_INVALIDDATA;
    if (ssif_position(s, s->base, 0) < 0 ||
        ssif_position(s, s->base, udfread_file_size(s->base) - 1) < 0)
        return AVERROR(ENOSYS);
    if (known->dependent_id[0]) {
        snprintf(path, sizeof(path), "BDMV/STREAM/%s.m2ts", known->dependent_id);
        s->dependent = udfread_file_open(s->udf, path);
        snprintf(path, sizeof(path), "BDMV/CLIPINF/%s.clpi", known->dependent_id);
        s->dependent_index = read_index(s, path);
        if (!s->dependent || !dependency_in_ssif(s, s->dependent) ||
            !index_has_pid(s->dependent_index, s->dependent_pid)) return AVERROR_INVALIDDATA;
    } else {
        int64_t wanted = s->size - udfread_file_size(s->base);
        int ret = list_candidates(s);
        if (ret < 0) return ret;
        /* Size is a cheap filter; physical allocation and PID confirm the pair. */
        for (unsigned i = 0; i < s->candidate_count; i++) {
            MvcCandidate *candidate = &s->candidates[i];
            UDFFILE *file;
            CLPI_CL *index;
            if (candidate->size != wanted || !strncmp(candidate->id, clip->clip_id, 5)) continue;
            snprintf(path, sizeof(path), "BDMV/STREAM/%s.m2ts", candidate->id);
            file = udfread_file_open(s->udf, path);
            if (!file) continue;
            if (!dependency_in_ssif(s, file)) { udfread_file_close(file); continue; }
            snprintf(path, sizeof(path), "BDMV/CLIPINF/%s.clpi", candidate->id);
            index = read_index(s, path);
            if (!index_has_pid(index, s->dependent_pid)) {
                if (index) bd_free_clpi(index);
                udfread_file_close(file); continue;
            }
            if (s->dependent) {
                bd_free_clpi(index); udfread_file_close(file);
                av_log(s->outer, AV_LOG_ERROR, "MVC dependency clip is ambiguous for %.5s\n", clip->clip_id);
                return AVERROR(ENOSYS);
            }
            s->dependent = file; s->dependent_index = index;
            memcpy(known->dependent_id, candidate->id, 5);
        }
        if (!s->dependent) {
            av_log(s->outer, AV_LOG_ERROR, "MVC dependency index not found for %.5s\n", clip->clip_id);
            return AVERROR_INVALIDDATA;
        }
        known->size = s->size;
    }
    s->clip_tag_pending = 1;
    s->first_pair_dts = AV_NOPTS_VALUE;
    av_log(s->outer, AV_LOG_VERBOSE, "MVC clip %u/%u: %.5s + %.5s, start %.6f, duration %.6f\n",
           number + 1, s->title->clip_count, clip->clip_id, known->dependent_id,
           clip->start_time / 90000., (clip->out_time - clip->in_time) / 90000.);
    return 0;
}

static int open_transport(BdMvc *s)
{
    AVDictionary *options = NULL;
    int ret;
    uint8_t *buffer = av_malloc(64 * 1024);
    if (!buffer) return AVERROR(ENOMEM);
    s->stream_io = avio_alloc_context(buffer, 64 * 1024, 0, s, stream_read, NULL, stream_seek);
    if (!s->stream_io) { av_free(buffer); return AVERROR(ENOMEM); }
    s->inner = avformat_alloc_context();
    if (!s->inner) return AVERROR(ENOMEM);
    s->inner->pb = s->stream_io;
    s->inner->flags |= AVFMT_FLAG_CUSTOM_IO;
    if (s->is_mvc) s->inner->flags |= AVFMT_FLAG_NOPARSE | AVFMT_FLAG_NOFILLIN;
    s->inner->interrupt_callback = s->outer->interrupt_callback;
    s->inner->probesize = 32 * 1024 * 1024;
    s->inner->max_analyze_duration = 15000000;
    s->inner->skip_estimate_duration_from_pts = 1;
    s->inner->codec_whitelist = av_strdup(s->is_mvc ? "dca,ac3,eac3,mlp,truehd,pcm_bluray,pgssub" : "h264,hevc,mpeg2video,vc1,dca,ac3,eac3,mlp,truehd,pcm_bluray,pgssub");
    if (s->title_stream) {
        /* Probe where the audio starts, not in a silent leader clip. */
        unsigned first = reference_clip(s->title) - s->title->clips;
        if (first && avio_seek(s->stream_io, s->clip_offsets[first], SEEK_SET) < 0) return AVERROR(EIO);
    }
    av_dict_set(&options, "max_packet_size", "16777216", 0);
    ret = avformat_open_input(&s->inner, NULL, av_find_input_format("mpegts"), &options);
    av_dict_free(&options);
    if (ret < 0) return ret;
    ret = avformat_find_stream_info(s->inner, NULL);
    if (ret < 0) return ret;
    avformat_flush(s->inner);
    return avio_seek(s->stream_io, 0, SEEK_SET) < 0 ? AVERROR(EIO) : 0;
}

static int remap_transport(BdMvc *s)
{
    av_freep(&s->stream_map);
    s->mapped_streams = s->inner->nb_streams;
    s->stream_map = av_malloc_array(s->mapped_streams, sizeof(*s->stream_map));
    if (!s->stream_map) return AVERROR(ENOMEM);
    for (unsigned i = 0; i < s->mapped_streams; i++) {
        AVStream *in = s->inner->streams[i];
        s->stream_map[i] = -1;
        if (in->id == s->dependent_pid) continue;
        for (unsigned j = 0; j < s->outer->nb_streams; j++) {
            AVStream *out = s->outer->streams[j];
            if (out->id != in->id) continue;
            if (out->codecpar->codec_type != in->codecpar->codec_type ||
                (out->codecpar->codec_id != in->codecpar->codec_id && (int)j != s->video_stream))
                return AVERROR_INVALIDDATA;
            s->stream_map[i] = j;
        }
    }
    for (unsigned j = 0; j < s->outer->nb_streams; j++) {
        int found = 0;
        for (unsigned i = 0; i < s->mapped_streams; i++) found |= s->stream_map[i] == (int)j;
        if (!found) return AVERROR_INVALIDDATA;
    }
    return 0;
}

/* A failed switch leaves no reader: later reads fail and a seek reopens the clip,
   instead of using a closed demuxer or a partially filled stream map. */
static int switch_mvc_clip(BdMvc *s, unsigned number)
{
    int ret;
    close_transport(s);
    clear_views(s);
    if ((ret = select_mvc_clip(s, number)) < 0 || (ret = open_transport(s)) < 0 ||
        (ret = remap_transport(s)) < 0) {
        close_transport(s);
        return ret;
    }
    return 0;
}

static const int format_widths[] = {0,720,720,720,1920,1280,1920,720,3840};
static const int format_heights[] = {0,480,576,480,1080,720,1080,576,2160};

/* The clip whose audio/PG layout the title follows: the first with audio.
   Ordinary titles often wrap the feature in second-long silent leader clips. */
static const BLURAY_CLIP_INFO *reference_clip(const BLURAY_TITLE_INFO *title)
{
    for (unsigned i = 0; i < title->clip_count; i++)
        if (title->clips[i].audio_stream_count) return &title->clips[i];
    return &title->clips[0];
}

/* Every clip keeps the reference clip's video/audio layout (and, for MVC, its
   rate and PG streams); ordinary titles may also contain silent clips. Shared
   by playback and the title list, so a listed title passes once selected. */
static int title_layout(const BLURAY_TITLE_INFO *title, int mvc)
{
    const BLURAY_CLIP_INFO *clip;
    const BLURAY_STREAM_INFO *video;
    if (!title || !title->clip_count || title->clip_count > 4096) return AVERROR_INVALIDDATA;
    if (!title->clips[0].video_stream_count || title->clips[0].still_mode != BLURAY_STILL_NONE)
        return AVERROR_INVALIDDATA;
    clip = mvc ? &title->clips[0] : reference_clip(title);
    if (!clip->video_stream_count) return AVERROR_INVALIDDATA;
    video = &clip->video_streams[0];
    if (video->format >= FF_ARRAY_ELEMS(format_widths) || !format_widths[video->format]) return AVERROR(ENOSYS);
    if (mvc && video->format != BLURAY_VIDEO_FORMAT_1080P && video->format != BLURAY_VIDEO_FORMAT_720P)
        return AVERROR(ENOSYS);
    for (unsigned i = 0; i < title->clip_count; i++) {
        const BLURAY_CLIP_INFO *part = &title->clips[i];
        if (!part->video_stream_count || part->still_mode != BLURAY_STILL_NONE ||
            part->out_time <= part->in_time ||
            part->video_streams[0].pid != video->pid ||
            part->video_streams[0].coding_type != video->coding_type ||
            part->video_streams[0].format != video->format ||
            (part->audio_stream_count != clip->audio_stream_count && (mvc || part->audio_stream_count)))
            return AVERROR(ENOSYS);
        for (unsigned a = 0; a < part->audio_stream_count; a++)
            if (part->audio_streams[a].pid != clip->audio_streams[a].pid ||
                part->audio_streams[a].coding_type != clip->audio_streams[a].coding_type)
                return AVERROR(ENOSYS);
        if (mvc) {
            if (part->video_streams[0].rate != video->rate || part->pg_stream_count != clip->pg_stream_count)
                return AVERROR(ENOSYS);
            for (unsigned a = 0; a < part->audio_stream_count; a++)
                if (part->audio_streams[a].format != clip->audio_streams[a].format ||
                    part->audio_streams[a].rate != clip->audio_streams[a].rate) return AVERROR(ENOSYS);
            for (unsigned a = 0; a < part->pg_stream_count; a++)
                if (part->pg_streams[a].pid != clip->pg_streams[a].pid ||
                    part->pg_streams[a].coding_type != clip->pg_streams[a].coding_type) return AVERROR(ENOSYS);
        }
    }
    return 0;
}

static int title_is_mvc(BdMvc *s, const BLURAY_TITLE_INFO *title)
{
    char path[128];
    UDFFILE *file;
    snprintf(path, sizeof(path), "BDMV/STREAM/SSIF/%s.ssif", title->clips[0].clip_id);
    file = udfread_file_open(s->udf, path);
    if (file) udfread_file_close(file);
    return file != NULL;
}

/* ---- HDMV disc menu session --------------------------------------------
   One menu session at a time. The application polls the state and the
   interactive-graphics plane and sends pointer/key input from another thread.
   Lock order: menu_input_lock -> libbluray's own lock -> menu_data_lock. */
#define MENU_PLANE_MAX (1920 * 1080)
static pthread_mutex_t menu_input_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t menu_data_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    BdMvc *owner;
    int width, height;          /* IG plane size */
    uint32_t *plane, *shown;    /* drawing plane and the last flushed copy */
    int x0, y0, x1, y1;         /* shown plane's occupied bounds, x1/y1 exclusive */
    uint64_t version;
    int title, playlist, chapter, menu, popup, seen, ended, error, unsupported;
    int64_t chapter_ms;
    /* The disc's own audio/subtitle choice (stream numbers, subtitle display flag) as
       the chosen stream's position among the playlist's streams of that type in PID
       order, which is the transport stream's and so the title demuxer's track order:
       -1 unknown, and for subtitles -2 off. */
    int audio_stream, pg_stream, pg_shown, audio_index, pg_index;
} menu_shared;

static int pid_ordinal(const BLURAY_STREAM_INFO *streams, int count, int number)
{
    int rank = 0;
    if (number < 1 || number > count) return -1;
    for (int i = 0; i < count; i++) rank += streams[i].pid < streams[number - 1].pid;
    return rank;
}

static void menu_update_pids_locked(const BLURAY_TITLE_INFO *title)
{
    const BLURAY_CLIP_INFO *clip = title && title->clip_count ? reference_clip(title) : NULL;
    menu_shared.audio_index = clip ? pid_ordinal(clip->audio_streams, clip->audio_stream_count, menu_shared.audio_stream) : -1;
    menu_shared.pg_index = !menu_shared.pg_shown ? -2 :
        clip ? pid_ordinal(clip->pg_streams, clip->pg_stream_count, menu_shared.pg_stream) : -1;
}

static void menu_publish_locked(void)
{
    int x0 = menu_shared.width, y0 = menu_shared.height, x1 = 0, y1 = 0;
    if (menu_shared.plane && menu_shared.shown) {
        memcpy(menu_shared.shown, menu_shared.plane, (size_t)menu_shared.width * menu_shared.height * 4);
        for (int y = 0; y < menu_shared.height; y++) {
            const uint32_t *row = menu_shared.shown + (size_t)y * menu_shared.width;
            for (int x = 0; x < menu_shared.width; x++)
                if (row[x] >> 24) {
                    if (x < x0) x0 = x;
                    if (x >= x1) x1 = x + 1;
                    if (y < y0) y0 = y;
                    y1 = y + 1;
                }
        }
    }
    if (x1 <= x0) x0 = y0 = x1 = y1 = 0;
    else menu_shared.seen = 1;
    menu_shared.x0 = x0; menu_shared.y0 = y0; menu_shared.x1 = x1; menu_shared.y1 = y1;
    menu_shared.version++;
}

static void menu_planes_free_locked(void)
{
    av_freep(&menu_shared.plane);
    av_freep(&menu_shared.shown);
    menu_shared.width = menu_shared.height = 0;
}

/* Limited-range YCbCr palette entry to straight ARGB (BT.709 for HD planes). */
static uint32_t menu_color(const BD_PG_PALETTE_ENTRY *entry, int hd)
{
    int y = (entry->Y - 16) * 298, cb = entry->Cb - 128, cr = entry->Cr - 128;
    int r = hd ? (y + 459 * cr + 128) >> 8 : (y + 409 * cr + 128) >> 8;
    int g = hd ? (y - 55 * cb - 136 * cr + 128) >> 8 : (y - 100 * cb - 208 * cr + 128) >> 8;
    int b = hd ? (y + 541 * cb + 128) >> 8 : (y + 516 * cb + 128) >> 8;
    return (uint32_t)entry->T << 24 | (uint32_t)av_clip_uint8(r) << 16 | (uint32_t)av_clip_uint8(g) << 8 | av_clip_uint8(b);
}

static void menu_clear_locked(int x, int y, int w, int h)
{
    for (int row = FFMAX(0, y); row < FFMIN(menu_shared.height, y + h); row++) {
        int from = FFMAX(0, x), to = FFMIN(menu_shared.width, x + w);
        if (to > from) memset(menu_shared.plane + (size_t)row * menu_shared.width + from, 0, (size_t)(to - from) * 4);
    }
}

/* HDMV interactive graphics arrive as palette RLE objects; PG is ignored here. */
static void menu_overlay(void *handle, const BD_OVERLAY *const overlay)
{
    pthread_mutex_lock(&menu_data_lock);
    if (handle != menu_shared.owner || !overlay || overlay->plane != BD_OVERLAY_IG) goto done;
    switch (overlay->cmd) {
    case BD_OVERLAY_INIT:
        menu_planes_free_locked();
        if (overlay->w && overlay->h && (int)overlay->w * overlay->h <= MENU_PLANE_MAX) {
            menu_shared.plane = av_calloc((size_t)overlay->w * overlay->h, 4);
            menu_shared.shown = av_calloc((size_t)overlay->w * overlay->h, 4);
            if (menu_shared.plane && menu_shared.shown) {
                menu_shared.width = overlay->w; menu_shared.height = overlay->h;
            } else menu_planes_free_locked();
        }
        menu_publish_locked();
        break;
    case BD_OVERLAY_CLOSE:
        menu_planes_free_locked();
        menu_publish_locked();
        break;
    case BD_OVERLAY_CLEAR:
        if (menu_shared.plane) menu_clear_locked(0, 0, menu_shared.width, menu_shared.height);
        break;
    case BD_OVERLAY_WIPE:
        if (menu_shared.plane) menu_clear_locked(overlay->x, overlay->y, overlay->w, overlay->h);
        break;
    case BD_OVERLAY_HIDE:
        if (menu_shared.plane) menu_clear_locked(0, 0, menu_shared.width, menu_shared.height);
        menu_publish_locked();
        break;
    case BD_OVERLAY_DRAW: {
        uint32_t colors[256];
        const BD_PG_RLE_ELEM *run = overlay->img;
        if (!menu_shared.plane || !run || !overlay->palette) break;
        for (int i = 0; i < 256; i++) colors[i] = menu_color(&overlay->palette[i], menu_shared.height >= 720);
        /* Each row is a run list ended by a zero-length run. */
        for (int y = 0; y < overlay->h; y++) {
            int x = 0, row = overlay->y + y;
            uint32_t *line = row < menu_shared.height ? menu_shared.plane + (size_t)row * menu_shared.width : NULL;
            for (; run->len; run++) {
                for (int i = 0; i < run->len && x < overlay->w; i++, x++)
                    if (line && overlay->x + x < menu_shared.width) line[overlay->x + x] = colors[run->color & 255];
            }
            run++; /* end of line */
        }
        break;
    }
    case BD_OVERLAY_FLUSH:
        menu_publish_locked();
        break;
    }
done:
    pthread_mutex_unlock(&menu_data_lock);
}

static void menu_event(BdMvc *s, const BD_EVENT *event)
{
    BLURAY_TITLE_INFO *info = NULL;
    if (event->event != BD_EVENT_STILL_TIME || !s->still_until)
        av_log(s->outer, AV_LOG_VERBOSE, "Disc menu event %u param %u\n", event->event, event->param);
    if (event->event == BD_EVENT_PLAYLIST) info = bd_get_playlist_info(s->disc, event->param, 0);
    pthread_mutex_lock(&menu_data_lock);
    switch (event->event) {
    /* A BD-J title cannot run here: return to the HDMV top menu instead of failing. */
    case BD_EVENT_ERROR: if (event->param == BD_ERROR_BDJ) s->menu_bdj = 1; else menu_shared.error = 1; break;
    case BD_EVENT_ENCRYPTED: menu_shared.error = 1; break;
    case BD_EVENT_TITLE:
        menu_shared.title = event->param;
        if (event->param == BLURAY_TITLE_TOP_MENU) s->menu_top_reached = 1;
        break;
    case BD_EVENT_PLAYLIST:
        menu_shared.playlist = event->param; menu_shared.chapter = 0; menu_shared.chapter_ms = 0;
        if (!s->menu_started) { s->replay_size = s->replay_pos = 0; s->replay_overflow = 0; }
        if (menu_shared.title == BLURAY_TITLE_TOP_MENU) s->menu_started = 1;
        if (s->menu_title) bd_free_title_info(s->menu_title);
        s->menu_title = info; info = NULL;
        menu_update_pids_locked(s->menu_title);
        break;
    case BD_EVENT_AUDIO_STREAM:
        menu_shared.audio_stream = event->param == 0xff ? 0 : event->param;
        menu_update_pids_locked(s->menu_title);
        break;
    case BD_EVENT_PG_TEXTST_STREAM:
        menu_shared.pg_stream = event->param == 0xfff ? 0 : event->param;
        menu_update_pids_locked(s->menu_title);
        break;
    case BD_EVENT_PG_TEXTST:
        menu_shared.pg_shown = event->param;
        menu_update_pids_locked(s->menu_title);
        break;
    case BD_EVENT_CHAPTER:
        menu_shared.chapter = event->param;
        menu_shared.chapter_ms = s->menu_title && event->param >= 1 && event->param <= s->menu_title->chapter_count ?
            s->menu_title->chapters[event->param - 1].start / 90 : 0;
        break;
    case BD_EVENT_MENU: menu_shared.menu = event->param; if (event->param) menu_shared.seen = 1; break;
    case BD_EVENT_POPUP: menu_shared.popup = event->param; break;
    case BD_EVENT_END_OF_TITLE: break;
    case BD_EVENT_STILL: if (!event->param) s->still_until = 0; break;
    case BD_EVENT_STILL_TIME:
        if (s->still_until && event->param == s->menu_last_still) break; /* repeated while still */
        s->menu_last_still = event->param;
        s->still_until = event->param ? av_gettime_relative() + (int64_t)event->param * 1000000 : INT64_MAX;
        break;
    }
    pthread_mutex_unlock(&menu_data_lock);
    if (info) bd_free_title_info(info);
}

#define MENU_REPLAY_MAX (48 * 1024 * 1024)
static void replay_append(BdMvc *s, const uint8_t *data, int count)
{
    uint8_t *grown;
    if (count <= 0 || s->replay_overflow) return;
    if (s->replay_size + count > MENU_REPLAY_MAX || !(grown = av_realloc(s->replay, s->replay_size + count))) {
        s->replay_overflow = 1; s->replay_size = 0; av_freep(&s->replay);
        return;
    }
    memcpy(grown + s->replay_size, data, count);
    s->replay = grown; s->replay_size += count;
}

/* Navigation data. A still menu has no data: block (interruptibly) until the
   viewer acts, except while probing, where it ends the probe instead. */
static int menu_read(void *opaque, uint8_t *buffer, int size)
{
    BdMvc *s = opaque;
    for (;;) {
        BD_EVENT event;
        int count;
        if (ff_check_interrupt(&s->outer->interrupt_callback)) return AVERROR_EXIT;
        if (s->menu_started && s->replay_pos < s->replay_size) {
            count = FFMIN(size, s->replay_size - s->replay_pos);
            memcpy(buffer, s->replay + s->replay_pos, count);
            if ((s->replay_pos += count) == s->replay_size) { av_freep(&s->replay); s->replay_size = s->replay_pos = 0; }
            return count;
        }
        while (bd_get_event(s->disc, &event)) menu_event(s, &event);
        count = bd_read_ext(s->disc, buffer, size, &event);
        if (event.event != BD_EVENT_NONE) menu_event(s, &event);
        while (bd_get_event(s->disc, &event)) menu_event(s, &event);
        if (s->menu_bdj) {
            /* A failed BD-J title leaves libbluray with no title. From a working
               menu or from First Play, restart and call the top menu; a top menu
               that itself needs BD-J cannot be shown. */
            s->menu_bdj = 0;
            if ((s->menu_top_reached && !s->menu_started) || ++s->menu_restarts > 3 || !bd_play(s->disc)) {
                av_log(s->outer, AV_LOG_WARNING, "Disc menu requires BD-J\n");
                return AVERROR(ENOSYS);
            }
            /* First Play may mask the menu call; the viewer asked for the menu. */
            bd_set_player_setting(s->disc, BLURAY_PLAYER_SETTING_UO_RESTRICTION_LEVEL, BLURAY_PLAYER_SETTING_UO_RESTRICTION_DISABLED);
            bd_menu_call(s->disc, -1);
            bd_set_player_setting(s->disc, BLURAY_PLAYER_SETTING_UO_RESTRICTION_LEVEL, BLURAY_PLAYER_SETTING_UO_RESTRICTION_RELAXED);
            continue;
        }
        if (count < 0) return AVERROR(EIO);
        if (!s->menu_started) replay_append(s, buffer, count);
        if (!s->menu_started && (menu_shared.menu || menu_shared.x1 > menu_shared.x0)) {
            /* First Play shows its own interactive screen: start at that playlist's beginning. */
            s->menu_started = 1;
            s->menu_probe_started = av_gettime_relative();
            s->replay_pos = 0;
            continue;
        }
        if (!s->menu_started) {
            if (menu_shared.title >= 1 && menu_shared.title != BLURAY_TITLE_FIRST_PLAY && !s->menu_called) {
                /* First Play started a title instead of the menu: call the menu from it. */
                s->menu_called = 1;
                bd_menu_call(s->disc, -1);
                continue;
            } else if (av_gettime_relative() - s->menu_probe_started > 60000000) return AVERROR(ENOSYS);
            if (!s->menu_started) {
                if (s->still_until) bd_read_skip_still(s->disc);
                continue;
            }
            s->menu_probe_started = av_gettime_relative();
        }
        if (count > 0) return count;
        if (menu_shared.error) return AVERROR(EIO);
        if (s->still_until && s->still_until != INT64_MAX && av_gettime_relative() >= s->still_until) {
            s->still_until = 0;
            bd_read_skip_still(s->disc);
            continue;
        }
        if (s->menu_probing && (s->still_until || av_gettime_relative() - s->menu_probe_started > 15000000))
            return AVERROR_EOF;
        if (event.event == BD_EVENT_NONE || s->still_until) av_usleep(20000);
    }
}

static int menu_header(AVFormatContext *context, const BLURAY_DISC_INFO *info)
{
    BdMvc *s = context->priv_data;
    AVDictionary *options = NULL;
    uint8_t *buffer;
    int ret;
    if (!info->top_menu_supported || !info->top_menu || info->top_menu->bdj || s->header_only)
        return AVERROR(ENOSYS);
    pthread_mutex_lock(&menu_input_lock);
    pthread_mutex_lock(&menu_data_lock);
    if (menu_shared.owner) ret = AVERROR(EBUSY);
    else {
        memset(&menu_shared, 0, sizeof(menu_shared));
        menu_shared.owner = s; menu_shared.title = -1; menu_shared.playlist = -1;
        menu_shared.audio_index = menu_shared.pg_index = -1;
        ret = 0;
    }
    pthread_mutex_unlock(&menu_data_lock);
    pthread_mutex_unlock(&menu_input_lock);
    if (ret < 0) return ret;
    bd_register_overlay_proc(s->disc, s, menu_overlay);
    if (!bd_play(s->disc)) return AVERROR_INVALIDDATA;
    /* First Play runs normally (top menus may depend on its registers), but its
       logos are not shown: the stream starts at the top menu, whose codec can differ. */
    if (!(buffer = av_malloc(64 * 1024))) return AVERROR(ENOMEM);
    s->stream_io = avio_alloc_context(buffer, 64 * 1024, 0, s, menu_read, NULL, NULL);
    if (!s->stream_io) { av_free(buffer); return AVERROR(ENOMEM); }
    s->stream_io->seekable = 0;
    if (!(s->inner = avformat_alloc_context())) return AVERROR(ENOMEM);
    s->inner->pb = s->stream_io;
    s->inner->flags |= AVFMT_FLAG_CUSTOM_IO;
    s->inner->interrupt_callback = s->outer->interrupt_callback;
    s->inner->probesize = 8 * 1024 * 1024;
    s->inner->max_analyze_duration = 5000000;
    s->inner->skip_estimate_duration_from_pts = 1;
    s->inner->codec_whitelist = av_strdup("h264,hevc,mpeg2video,vc1,dca,ac3,eac3,mlp,truehd,pcm_bluray");
    av_dict_set(&options, "max_packet_size", "16777216", 0);
    s->menu_probing = 1; s->menu_probe_started = av_gettime_relative();
    ret = avformat_open_input(&s->inner, NULL, av_find_input_format("mpegts"), &options);
    av_dict_free(&options);
    if (ret >= 0) ret = avformat_find_stream_info(s->inner, NULL);
    s->menu_probing = 0;
    if (ret < 0) return ret;
    /* A probe ended by a still frame is not the end of the menu. */
    s->stream_io->eof_reached = 0;
    s->mapped_streams = s->inner->nb_streams;
    s->stream_map = av_malloc_array(FFMAX(1, s->mapped_streams), sizeof(*s->stream_map));
    if (!s->stream_map) return AVERROR(ENOMEM);
    s->video_stream = -1;
    for (unsigned i = 0; i < s->mapped_streams; i++) {
        AVStream *in = s->inner->streams[i], *out;
        enum AVMediaType type = in->codecpar->codec_type;
        s->stream_map[i] = -1;
        if ((type != AVMEDIA_TYPE_VIDEO || s->video_stream >= 0) && (type != AVMEDIA_TYPE_AUDIO || in->codecpar->codec_id == AV_CODEC_ID_NONE))
            continue;
        if (!(out = avformat_new_stream(context, NULL))) return AVERROR(ENOMEM);
        s->stream_map[i] = out->index;
        out->id = in->id;
        avpriv_set_pts_info(out, 33, 1, 90000);
        if ((ret = avcodec_parameters_copy(out->codecpar, in->codecpar)) < 0) return ret;
        out->start_time = 0;
        if (type == AVMEDIA_TYPE_VIDEO) { s->video_stream = out->index; out->disposition |= AV_DISPOSITION_DEFAULT; }
    }
    if (s->video_stream < 0) return AVERROR_INVALIDDATA;
    s->menu_last_raw = av_malloc_array(context->nb_streams, sizeof(*s->menu_last_raw));
    s->menu_stream_epoch = av_calloc(context->nb_streams, sizeof(*s->menu_stream_epoch));
    if (!s->menu_last_raw || !s->menu_stream_epoch) return AVERROR(ENOMEM);
    for (unsigned i = 0; i < context->nb_streams; i++) s->menu_last_raw[i] = AV_NOPTS_VALUE;
    s->menu_max_out = -3754;
    context->ctx_flags |= AVFMTCTX_UNSEEKABLE;
    context->duration = AV_NOPTS_VALUE;
    context->start_time = 0;
    av_dict_set(&context->metadata, "thru3d_disc_menu", "1", 0);
    av_log(context, AV_LOG_INFO, "HDMV disc menu session with %u streams\n", context->nb_streams);
    return 0;
}

/* Menus loop clips and jump between playlists: keep one increasing timeline.
   A jump on one stream starts an epoch the others adopt when they jump too. */
static int menu_packet(AVFormatContext *context, AVPacket *output)
{
    BdMvc *s = context->priv_data;
    for (;;) {
        int ret = av_read_frame(s->inner, output), mapped;
        int64_t raw;
        if (ret < 0) return ret;
        if ((unsigned)output->stream_index >= s->mapped_streams && (ret = map_late_streams(s)) < 0) {
            av_packet_unref(output); return ret;
        }
        mapped = (unsigned)output->stream_index < s->mapped_streams ? s->stream_map[output->stream_index] : -1;
        if (mapped >= 0 && s->inner->streams[output->stream_index]->codecpar->codec_id != context->streams[mapped]->codecpar->codec_id) {
            pthread_mutex_lock(&menu_data_lock); menu_shared.unsupported = 1; pthread_mutex_unlock(&menu_data_lock);
            mapped = -1;
        }
        raw = output->dts != AV_NOPTS_VALUE ? output->dts : output->pts;
        if (mapped < 0 || raw == AV_NOPTS_VALUE) { av_packet_unref(output); continue; }
        int64_t last = s->menu_last_raw[mapped];
        if (last == AV_NOPTS_VALUE || raw < last - 45000 || raw > last + 900000) {
            if (s->menu_epoch && s->menu_stream_epoch[mapped] < s->menu_epoch && llabs(raw - s->menu_epoch_raw) < 900000) {
                s->menu_stream_epoch[mapped] = s->menu_epoch;
            } else {
                s->menu_offset = s->menu_max_out + 3754 - raw;
                s->menu_epoch_raw = raw;
                s->menu_stream_epoch[mapped] = ++s->menu_epoch;
            }
        }
        s->menu_last_raw[mapped] = raw;
        if (output->pts != AV_NOPTS_VALUE) output->pts += s->menu_offset;
        if (output->dts != AV_NOPTS_VALUE) output->dts += s->menu_offset;
        s->menu_max_out = FFMAX(s->menu_max_out, raw + s->menu_offset);
        output->stream_index = mapped;
        output->pos = -1;
        return 0;
    }
}

static void menu_close(BdMvc *s)
{
    pthread_mutex_lock(&menu_input_lock);
    pthread_mutex_lock(&menu_data_lock);
    if (menu_shared.owner == s) {
        menu_planes_free_locked();
        menu_shared.owner = NULL;
        menu_shared.version++;
    }
    pthread_mutex_unlock(&menu_data_lock);
    pthread_mutex_unlock(&menu_input_lock);
    if (s->menu_title) bd_free_title_info(s->menu_title);
    s->menu_title = NULL;
    av_freep(&s->replay);
    av_freep(&s->menu_last_raw);
    av_freep(&s->menu_stream_epoch);
}

/* Private application API for the playing menu session. */
int avformat_thru3d_bd_menu_state(char *json, int capacity)
{
    int written;
    pthread_mutex_lock(&menu_data_lock);
    if (!menu_shared.owner)
        written = snprintf(json, capacity, "{\"active\":false}");
    else
        written = snprintf(json, capacity, "{\"active\":true,\"version\":%"PRIu64",\"width\":%d,\"height\":%d,"
            "\"title\":%d,\"playlist\":%d,\"chapter\":%d,\"chapter_ms\":%"PRId64",\"menu\":%s,\"popup\":%s,"
            "\"seen\":%s,\"error\":%s,\"unsupported\":%s,\"buttons\":%s,\"audio_index\":%d,\"subtitle_index\":%d}",
            menu_shared.version, menu_shared.width, menu_shared.height, menu_shared.title, menu_shared.playlist,
            menu_shared.chapter, menu_shared.chapter_ms, menu_shared.menu ? "true" : "false",
            menu_shared.popup ? "true" : "false", menu_shared.seen ? "true" : "false",
            menu_shared.error ? "true" : "false", menu_shared.unsupported ? "true" : "false",
            menu_shared.x1 > menu_shared.x0 ? "true" : "false", menu_shared.audio_index, menu_shared.pg_index);
    pthread_mutex_unlock(&menu_data_lock);
    return written >= 0 && written < capacity ? written : AVERROR(ENOSPC);
}

/* The occupied part of the shown IG plane as straight-to-premultiplied RGBA.
   rect: x, y, width, height, plane width, plane height. Returns the bytes
   written, 0 when the plane is empty, or a negative error. */
int avformat_thru3d_bd_menu_overlay(uint64_t version, uint8_t *rgba, int capacity, int *rect)
{
    int ret = 0;
    pthread_mutex_lock(&menu_data_lock);
    if (!menu_shared.owner || version != menu_shared.version) { ret = AVERROR(EAGAIN); goto done; }
    int w = menu_shared.x1 - menu_shared.x0, h = menu_shared.y1 - menu_shared.y0;
    rect[0] = menu_shared.x0; rect[1] = menu_shared.y0; rect[2] = w; rect[3] = h;
    rect[4] = menu_shared.width; rect[5] = menu_shared.height;
    if (w <= 0 || h <= 0) goto done;
    if ((int64_t)w * h * 4 > capacity) { ret = AVERROR(ENOSPC); goto done; }
    for (int y = 0; y < h; y++) {
        const uint32_t *row = menu_shared.shown + (size_t)(menu_shared.y0 + y) * menu_shared.width + menu_shared.x0;
        uint8_t *out = rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            uint32_t p = row[x], a = p >> 24;
            out[4*x+0] = ((p >> 16 & 255) * a + 127) / 255;
            out[4*x+1] = ((p >> 8 & 255) * a + 127) / 255;
            out[4*x+2] = ((p & 255) * a + 127) / 255;
            out[4*x+3] = a;
        }
    }
    ret = w * h * 4;
done:
    pthread_mutex_unlock(&menu_data_lock);
    return ret;
}

/* kind: 0 point at plane x/y, 1 activate at x/y, 2..5 up/down/left/right,
   6 enter, 7 top menu, 8 popup menu. Returns libbluray's result or -1. */
int avformat_thru3d_bd_menu_input(int kind, int x, int y)
{
    static const uint32_t keys[] = {BD_VK_UP, BD_VK_DOWN, BD_VK_LEFT, BD_VK_RIGHT, BD_VK_ENTER};
    int ret = -1;
    pthread_mutex_lock(&menu_input_lock);
    BdMvc *s = menu_shared.owner;
    if (s && s->disc) {
        if ((kind == 0 || kind == 1) && x >= 0 && y >= 0 && x < 65536 && y < 65536) {
            ret = bd_mouse_select(s->disc, -1, x, y);
            if (kind == 1) ret = bd_user_input(s->disc, -1, BD_VK_MOUSE_ACTIVATE);
        } else if (kind >= 2 && kind <= 6) ret = bd_user_input(s->disc, -1, keys[kind - 2]);
        else if (kind == 7) {
            /* The viewer's own "back to the menu": a top menu usually masks the call. */
            bd_set_player_setting(s->disc, BLURAY_PLAYER_SETTING_UO_RESTRICTION_LEVEL, BLURAY_PLAYER_SETTING_UO_RESTRICTION_DISABLED);
            ret = bd_menu_call(s->disc, -1);
            bd_set_player_setting(s->disc, BLURAY_PLAYER_SETTING_UO_RESTRICTION_LEVEL, BLURAY_PLAYER_SETTING_UO_RESTRICTION_RELAXED);
        }
        else if (kind == 8) ret = bd_user_input(s->disc, -1, BD_VK_POPUP);
    }
    pthread_mutex_unlock(&menu_input_lock);
    return ret;
}

static int disc_header(AVFormatContext *context)
{
    BdMvc *s = context->priv_data;
    BLURAY_STREAM_INFO *video;
    BLURAY_CLIP_INFO *clip;
    const BLURAY_DISC_INFO *info;
    uint64_t longest = 0;
    int titles, ret, selected = -1;
    char path[128];
    s->outer = context;
    av_log(context, AV_LOG_VERBOSE, "MVC ISO: opening sector reader\n");
    if (!context->pb || !(context->pb->seekable & AVIO_SEEKABLE_NORMAL))
        return AVERROR(ENOSYS);
    s->disc = bd_init();
    if (!s->disc || !bd_open_stream(s->disc, s, disc_blocks))
        return AVERROR_INVALIDDATA;
    info = bd_get_disc_info(s->disc);
    if (!info || !info->bluray_detected ||
        (info->aacs_detected && !info->aacs_handled) ||
        (info->bdplus_detected && !info->bdplus_handled)) {
        av_log(context, AV_LOG_ERROR, "Blu-ray image is unavailable or encrypted\n");
        return AVERROR(EACCES);
    }
    if (s->menu) return menu_header(context, info);
    s->input.input.read = udf_blocks; s->input.owner = s;
    s->udf = udfread_init();
    if (!s->udf || udfread_open_input(s->udf, &s->input.input) < 0)
        return AVERROR_INVALIDDATA;
    if (s->playlist >= 0) {
        /* An explicit title chosen from avformat_thru3d_bd_titles(). libbluray
           expects its title scan before a playlist is opened directly. */
        bd_get_titles(s->disc, TITLES_RELEVANT, 0);
        if (!bd_select_playlist(s->disc, s->playlist)) return AVERROR(EINVAL);
        s->title = bd_get_playlist_info(s->disc, s->playlist, 0);
    } else {
        titles = bd_get_titles(s->disc, TITLES_RELEVANT, 0);
        for (int i = 0; i < titles; i++) {
            if (ff_check_interrupt(&context->interrupt_callback)) return AVERROR_EXIT;
            BLURAY_TITLE_INFO *candidate = bd_get_title_info(s->disc, i, 0);
            /* The longest title this demuxer can play: an incompatible main
               feature layout must not hide every other title on the disc. */
            if (candidate && candidate->duration > longest &&
                title_layout(candidate, candidate->clip_count && candidate->clip_count <= 4096 &&
                             title_is_mvc(s, candidate)) >= 0) {
                selected = i;
                longest = candidate->duration;
            }
            if (candidate) bd_free_title_info(candidate);
        }
        if (selected < 0 || !bd_select_title(s->disc, selected))
            return AVERROR_INVALIDDATA;
        s->title = bd_get_title_info(s->disc, selected, 0);
    }
    if (!s->title || !s->title->clip_count || s->title->clip_count > 4096) return AVERROR_INVALIDDATA;
    clip = &s->title->clips[0];
    av_log(context, AV_LOG_VERBOSE, "MVC ISO: title %u has %u video streams\n", s->title->playlist, clip->video_stream_count);
    if (!clip->video_stream_count || clip->still_mode != BLURAY_STILL_NONE)
        return AVERROR_INVALIDDATA;
    video = &clip->video_streams[0];
    if (video->format >= FF_ARRAY_ELEMS(format_widths) || !format_widths[video->format]) return AVERROR(ENOSYS);
    s->width = format_widths[video->format]; s->height = format_heights[video->format];
    s->base_pid = video->pid; s->dependent_pid = 0x1012;
    s->origin = clip->in_time; s->end = clip->out_time;
    snprintf(path, sizeof(path), "BDMV/STREAM/SSIF/%s.ssif", clip->clip_id);
    s->ssif = udfread_file_open(s->udf, path);
    s->is_mvc = s->ssif != NULL;
    s->title_stream = !s->is_mvc && s->title->clip_count > 1;
    if (s->title_stream) {
        s->clip_offsets = av_calloc(s->title->clip_count + 1, sizeof(*s->clip_offsets));
        if (!s->clip_offsets) return AVERROR(ENOMEM);
    }
    if ((ret = title_layout(s->title, s->is_mvc)) < 0) return ret;
    for (unsigned i = 0; s->title_stream && i < s->title->clip_count; i++)
        s->clip_offsets[i+1] = s->clip_offsets[i] + (int64_t)s->title->clips[i].pkt_count * 192;
    if (s->is_mvc) {
        s->mvc_clips = av_calloc(s->title->clip_count, sizeof(*s->mvc_clips));
        if (!s->mvc_clips) return AVERROR(ENOMEM);
        /* Validate each independent SSIF/index association during preflight.
           Only the active clip's file handles and parsed indexes stay resident. */
        for (unsigned i = 0; i < s->title->clip_count; i++) {
            if (ff_check_interrupt(&context->interrupt_callback)) return AVERROR_EXIT;
            if ((ret = select_mvc_clip(s, i)) < 0) return ret;
        }
        if (s->packet_clip && (ret = select_mvc_clip(s, 0)) < 0) return ret;
    } else {
        snprintf(path, sizeof(path), "BDMV/STREAM/%s.m2ts", clip->clip_id);
        s->base = udfread_file_open(s->udf, path);
        s->ssif = udfread_file_open(s->udf, path);
        s->base_index = bd_get_clpi(s->disc, 0);
        if (!s->base || !s->ssif || !s->base_index) return AVERROR_INVALIDDATA;
        s->size = s->title_stream ? bd_get_title_size(s->disc) : udfread_file_size(s->ssif);
        if (s->title_stream && s->clip_offsets[s->title->clip_count] != s->size) return AVERROR_INVALIDDATA;
    }
    if (s->size <= 0) return AVERROR_INVALIDDATA;
    context->duration = av_rescale(s->title->duration, AV_TIME_BASE, 90000);
    context->start_time = 0;
    av_dict_set_int(&context->metadata, "thru3d_clip_count", s->title->clip_count, 0);
    if (s->header_only) return 0;
    if ((ret = open_transport(s)) < 0) return ret;
    s->mapped_streams = s->inner->nb_streams;
    s->stream_map = av_malloc_array(s->mapped_streams, sizeof(*s->stream_map));
    if (!s->stream_map) return AVERROR(ENOMEM);
    s->video_stream = -1;
    for (unsigned i = 0; i < s->mapped_streams; i++) {
        AVStream *in = s->inner->streams[i], *out;
        s->stream_map[i] = -1;
        if (in->id == s->dependent_pid) continue;
        if (in->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && in->id != s->base_pid) continue;
        out = avformat_new_stream(context, NULL);
        if (!out) return AVERROR(ENOMEM);
        s->stream_map[i] = out->index;
        out->id = in->id;
        avpriv_set_pts_info(out, 33, 1, 90000);
        if ((ret = avcodec_parameters_copy(out->codecpar, in->codecpar)) < 0) return ret;
        if (s->is_mvc && out->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
            ffstream(out)->need_parsing = AVSTREAM_PARSE_FULL;
        out->start_time = 0;
        out->duration = s->title->duration;
        out->disposition = in->disposition;
        if (in->id == s->base_pid) s->video_stream = out->index;
        if (in->id == s->base_pid && s->is_mvc) {
            AVStereo3D *stereo;
            AVPacketSideData *sd;
            s->video_stream = out->index;
            out->codecpar->codec_id = AV_CODEC_ID_H264_MVC;
            out->codecpar->codec_tag = 0;
            out->codecpar->width = s->width * 2;
            out->codecpar->height = s->height;
            out->codecpar->format = AV_PIX_FMT_YUV420P;
            out->codecpar->color_space = AVCOL_SPC_BT709;
            out->codecpar->color_range = AVCOL_RANGE_MPEG;
            out->codecpar->sample_aspect_ratio = (AVRational){1, 1};
            av_freep(&out->codecpar->extradata);
            out->codecpar->extradata = av_mallocz(1 + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!out->codecpar->extradata) return AVERROR(ENOMEM);
            out->codecpar->extradata_size = 1;
            out->codecpar->extradata[0] = s->title->mvc_base_view_r_flag;
            static const AVRational rates[8] = {{0,1}, {24000,1001}, {24,1}, {25,1}, {30000,1001}, {0,1}, {50,1}, {60000,1001}};
            out->avg_frame_rate = out->r_frame_rate = rates[video->rate & 7];
            av_dict_set(&out->metadata, "stereo_mode", "left_right", 0);
            sd = av_packet_side_data_new(&out->codecpar->coded_side_data, &out->codecpar->nb_coded_side_data,
                                         AV_PKT_DATA_STEREO3D, sizeof(*stereo), 0);
            if (!sd) return AVERROR(ENOMEM);
            stereo = (AVStereo3D *)sd->data;
            *stereo = (AVStereo3D){.type = AV_STEREO3D_SIDEBYSIDE, .view = AV_STEREO3D_VIEW_PACKED};
            out->disposition |= AV_DISPOSITION_DEFAULT;
        }
        const BLURAY_CLIP_INFO *named = s->is_mvc ? clip : reference_clip(s->title);
        for (unsigned a = 0; a < named->audio_stream_count; a++)
            if (named->audio_streams[a].pid == in->id)
                av_dict_set(&out->metadata, "language", (const char *)named->audio_streams[a].lang, 0);
        for (unsigned p = 0; p < named->pg_stream_count; p++)
            if (named->pg_streams[p].pid == in->id)
                av_dict_set(&out->metadata, "language", (const char *)named->pg_streams[p].lang, 0);
    }
    if (s->video_stream < 0) return AVERROR_INVALIDDATA;
    context->duration = av_rescale(s->title->duration, AV_TIME_BASE, 90000);
    context->start_time = 0;
    av_dict_set(&context->metadata, "thru3d_mvc_iso", s->is_mvc ? "1" : "0", 0);
    for (unsigned c = 0; c < s->title->chapter_count; c++)
        avpriv_new_chapter(context, c, (AVRational){1,90000}, s->title->chapters[c].start,
                          s->title->chapters[c].start + s->title->chapters[c].duration, NULL);
    av_log(context, AV_LOG_INFO, "MVC ISO playlist %05u, %dx%d per eye, duration %.3f, base eye %s\n",
           s->title->playlist, s->width, s->height, context->duration / 1000000.,
           s->title->mvc_base_view_r_flag ? "right" : "left");
    return 0;
}

/* A clip whose PMT lacks a stream (a silent leader) makes the MPEG-TS demuxer
   create that PID again under a new index when the next clip's PMT lists it.
   Route such streams to the output stream of the same PID and type. */
static int map_late_streams(BdMvc *s)
{
    int *grown;
    unsigned old = s->mapped_streams;
    if (s->inner->nb_streams <= old) return 0;
    grown = av_realloc_array(s->stream_map, s->inner->nb_streams, sizeof(*grown));
    if (!grown) return AVERROR(ENOMEM);
    s->stream_map = grown;
    for (unsigned i = old; i < s->inner->nb_streams; i++) {
        AVStream *in = s->inner->streams[i];
        s->stream_map[i] = -1;
        for (unsigned j = 0; in->id != s->dependent_pid && j < s->outer->nb_streams; j++)
            if (s->outer->streams[j]->id == in->id &&
                s->outer->streams[j]->codecpar->codec_type == in->codecpar->codec_type) s->stream_map[i] = j;
    }
    s->mapped_streams = s->inner->nb_streams;
    return 0;
}

static int disc_packet(AVFormatContext *context, AVPacket *output)
{
    BdMvc *s = context->priv_data;
    if (s->menu) return menu_packet(context, output);
    for (;;) {
        AVPacket *packet = av_packet_alloc();
        int ret, pid, eye;
        PacketNode **other, *found;
        if (!packet) return AVERROR(ENOMEM);
        if (!s->inner) { av_packet_free(&packet); return AVERROR(EIO); }
        ret = av_read_frame(s->inner, packet);
        if (ret < 0) {
            av_log(context, AV_LOG_VERBOSE, "MVC inner read returned %d at %"PRId64"\n", ret, avio_tell(s->stream_io));
            av_packet_free(&packet);
            if (ret == AVERROR_EOF && s->is_mvc && s->packet_clip + 1 < s->title->clip_count) {
                /* Starting at the earlier of two CLPI points can read one
                   view before the other's first access unit. Only these
                   pre-roll or out-of-presentation orphans may be discarded. */
                for (int view = 0; view < 2; view++) {
                    PacketNode **node = &s->views[view];
                    while (*node) {
                        AVPacket *p = (*node)->packet;
                        if (p->pts < s->origin || p->pts >= s->end ||
                            (p->dts != AV_NOPTS_VALUE && s->first_pair_dts != AV_NOPTS_VALUE &&
                             p->dts < s->first_pair_dts)) {
                            PacketNode *old = *node;
                            *node = old->next; s->queued_bytes -= p->size;
                            av_packet_free(&old->packet); av_free(old);
                        } else node = &(*node)->next;
                    }
                }
                /* A one-eyed tail cannot be shown; drop it rather than ending the title. */
                if (s->views[0] || s->views[1])
                    av_log(context, AV_LOG_WARNING, "MVC clip %d ended with an unmatched view; dropping it\n",
                           s->packet_clip + 1);
                if ((ret = switch_mvc_clip(s, s->packet_clip + 1)) < 0) return ret;
                continue;
            }
            return ret;
        }
        if ((unsigned)packet->stream_index >= s->mapped_streams && (ret = map_late_streams(s)) < 0) {
            av_packet_free(&packet); return ret;
        }
        if ((unsigned)packet->stream_index >= s->mapped_streams) { av_packet_free(&packet); continue; }
        pid = s->inner->streams[packet->stream_index]->id;
        int64_t origin = s->origin, end = s->end;
        int64_t title_start = s->is_mvc ? s->title->clips[s->packet_clip].start_time : 0;
        if (s->title_stream) {
            if (packet->pos >= 0) {
                unsigned low = 0, high = s->title->clip_count - 1;
                while (low < high) {
                    unsigned middle = low + (high - low + 1) / 2;
                    if (s->clip_offsets[middle] <= packet->pos) low = middle;
                    else high = middle - 1;
                }
                s->packet_clip = low;
            }
            BLURAY_CLIP_INFO *part = &s->title->clips[s->packet_clip];
            origin = part->in_time; end = part->out_time; title_start = part->start_time;
        }
        if (s->packets++ < 8)
            av_log(context, AV_LOG_VERBOSE, "MVC packet pid=%x pts=%"PRId64" dts=%"PRId64" bytes=%d origin=%"PRId64" end=%"PRId64"\n",
                   pid, packet->pts, packet->dts, packet->size, s->origin, s->end);
        /* MVC reference pictures can have PTS beyond the playlist out-point
           while earlier B pictures still need them. Trim decoded frames, not
           compressed reference pictures. Ordinary/audio trimming stays here. */
        if ((!s->is_mvc || (pid != s->base_pid && pid != s->dependent_pid)) &&
            packet->pts != AV_NOPTS_VALUE && packet->pts >= end) { av_packet_free(&packet); continue; }
        if (!s->is_mvc || (pid != s->base_pid && pid != s->dependent_pid)) {
            int mapped = s->stream_map[packet->stream_index];
            if (mapped < 0 || (packet->pts != AV_NOPTS_VALUE && packet->pts < origin)) {
                av_packet_free(&packet); continue;
            }
            packet->stream_index = mapped;
            if (packet->pts != AV_NOPTS_VALUE) packet->pts += title_start - origin;
            if (packet->dts != AV_NOPTS_VALUE) packet->dts += title_start - origin;
            av_packet_move_ref(output, packet);
            av_packet_free(&packet);
            return 0;
        }
        int terminator = 0, picture = 0;
        for (int at = 0; at + 3 < packet->size; at++) {
            if (packet->data[at] || packet->data[at+1] || packet->data[at+2] != 1) continue;
            int type = packet->data[at+3] & 31;
            terminator |= type == 10 || type == 11;
            picture |= (type >= 1 && type <= 5) || type == 20;
        }
        if (terminator && !picture) { av_packet_free(&packet); continue; }
        if (packet->pts == AV_NOPTS_VALUE || packet->size <= 0 || packet->size > 16*1024*1024) {
            av_log(context, AV_LOG_ERROR, "MVC invalid PES pid=%x pts=%"PRId64" dts=%"PRId64" bytes=%d\n",
                   pid, packet->pts, packet->dts, packet->size);
            av_packet_free(&packet); return AVERROR_INVALIDDATA;
        }
        eye = pid == s->base_pid ? 0 : 1;
        other = &s->views[!eye];
        while (*other && (*other)->packet->pts != packet->pts) other = &(*other)->next;
        found = *other;
        if (found) {
            AVPacket *base = eye ? found->packet : packet;
            AVPacket *dependent = eye ? packet : found->packet;
            int total = base->size + dependent->size;
            if (base->dts != dependent->dts || total > 16*1024*1024) {
                av_log(context, AV_LOG_ERROR, "MVC pair DTS mismatch: %"PRId64" / %"PRId64"\n", base->dts, dependent->dts);
                av_packet_free(&packet); return AVERROR_INVALIDDATA;
            }
            if (s->first_pair_dts == AV_NOPTS_VALUE) s->first_pair_dts = base->dts;
            /* CLPI random-access points may use recovery-point SEI with an
               intra picture instead of IDR. The decoder's reset gate handles
               both; discarding these here would skip seconds after a seek. */
            ret = av_new_packet(output, total);
            if (ret < 0) { av_packet_free(&packet); return ret; }
            memcpy(output->data, base->data, base->size);
            memcpy(output->data + base->size, dependent->data, dependent->size);
            output->pts = base->pts + title_start - origin;
            output->dts = base->dts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : base->dts + title_start - origin;
            output->duration = base->duration;
            output->flags = base->flags;
            output->stream_index = s->video_stream;
            output->pos = base->pos;
            if (s->clip_tag_pending) {
                AVDictionary *tag = NULL;
                size_t bytes;
                uint8_t *data;
                av_dict_set_int(&tag, "thru3d_mvc_clip", s->packet_clip, 0);
                av_dict_set_int(&tag, "thru3d_mvc_start", title_start, 0);
                av_dict_set_int(&tag, "thru3d_mvc_end", title_start + end - origin, 0);
                data = av_packet_pack_dictionary(tag, &bytes);
                av_dict_free(&tag);
                if (!data) { av_packet_unref(output); av_packet_free(&packet); return AVERROR(ENOMEM); }
                ret = av_packet_add_side_data(output, AV_PKT_DATA_STRINGS_METADATA, data, bytes);
                if (ret < 0) { av_free(data); av_packet_unref(output); av_packet_free(&packet); return ret; }
                s->clip_tag_pending = 0;
            }
            *other = found->next;
            s->queued_bytes -= found->packet->size;
            av_packet_free(&found->packet); av_free(found);
            av_packet_free(&packet);
            s->paired++;
            return 0;
        }
        PacketNode *node = av_mallocz(sizeof(*node));
        if (!node) { av_packet_free(&packet); return AVERROR(ENOMEM); }
        node->packet = packet;
        PacketNode **tail = &s->views[eye];
        while (*tail) tail = &(*tail)->next;
        *tail = node;
        s->queued_bytes += packet->size;
        if (s->queued_bytes > 128*1024*1024) {
            av_log(context, AV_LOG_ERROR, "MVC view pairing exceeded bounded read-ahead\n");
            return AVERROR_INVALIDDATA;
        }
    }
}

static int64_t ssif_position(BdMvc *s, UDFFILE *file, int64_t position)
{
    uint32_t target, low = 0, high = (s->size - 1) / 2048;
    if (position < 0 || position >= udfread_file_size(file)) return AVERROR(EIO);
    target = udfread_file_lba(file, position / 2048);
    if (!target) return AVERROR(EIO);
    /* Locate the base IDR's physical sector in the interleaved SSIF allocation.
       Validate the exact match: fragmented/unordered layouts must never seek to a guess. */
    while (low < high) {
        uint32_t middle = low + (high - low) / 2;
        uint32_t physical = udfread_file_lba(s->ssif, middle);
        if (!physical) return AVERROR(EIO);
        if (physical < target) low = middle + 1;
        else high = middle;
    }
    if (udfread_file_lba(s->ssif, low) != target) return AVERROR(ENOSYS);
    return (int64_t)low * 2048 + position % 2048;
}

static int disc_seek(AVFormatContext *context, int stream, int64_t timestamp, int flags)
{
    BdMvc *s = context->priv_data;
    int64_t position, base, dependent;
    if (stream >= 0)
        timestamp = av_rescale_q(timestamp, context->streams[stream]->time_base, (AVRational){1,90000});
    else
        timestamp = av_rescale_q(timestamp, AV_TIME_BASE_Q, (AVRational){1,90000});
    timestamp = av_clip64(timestamp, 0, s->title->duration - 1);
    if (s->is_mvc) {
        unsigned clip = 0;
        int ret;
        while (clip + 1 < s->title->clip_count && s->title->clips[clip + 1].start_time <= timestamp) clip++;
        clear_views(s);
        if ((clip != s->packet_clip || !s->inner) && (ret = switch_mvc_clip(s, clip)) < 0) return ret;
        timestamp -= s->title->clips[clip].start_time;
        s->clip_tag_pending = 1;
    }
    if (s->title_stream) {
        position = bd_seek_time(s->disc, timestamp);
        if (position < 0) return AVERROR(EIO);
        avformat_flush(s->inner);
        // Navigation moved the underlying reader; invalidate buffered old-clip bytes.
        s->stream_io->buf_ptr = s->stream_io->buf_end = s->stream_io->buffer;
        s->stream_io->pos = position;
        s->stream_io->eof_reached = 0;
        s->stream_io->error = 0;
        s->packet_clip = 0;
        while (s->packet_clip + 1 < s->title->clip_count && s->clip_offsets[s->packet_clip+1] <= position)
            s->packet_clip++;
        return 0;
    }
    uint32_t tick = (s->origin + timestamp) / 2;
    base = (int64_t)clpi_lookup_spn(s->base_index, tick, 1, 0) * 192;
    if (s->is_mvc) base = ssif_position(s, s->base, base);
    dependent = s->is_mvc ? ssif_position(s, s->dependent,
        (int64_t)clpi_lookup_spn(s->dependent_index, tick, 1, 0) * 192) : base;
    if (base < 0 || dependent < 0) return AVERROR(ENOSYS);
    position = timestamp ? FFMIN(base, dependent) : 0;
    clear_views(s);
    avformat_flush(s->inner);
    if (avio_seek(s->stream_io, position, SEEK_SET) < 0) return AVERROR(EIO);
    av_log(context, AV_LOG_VERBOSE, "MVC seek %.3f sec -> SSIF byte %"PRId64"\n", timestamp / 90000., position);
    return 0;
}

static int disc_probe(const AVProbeData *probe)
{
    for (int at = 16 * 2048; at + 7 < probe->buf_size && at < 32 * 2048; at += 2048)
        if (!memcmp(probe->buf + at + 1, "NSR03", 5) || !memcmp(probe->buf + at + 1, "NSR02", 5))
            return AVPROBE_SCORE_MAX;
    return av_match_ext(probe->filename, "iso") ? AVPROBE_SCORE_EXTENSION / 2 : 0;
}

/* HDMV navigation needs a MovieObject table libbluray can parse (main or backup copy):
   the same length check it applies, so a truncated table does not offer a menu. */
static int movie_objects_valid(BdMvc *s)
{
    static const char *const names[] = {"BDMV/MovieObject.bdmv", "BDMV/BACKUP/MovieObject.bdmv"};
    for (int i = 0; i < 2; i++) {
        uint8_t header[48];
        UDFFILE *file = udfread_file_open(s->udf, names[i]);
        int64_t size;
        int valid;
        if (!file) continue;
        size = udfread_file_size(file);
        valid = udfread_file_read(file, header, sizeof(header)) == sizeof(header) && !memcmp(header, "MOBJ", 4) &&
                size - 44 >= (int64_t)AV_RB32(header + 40);
        udfread_file_close(file);
        if (valid) return 1;
    }
    return 0;
}

/* Selectable titles of the opened disc as a JSON array. Reuses the preflight's
   reader and sector cache: no second disc open and no stream probing. */
static void list_titles(BdMvc *s, char *json, int capacity)
{
    unsigned listed = 0;
    uint32_t count = bd_get_titles(s->disc, TITLES_RELEVANT, 30);
    const BLURAY_DISC_INFO *info = bd_get_disc_info(s->disc);
    /* Without a Java VM libbluray leaves a BD-J top menu unsupported (and unnamed):
       an unplayable top menu on a disc with BD-J is still named as such. */
    const char *menu = !info ? "none" :
                       !info->top_menu_supported || !info->top_menu ? (info->bdj_detected ? "bdj" : "none") :
                       info->top_menu->bdj ? "bdj" : movie_objects_valid(s) ? "hdmv" : "none";
    snprintf(json, capacity, "{\"menu\":\"%s\",\"titles\":[", menu);
    for (uint32_t i = 0; i < count && listed < 48; i++) {
        if (ff_check_interrupt(&s->outer->interrupt_callback)) break;
        BLURAY_TITLE_INFO *title = bd_get_title_info(s->disc, i, 0);
        char item[256];
        if (!title) continue;
        int mvc = title->clip_count && title->clip_count <= 4096 && title_is_mvc(s, title);
        /* Silent playlists are menu loops and logos, not something to watch. */
        if (title_layout(title, mvc) >= 0 && reference_clip(title)->audio_stream_count) {
            const BLURAY_CLIP_INFO *clip = reference_clip(title);
            snprintf(item, sizeof(item), "%s{\"playlist\":%u,\"duration_ms\":%"PRIu64",\"chapters\":%u,"
                     "\"clips\":%u,\"angles\":%u,\"height\":%d,\"stereo\":%s,\"audio\":%u,\"subtitles\":%u}",
                     listed ? "," : "", title->playlist, title->duration / 90, title->chapter_count, title->clip_count,
                     title->angle_count, format_heights[clip->video_streams[0].format], mvc ? "true" : "false",
                     clip->audio_stream_count, clip->pg_stream_count);
            if (strlen(json) + strlen(item) + 3 > (size_t)capacity) { bd_free_title_info(title); break; }
            av_strlcat(json, item, capacity);
            listed++;
        }
        bd_free_title_info(title);
    }
    av_strlcat(json, "]}", capacity);
}

/* Private, versioned native preflight. Does no decoding and never creates GL state.
   playlist < 0 selects the longest title; json (optional) receives the title list. */
int avformat_thru3d_bd_titles(const char *url, int playlist, int *width, int *height, int64_t *duration,
                              int *mvc, int *selected, char *json, int capacity)
{
    return avformat_thru3d_bd_titles_v2(url, playlist, width, height, duration, mvc, selected,
                                      json, capacity, NULL, NULL);
}

int avformat_thru3d_bd_titles_v2(const char *url, int playlist, int *width, int *height, int64_t *duration,
                               int *mvc, int *selected, char *json, int capacity,
                               int (*interrupt)(void *), void *opaque)
{
    AVFormatContext *context = avformat_alloc_context();
    AVDictionary *options = NULL;
    if (!context) return AVERROR(ENOMEM);
    if (json && capacity < 3) { avformat_free_context(context); return AVERROR(EINVAL); }
    context->interrupt_callback = (AVIOInterruptCB){interrupt, opaque};
    av_dict_set(&options, "header_only", "1", 0);
    av_dict_set(&options, "rw_timeout", "30000000", 0);
    av_dict_set_int(&options, "playlist", playlist < 0 ? -1 : playlist, 0);
    int ret = avformat_open_input(&context, url, av_find_input_format("bd_mvc"), &options);
    av_dict_free(&options);
    if (ret >= 0) {
        BdMvc *s = context->priv_data;
        *width = s->width * (s->is_mvc ? 2 : 1); *height = s->height; *duration = context->duration;
        *mvc = s->is_mvc;
        if (selected) *selected = s->title->playlist;
        if (json) list_titles(s, json, capacity);
    }
    /* libbluray represents a cancelled block read as an invalid disc. Preserve
       cancellation even after a partial title scan appeared successful. */
    if (interrupt && interrupt(opaque)) ret = AVERROR_EXIT;
    avformat_close_input(&context);
    return ret;
}

int avformat_thru3d_bd_probe(const char *url, int *width, int *height, int64_t *duration, int *mvc)
{
    return avformat_thru3d_bd_titles(url, -1, width, height, duration, mvc, NULL, NULL, 0);
}

static const AVOption bd_options[] = {
    { "header_only", "Read Blu-ray title metadata without stream probing", offsetof(BdMvc, header_only), AV_OPT_TYPE_BOOL,
      { .i64 = 0 }, 0, 1, AV_OPT_FLAG_DECODING_PARAM },
    { "playlist", "Blu-ray playlist (MPLS) number; -1 selects the longest title", offsetof(BdMvc, playlist), AV_OPT_TYPE_INT,
      { .i64 = -1 }, -1, 99999, AV_OPT_FLAG_DECODING_PARAM },
    { "menu", "Play the disc's HDMV top menu instead of a title", offsetof(BdMvc, menu), AV_OPT_TYPE_BOOL,
      { .i64 = 0 }, 0, 1, AV_OPT_FLAG_DECODING_PARAM },
    { NULL }
};
static const AVClass bd_class = {
    .class_name = "Thru3D Blu-ray ISO",
    .item_name = av_default_item_name,
    .option = bd_options,
    .version = LIBAVUTIL_VERSION_INT,
};

const FFInputFormat ff_bd_mvc_demuxer = {
    .p.name = "bd_mvc",
    .p.long_name = NULL_IF_CONFIG_SMALL("Blu-ray MVC ISO (UDF/playlist/SSIF)"),
    .p.extensions = "iso",
    .p.flags = AVFMT_TS_DISCONT,
    .p.priv_class = &bd_class,
    .priv_data_size = sizeof(BdMvc),
    .flags_internal = FF_INFMT_FLAG_INIT_CLEANUP,
    .read_probe = disc_probe,
    .read_header = disc_header,
    .read_packet = disc_packet,
    .read_seek = disc_seek,
    .read_close = close_disc,
};
