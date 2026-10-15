/* Seekable Blu-ray MVC ISO demux bridge. LGPL-2.1-or-later. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include <errno.h>
#include <stddef.h>
#include <libbluray/bluray.h>
#include <libbluray/clpi_data.h>
#include <libbluray/filesystem.h>
#include <udfread/udfread.h>
#include <udfread/blockinput.h>
#include "libavutil/avstring.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/stereo3d.h"
#include "avformat.h"
#include "demux.h"
#include "internal.h"

int avformat_thru3d_bd_probe(const char *url, int *width, int *height, int64_t *duration, int *mvc);
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
    titles = bd_get_titles(s->disc, TITLES_RELEVANT, 0);
    for (int i = 0; i < titles; i++) {
        BLURAY_TITLE_INFO *candidate = bd_get_title_info(s->disc, i, 0);
        if (candidate && candidate->duration > longest) {
            selected = i;
            longest = candidate->duration;
        }
        if (candidate) bd_free_title_info(candidate);
    }
    if (selected < 0 || !bd_select_title(s->disc, selected))
        return AVERROR_INVALIDDATA;
    s->title = bd_get_title_info(s->disc, selected, 0);
    if (!s->title || !s->title->clip_count || s->title->clip_count > 4096) return AVERROR_INVALIDDATA;
    clip = &s->title->clips[0];
    av_log(context, AV_LOG_VERBOSE, "MVC ISO: title %u has %u video streams\n", s->title->playlist, clip->video_stream_count);
    if (!clip->video_stream_count || clip->still_mode != BLURAY_STILL_NONE)
        return AVERROR_INVALIDDATA;
    video = &clip->video_streams[0];
    static const int widths[] = {0,720,720,720,1920,1280,1920,720,3840};
    static const int heights[] = {0,480,576,480,1080,720,1080,576,2160};
    if (video->format >= FF_ARRAY_ELEMS(widths) || !widths[video->format]) return AVERROR(ENOSYS);
    s->width = widths[video->format]; s->height = heights[video->format];
    s->base_pid = video->pid; s->dependent_pid = 0x1012;
    s->origin = clip->in_time; s->end = clip->out_time;
    s->input.input.read = udf_blocks; s->input.owner = s;
    s->udf = udfread_init();
    if (!s->udf || udfread_open_input(s->udf, &s->input.input) < 0)
        return AVERROR_INVALIDDATA;
    snprintf(path, sizeof(path), "BDMV/STREAM/SSIF/%s.ssif", clip->clip_id);
    s->ssif = udfread_file_open(s->udf, path);
    s->is_mvc = s->ssif != NULL;
    s->title_stream = !s->is_mvc && s->title->clip_count > 1;
    if (s->title_stream) {
        s->clip_offsets = av_calloc(s->title->clip_count + 1, sizeof(*s->clip_offsets));
        if (!s->clip_offsets) return AVERROR(ENOMEM);
    }
    for (unsigned i = 0; i < s->title->clip_count; i++) {
        BLURAY_CLIP_INFO *part = &s->title->clips[i];
        if (!part->video_stream_count || part->still_mode != BLURAY_STILL_NONE ||
            part->out_time <= part->in_time ||
            part->video_streams[0].pid != video->pid ||
            part->video_streams[0].coding_type != video->coding_type ||
            part->video_streams[0].format != video->format ||
            part->audio_stream_count != clip->audio_stream_count)
            return AVERROR(ENOSYS);
        for (unsigned a = 0; a < part->audio_stream_count; a++)
            if (part->audio_streams[a].pid != clip->audio_streams[a].pid ||
                part->audio_streams[a].coding_type != clip->audio_streams[a].coding_type)
                return AVERROR(ENOSYS);
        if (s->is_mvc) {
            if (part->video_streams[0].rate != video->rate || part->pg_stream_count != clip->pg_stream_count)
                return AVERROR(ENOSYS);
            for (unsigned a = 0; a < part->audio_stream_count; a++)
                if (part->audio_streams[a].format != clip->audio_streams[a].format ||
                    part->audio_streams[a].rate != clip->audio_streams[a].rate) return AVERROR(ENOSYS);
            for (unsigned a = 0; a < part->pg_stream_count; a++)
                if (part->pg_streams[a].pid != clip->pg_streams[a].pid ||
                    part->pg_streams[a].coding_type != clip->pg_streams[a].coding_type) return AVERROR(ENOSYS);
        }
        if (s->title_stream) s->clip_offsets[i+1] = s->clip_offsets[i] + (int64_t)part->pkt_count * 192;
    }
    if (s->is_mvc) {
        if (video->format != BLURAY_VIDEO_FORMAT_1080P && video->format != BLURAY_VIDEO_FORMAT_720P)
            return AVERROR(ENOSYS);
        s->mvc_clips = av_calloc(s->title->clip_count, sizeof(*s->mvc_clips));
        if (!s->mvc_clips) return AVERROR(ENOMEM);
        /* Validate each independent SSIF/index association during preflight.
           Only the active clip's file handles and parsed indexes stay resident. */
        for (unsigned i = 0; i < s->title->clip_count; i++)
            if ((ret = select_mvc_clip(s, i)) < 0) return ret;
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
        for (unsigned a = 0; a < clip->audio_stream_count; a++)
            if (clip->audio_streams[a].pid == in->id)
                av_dict_set(&out->metadata, "language", (const char *)clip->audio_streams[a].lang, 0);
        for (unsigned p = 0; p < clip->pg_stream_count; p++)
            if (clip->pg_streams[p].pid == in->id)
                av_dict_set(&out->metadata, "language", (const char *)clip->pg_streams[p].lang, 0);
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

static int disc_packet(AVFormatContext *context, AVPacket *output)
{
    BdMvc *s = context->priv_data;
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

/* Private, versioned native preflight. Does no decoding and never creates GL state. */
int avformat_thru3d_bd_probe(const char *url, int *width, int *height, int64_t *duration, int *mvc)
{
    AVFormatContext *context = NULL;
    AVDictionary *options = NULL;
    av_dict_set(&options, "header_only", "1", 0);
    av_dict_set(&options, "rw_timeout", "30000000", 0);
    int ret = avformat_open_input(&context, url, av_find_input_format("bd_mvc"), &options);
    av_dict_free(&options);
    if (ret >= 0) {
        BdMvc *s = context->priv_data;
        *width = s->width * (s->is_mvc ? 2 : 1); *height = s->height; *duration = context->duration;
        *mvc = s->is_mvc;
    }
    avformat_close_input(&context);
    return ret;
}

static const AVOption bd_options[] = {
    { "header_only", "Read Blu-ray title metadata without stream probing", offsetof(BdMvc, header_only), AV_OPT_TYPE_BOOL,
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
