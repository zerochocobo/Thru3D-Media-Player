/* DVD ISO titles and interactive DVD-Video menus. LGPL-2.1-or-later.
 * Title decoding reuses the pinned FFmpeg dvdvideodec.c, with seekable AVIO
 * callbacks instead of path-only DVDOpen. Navigation uses libdvdnav's VM.
 * The caller owns sector IO, including its bounded cache and cancellation. */
#include <pthread.h>
#include <dvdnav/dvdnav.h>
#include "libavutil/time.h"
#include "dvd_nav.h"
#include "internal.h"
#include "url.h"

typedef struct DvdIO {
    AVFormatContext *context;
    void *source;
    int (*blocks)(void *, void *, int, int);
    uint64_t position;
} DvdIO;

static int dvd_io_seek(void *opaque, uint64_t position)
{
    DvdIO *io = opaque;
    if (position / 2048 > INT_MAX || position % 2048) return -1;
    io->position = position;
    return 0;
}

static int dvd_io_read(void *opaque, void *buffer, int bytes)
{
    DvdIO *io = opaque;
    if (bytes < 0 || bytes % 2048 || io->position / 2048 > INT_MAX ||
        ff_check_interrupt(&io->context->interrupt_callback)) return -1;
    int count = io->blocks(io->source, buffer, io->position / 2048, bytes / 2048);
    if (count <= 0) return -1;
    io->position += count * 2048;
    return count * 2048;
}
static dvd_reader_stream_cb dvd_io_callbacks = {.pf_seek = dvd_io_seek, .pf_read = dvd_io_read};

static int thru_dvd_title_jump(dvdnav_t *nav,int title,int64_t pts,const uint64_t *ends,int chapters)
{
    /* Chapter selections arrive as milliseconds. Use the VM's exact PTT entry
     * instead of interpolating a sector near the boundary. */
    for(int chapter=1;chapter<=chapters;chapter++) {
        int64_t start=chapter==1 ? 0 : ends[chapter-2];
        if(llabs(pts-start)<90) return dvdnav_part_play(nav,title,chapter);
    }
    return dvdnav_jump_to_sector_by_time(nav,pts,0);
}

/* Generated from the locked FFmpeg archive by mvc_patch.py. Retains its
 * license and all upstream stream/PGC/chapter/codec handling. */
#include "thru3d_dvd_title.c"

#define DVD_MAX_TITLES 99
#define DVD_PLANE (720 * 576)
typedef struct DvdTitle {
    int number, width, height, chapters, audio, subtitles, angles;
    int vts;
    uint32_t first_sector;
    int64_t duration;
    uint64_t *ends;
} DvdTitle;

struct ThruDvd {
    DvdIO io, nav_io;
    AVFormatContext *outer, *inner;
    AVIOContext *mpeg_io;
    dvd_reader_t *reader;
    ifo_handle_t *vmg;
    dvdnav_t *nav;
    DvdTitle titles[DVD_MAX_TITLES];
    int count, selected, has_menu, menu, width, height;
    int started, reset, boundary, eof, seen, in_menu, title, chapter;
    int audio_index, subtitle_index, spu_stream, error;
    int64_t chapter_ms, still_until, epoch_end, epoch_offset, last_end;
    int64_t packet_offset;
    int64_t packet_time, packet_end;
    AVPacket *video_unit, *still_picture;
    pci_t pci;
    uint32_t clut[16];
    uint8_t *spu;
    int spu_x, spu_y, spu_w, spu_h, spu_visible;
    uint16_t spu_palette, spu_alpha;
    uint32_t *plane;
    int x0, y0, x1, y1;
    uint64_t version;
    int highlighted;
};

/* Only the menu worker touches the VM. UI actions are queued, so network IO
 * can never block the render thread. Data snapshots have a separate lock. */
static pthread_mutex_t dvd_data_lock = PTHREAD_MUTEX_INITIALIZER;
static ThruDvd *dvd_menu;
static uint64_t dvd_version;
static struct { int kind, x, y; } dvd_commands[32];
static unsigned dvd_head, dvd_tail;

static void quiet_dvdread(void *opaque, dvd_logger_level_t level, const char *msg, va_list args) {}
static void quiet_dvdnav(void *opaque, dvdnav_logger_level_t level, const char *msg, va_list args) {}

static int has_menu_entries(const pgci_ut_t *table)
{
    if (!table || !table->lu) return 0;
    for (unsigned i = 0; i < table->nr_of_lus; i++) {
        pgcit_t *pg = table->lu[i].pgcit;
        if (!pg || !pg->pgci_srp) continue;
        for (unsigned j = 0; j < pg->nr_of_pgci_srp; j++)
            if ((pg->pgci_srp[j].entry_id & 0x80) && pg->pgci_srp[j].pgc)
                return 1;
    }
    return 0;
}

static int title_scan(ThruDvd *d, int requested)
{
    if (!d->vmg->tt_srpt || !d->vmg->tt_srpt->title ||
        d->vmg->tt_srpt->nr_of_srpts > DVD_MAX_TITLES) return AVERROR_INVALIDDATA;
    d->has_menu = has_menu_entries(d->vmg->pgci_ut);
    int last_vts = -1;
    ifo_handle_t *vts = NULL;
    uint64_t longest = 0;
    for (int n = 1; n <= d->vmg->tt_srpt->nr_of_srpts; n++) {
        if (ff_check_interrupt(&d->outer->interrupt_callback)) break;
        title_info_t *info = &d->vmg->tt_srpt->title[n - 1];
        if (info->title_set_nr != last_vts) {
            if (vts) ifoClose(vts);
            vts = ifoOpen(d->reader, info->title_set_nr);
            last_vts = info->title_set_nr;
        }
        if (!vts || !vts->vtsi_mat) continue;
        d->has_menu |= has_menu_entries(vts->pgci_ut);
        uint64_t duration = 0, *ends = NULL;
        unsigned chapters = dvdnav_describe_title_chapters(d->nav, n, &ends, &duration);
        if (!chapters || !duration || chapters > 999) { free(ends); continue; }
        video_attr_t video = vts->vtsi_mat->vts_video_attr;
        static const int widths[] = {720, 704, 352, 352};
        DvdTitle *t = &d->titles[d->count++];
        *t = (DvdTitle){.number=n, .width=widths[video.picture_size],
            .height=(video.video_format ? 576 : 480) / (video.picture_size == 3 ? 2 : 1),
            .chapters=chapters, .audio=vts->vtsi_mat->nr_of_vts_audio_streams,
            .subtitles=vts->vtsi_mat->nr_of_vts_subp_streams, .angles=info->nr_of_angles,
            .duration=duration, .ends=ends, .vts=info->title_set_nr};
        if(vts->vts_ptt_srpt && info->vts_ttn>0 && info->vts_ttn<=vts->vts_ptt_srpt->nr_of_srpts && vts->vts_pgcit) {
            ttu_t *unit=&vts->vts_ptt_srpt->title[info->vts_ttn-1];
            if(unit->nr_of_ptts && unit->ptt && unit->ptt[0].pgcn>0 && unit->ptt[0].pgcn<=vts->vts_pgcit->nr_of_pgci_srp) {
                pgc_t *pgc=vts->vts_pgcit->pgci_srp[unit->ptt[0].pgcn-1].pgc;
                int pg=unit->ptt[0].pgn;
                if(pgc && pg>0 && pg<=pgc->nr_of_programs && pgc->program_map && pgc->cell_playback) {
                    int cell=pgc->program_map[pg-1];
                    if(cell>0 && cell<=pgc->nr_of_cells) t->first_sector=pgc->cell_playback[cell-1].first_sector;
                }
            }
        }
        if (requested == n || (requested < 0 && duration > longest)) {
            d->selected = d->count - 1; longest = duration;
        }
    }
    if (vts) ifoClose(vts);
    if (ff_check_interrupt(&d->outer->interrupt_callback)) return AVERROR_EXIT;
    if (d->selected < 0 || !d->count) return AVERROR_STREAM_NOT_FOUND;
    DvdTitle *t = &d->titles[d->selected];
    /* Some authored discs advertise Half D1 in IFO but encode CIF. Surface
     * allocation must use the sequence header, without decoding the movie. */
    dvd_file_t *vob=DVDOpenFile(d->reader,t->vts,DVD_READ_TITLE_VOBS);
    uint8_t *head=av_malloc(128*2048);
    if(vob && head) {
        int count=DVDReadBlocks(vob,t->first_sector,128,head);
        for(int i=0;i+8<count*2048;i++) if(AV_RB32(head+i)==0x000001b3) {
            unsigned size=AV_RB24(head+i+4), w=size>>12, h=size&4095;
            if((w==352 || w==704 || w==720) && (h==240 || h==288 || h==480 || h==576)) {
                t->width=w; t->height=h; break;
            }
        }
    }
    av_free(head); if(vob) DVDCloseFile(vob);
    if(ff_check_interrupt(&d->outer->interrupt_callback)) return AVERROR_EXIT;
    d->width = t->width; d->height = t->height;
    d->outer->duration = av_rescale(t->duration, AV_TIME_BASE, 90000);
    return 0;
}

/* DVD SPU uses two interlaced fields and nibble RLE. Keep original two-bit
 * pixels: selection changes their CLUT/alpha only inside the DVD button. */
static int nibble(const uint8_t *data, int limit, int *at)
{
    if (*at < 0 || *at >= limit * 2) return -1;
    int value = (data[*at / 2] >> ((*at & 1) ? 0 : 4)) & 15;
    ++*at;
    return value;
}

static int spu_decode(ThruDvd *d, const uint8_t *data, int bytes)
{
    if (bytes < 4) return AVERROR_INVALIDDATA;
    int size = AV_RB16(data), control = AV_RB16(data + 2);
    if (size > bytes || control < 4 || control >= size) return AVERROR_INVALIDDATA;
    int x=0, y=0, w=0, h=0, offsets[2]={0}, visible=0;
    uint16_t palette=0, alpha=0;
    int sequence = control;
    for (int loops=0; loops<64; loops++) {
        if (sequence < control || sequence + 4 > size) return AVERROR_INVALIDDATA;
        int next = AV_RB16(data + sequence + 2), p = sequence + 4;
        while (p < size && data[p] != 0xff) {
            int cmd = data[p++];
            int len = cmd <= 2 ? 0 : cmd <= 4 ? 2 : cmd == 5 ? 6 : cmd == 6 ? 4 : -1;
            if (len < 0 || p + len > size) return AVERROR_INVALIDDATA;
            if (cmd == 0 || cmd == 1) visible = 1;
            /* A later stop is a scheduled expiry, not an instruction to hide
             * the initial menu. Navigation invalidates it at the next cell. */
            if (cmd == 3) palette = AV_RB16(data + p);
            if (cmd == 4) alpha = AV_RB16(data + p);
            if (cmd == 5) {
                x = AV_RB24(data+p) >> 12; w = (AV_RB24(data+p) & 4095) - x + 1;
                y = AV_RB24(data+p+3) >> 12; h = (AV_RB24(data+p+3) & 4095) - y + 1;
            }
            if (cmd == 6) { offsets[0]=AV_RB16(data+p); offsets[1]=AV_RB16(data+p+2); }
            p += len;
        }
        if (visible && w > 0 && offsets[0]) break;
        if (next == sequence) break;
        if (next <= sequence) return AVERROR_INVALIDDATA;
        sequence = next;
    }
    if (w <= 0 || h <= 0 || x+w > 720 || y+h > 576 ||
        offsets[0] < 4 || offsets[1] < 4 || offsets[0] >= control || offsets[1] >= control)
        return AVERROR_INVALIDDATA;
    uint8_t *pixels = av_mallocz(w*h);
    if (!pixels) return AVERROR(ENOMEM);
    for (int field=0; field<2; field++) {
        int at = offsets[field]*2;
        for (int row=field; row<h; row+=2) {
            int col=0;
            while (col<w) {
                int code=nibble(data,control,&at), n;
                if (code<0) goto invalid;
                for (int threshold=4; threshold<=0x40 && code<threshold; threshold*=4) {
                    n=nibble(data,control,&at); if(n<0) goto invalid;
                    code=(code<<4)|n;
                }
                int run=code>>2;
                if (!run) run=w-col;
                if(run>w-col) goto invalid;
                memset(pixels+row*w+col,code&3,run); col+=run;
            }
            at=(at+1)&~1;
        }
    }
    av_free(d->spu); d->spu=pixels;
    d->spu_x=x; d->spu_y=y; d->spu_w=w; d->spu_h=h;
    d->spu_palette=palette; d->spu_alpha=alpha; d->spu_visible=visible;
    return 0;
invalid:
    av_free(pixels); return AVERROR_INVALIDDATA;
}

static uint32_t dvd_color(uint32_t yuv, int alpha)
{
    int y=(yuv>>16)&255, cr=((yuv>>8)&255)-128, cb=(yuv&255)-128;
    int l=298*(y-16);
    int r=av_clip_uint8((l+409*cr+128)>>8), g=av_clip_uint8((l-100*cb-208*cr+128)>>8);
    int b=av_clip_uint8((l+516*cb+128)>>8), a=alpha*17;
    return (uint32_t)a<<24 | r<<16 | g<<8 | b;
}

static void menu_publish(ThruDvd *d)
{
    int button=0;
    dvdnav_get_current_highlight(d->nav, &button);
    dvdnav_highlight_area_t area={0};
    int highlight = dvdnav_get_highlight_area(&d->pci,button,0,&area)==DVDNAV_STATUS_OK;
    pthread_mutex_lock(&dvd_data_lock);
    d->highlighted=button;
    if (d->plane) memset(d->plane,0,DVD_PLANE*4);
    d->x0=d->width; d->y0=d->height; d->x1=d->y1=0;
    if (d->plane && d->spu && d->spu_visible) {
        for (int y=0; y<d->spu_h; y++) for(int x=0; x<d->spu_w; x++) {
            int px=d->spu_x+x, py=d->spu_y+y, code=d->spu[y*d->spu_w+x];
            if(px>=d->width || py>=d->height) continue;
            int selected=highlight && px>=area.sx && px<=area.ex && py>=area.sy && py<=area.ey;
            unsigned pal=selected ? area.palette>>16 : d->spu_palette;
            unsigned alpha=selected ? area.palette&65535 : d->spu_alpha;
            uint32_t color=dvd_color(d->clut[(pal>>(code*4))&15],(alpha>>(code*4))&15);
            d->plane[py*d->width+px]=color;
            if(color>>24) {
                d->x0=FFMIN(d->x0,px); d->y0=FFMIN(d->y0,py);
                d->x1=FFMAX(d->x1,px+1); d->y1=FFMAX(d->y1,py+1);
            }
        }
    }
    /* Include every hit area, even when only the selected button has visible
     * SPU pixels. Godot uses this crop as the ray interception boundary. */
    for(int b=1;b<=FFMIN(36,d->pci.hli.hl_gi.btn_ns);b++) {
        dvdnav_highlight_area_t a={0};
        if(dvdnav_get_highlight_area(&d->pci,b,0,&a)!=DVDNAV_STATUS_OK) continue;
        d->x0=FFMIN(d->x0,av_clip(a.sx,0,d->width)); d->y0=FFMIN(d->y0,av_clip(a.sy,0,d->height));
        d->x1=FFMAX(d->x1,av_clip(a.ex+1,0,d->width)); d->y1=FFMAX(d->y1,av_clip(a.ey+1,0,d->height));
    }
    d->version=++dvd_version;
    pthread_mutex_unlock(&dvd_data_lock);
}

static void title_track_choices(ThruDvd *d,int title,int *audio,int *subtitle)
{
    int current=0,pgcn=0,pgn=0;
    *audio=-1; *subtitle=-2;
    if(title<1 || title>d->vmg->tt_srpt->nr_of_srpts ||
       dvdnav_current_title_program(d->nav,&current,&pgcn,&pgn)!=DVDNAV_STATUS_OK) return;
    int vtsn=d->vmg->tt_srpt->title[title-1].title_set_nr;
    ifo_handle_t *vts=ifoOpen(d->reader,vtsn);
    if(!vts) return;
    AVFormatContext *map=NULL;
    if(!vts->vtsi_mat || !vts->vts_pgcit || pgcn<1 || pgcn>vts->vts_pgcit->nr_of_pgci_srp) goto done;
    map=avformat_alloc_context();
    if(!map) goto done;
    DVDVideoDemuxContext context={0};
    context.vts_ifo=vts; context.play_state.pgc=vts->vts_pgcit->pgci_srp[pgcn-1].pgc;
    map->priv_data=&context;
    if(!context.play_state.pgc || dvdvideo_audio_stream_add_all(map)<0 || dvdvideo_subp_stream_add_all(map)<0) goto done;
    int physical=dvdnav_get_active_audio_stream(d->nav);
    audio_attr_t attr={0}; DVDVideoPGCAudioStreamEntry entry={0};
    int logical=dvdnav_get_audio_logical_stream(d->nav,physical);
    int audio_id=-1,spu=dvdnav_get_active_spu_stream(d->nav);
    if(physical>=0 && logical>=0 && dvdnav_get_audio_attr(d->nav,logical,&attr)==DVDNAV_STATUS_OK &&
       dvdvideo_audio_stream_analyze(map,attr,physical<<8,&entry)>=0) audio_id=entry.startcode;
    int audio_n=0,sub_n=0;
    for(unsigned i=0;i<map->nb_streams;i++) {
        AVStream *st=map->streams[i];
        if(st->codecpar->codec_type==AVMEDIA_TYPE_AUDIO) { if(st->id==audio_id) *audio=audio_n; audio_n++; }
        if(st->codecpar->codec_type==AVMEDIA_TYPE_SUBTITLE) { if(spu>=0 && !(spu&0x80) && st->id==0x20+(spu&31)) *subtitle=sub_n; sub_n++; }
    }
done:
    if(map) { map->priv_data=NULL; avformat_free_context(map); }
    ifoClose(vts);
}

static void menu_location(ThruDvd *d)
{
    int title=0, chapter=0;
    dvdnav_current_title_info(d->nav,&title,&chapter);
    int in_menu=!dvdnav_is_domain_vts(d->nav);
    int64_t at=0;
    for(int i=0;i<d->count;i++) if(d->titles[i].number==title && chapter>1 && chapter<=d->titles[i].chapters)
        at=d->titles[i].ends[chapter-2]/90;
    int audio=d->audio_index,subtitle=d->subtitle_index;
    if(!in_menu && (d->in_menu || title!=d->title)) title_track_choices(d,title,&audio,&subtitle);
    pthread_mutex_lock(&dvd_data_lock);
    d->title=title; d->chapter=chapter; d->in_menu=in_menu; d->chapter_ms=at;
    d->audio_index=audio; d->subtitle_index=subtitle;
    if(in_menu && d->pci.hli.hl_gi.btn_ns) d->seen=1;
    pthread_mutex_unlock(&dvd_data_lock);
}

static int call_menu(ThruDvd *d)
{
    int ok=dvdnav_menu_call(d->nav,DVD_MENU_Root);
    if(ok!=DVDNAV_STATUS_OK) ok=dvdnav_menu_call(d->nav,DVD_MENU_Title);
    return ok;
}

static void menu_commands(ThruDvd *d)
{
    for(;;) {
        pthread_mutex_lock(&dvd_data_lock);
        if(dvd_head==dvd_tail) { pthread_mutex_unlock(&dvd_data_lock); break; }
        int kind=dvd_commands[dvd_head%32].kind, x=dvd_commands[dvd_head%32].x, y=dvd_commands[dvd_head%32].y;
        dvd_head++;
        pthread_mutex_unlock(&dvd_data_lock);
        if(kind==7 || kind==8) { call_menu(d); d->still_until=0; continue; }
        if(kind<0 || kind>1) continue;
        /* Never activate a previously selected button when the ray misses. */
        int hit=0;
        for(int b=1;b<=FFMIN(36,d->pci.hli.hl_gi.btn_ns);b++) {
            dvdnav_highlight_area_t a={0};
            if(dvdnav_get_highlight_area(&d->pci,b,0,&a)==DVDNAV_STATUS_OK &&
                x>=a.sx && x<=a.ex && y>=a.sy && y<=a.ey) { hit=b; break; }
        }
        if(!hit) continue;
        if(kind==0) dvdnav_button_select(d->nav,&d->pci,hit);
        else { dvdnav_button_select_and_activate(d->nav,&d->pci,hit); d->still_until=0; }
        menu_publish(d);
    }
}

static int menu_read(void *opaque,uint8_t *buffer,int size)
{
    ThruDvd *d=opaque;
    if(size<2048) return AVERROR(EINVAL);
    /* AVIO retries EOF while checking its buffer. Keep the boundary sticky
     * until the enclosing demuxer has drained every packet in this VOBU. */
    if(d->reset) return AVERROR_EOF;
    for(;;) {
        if(ff_check_interrupt(&d->outer->interrupt_callback)) return AVERROR_EXIT;
        menu_commands(d);
        if(d->eof) return AVERROR_EOF;
        /* A menu selection is handed to ordinary title playback by Godot.
         * Keep the menu's last picture while that reopen is being scheduled. */
        if(d->seen && dvdnav_is_domain_vts(d->nav)) {
            menu_location(d); av_usleep(10000); continue;
        }
        int event=0,len=0;
        uint8_t block[2048];
        if(dvdnav_get_next_block(d->nav,block,&event,&len)!=DVDNAV_STATUS_OK) {
            pthread_mutex_lock(&dvd_data_lock); d->error=1; pthread_mutex_unlock(&dvd_data_lock);
            return AVERROR(EIO);
        }
        if(len<0 || len>2048) return AVERROR_INVALIDDATA;
        switch(event) {
        case DVDNAV_BLOCK_OK:
            if(len!=2048) return AVERROR_INVALIDDATA;
            memcpy(buffer,block,2048); return 2048;
        case DVDNAV_NAV_PACKET: {
            pci_t *pci=dvdnav_get_current_nav_pci(d->nav);
            if(!pci) return AVERROR_INVALIDDATA;
            d->pci=*pci;
            int64_t start=pci->pci_gi.vobu_s_ptm, end=pci->pci_gi.vobu_e_ptm;
            int previous=d->started;
            int boundary=previous && (d->boundary || start!=d->last_end);
            if(!d->started || boundary) d->epoch_offset=d->epoch_end-start;
            d->epoch_end=FFMAX(d->epoch_end,end+d->epoch_offset);
            d->last_end=end; d->started=1; d->boundary=0;
            menu_location(d); menu_publish(d);
            /* Finish each VOBU before the next one. Static DVD menu images
             * may be one picture followed by many seconds of audio; waiting
             * for another picture start would hide the menu until it exits. */
            if(previous) { d->reset=1; return AVERROR_EOF; }
            d->packet_offset=d->epoch_offset;
            d->packet_time=start+d->epoch_offset; d->packet_end=d->epoch_end;
            break;
        }
        case DVDNAV_SPU_CLUT_CHANGE:
            if(len>=64) memcpy(d->clut,block,64);
            menu_publish(d); break;
        case DVDNAV_SPU_STREAM_CHANGE:
            if(len<(int)sizeof(dvdnav_spu_stream_change_event_t)) return AVERROR_INVALIDDATA;
            d->spu_stream=((dvdnav_spu_stream_change_event_t*)block)->physical_wide & 31;
            pthread_mutex_lock(&dvd_data_lock);
            d->subtitle_index=(((dvdnav_spu_stream_change_event_t*)block)->physical_wide & 128) ? -2 :
                dvdnav_get_spu_logical_stream(d->nav,d->spu_stream);
            pthread_mutex_unlock(&dvd_data_lock);
            break;
        case DVDNAV_AUDIO_STREAM_CHANGE:
            if(len<(int)sizeof(dvdnav_audio_stream_change_event_t)) return AVERROR_INVALIDDATA;
            pthread_mutex_lock(&dvd_data_lock);
            d->audio_index=dvdnav_get_audio_logical_stream(d->nav,((dvdnav_audio_stream_change_event_t*)block)->physical);
            pthread_mutex_unlock(&dvd_data_lock); break;
        case DVDNAV_HIGHLIGHT: menu_publish(d); break;
        case DVDNAV_VTS_CHANGE:
        case DVDNAV_CELL_CHANGE:
        case DVDNAV_HOP_CHANNEL:
            d->spu_visible=0; d->boundary=1; d->still_until=0;
            memset(&d->pci,0,sizeof(d->pci)); menu_location(d); menu_publish(d); break;
        case DVDNAV_STILL_FRAME: {
            if(len<(int)sizeof(dvdnav_still_event_t)) return AVERROR_INVALIDDATA;
            int seconds=((dvdnav_still_event_t*)block)->length;
            if(!d->still_until) d->still_until=seconds==255 ? INT64_MAX : av_gettime_relative()+seconds*1000000LL;
            if(av_gettime_relative()>=d->still_until) { dvdnav_still_skip(d->nav); d->still_until=0; }
            else av_usleep(10000);
            break;
        }
        case DVDNAV_WAIT:
            dvdnav_wait_skip(d->nav); d->reset=1; return AVERROR_EOF;
        case DVDNAV_STOP: d->eof=1; return AVERROR_EOF;
        default: break;
        }
    }
}

static void menu_transport_close(ThruDvd *d)
{
    avformat_close_input(&d->inner);
    if(d->mpeg_io) { av_freep(&d->mpeg_io->buffer); avio_context_free(&d->mpeg_io); }
}

static int menu_transport_open(ThruDvd *d)
{
    uint8_t *buffer=av_malloc(2048);
    if(!buffer) return AVERROR(ENOMEM);
    d->mpeg_io=avio_alloc_context(buffer,2048,0,d,menu_read,NULL,NULL);
    if(!d->mpeg_io) { av_free(buffer); return AVERROR(ENOMEM); }
    d->inner=avformat_alloc_context();
    if(!d->inner) return AVERROR(ENOMEM);
    d->inner->pb=d->mpeg_io; d->inner->flags=AVFMT_FLAG_CUSTOM_IO;
    d->inner->probesize=0; d->inner->max_analyze_duration=0;
    d->inner->interrupt_callback=d->outer->interrupt_callback;
    d->mpeg_io->seekable=0;
    int ret=avformat_open_input(&d->inner,"",av_find_input_format("mpeg"),NULL);
    if(ret<0) return ret;
    for(unsigned i=0;i<d->outer->nb_streams;i++) {
        AVStream *st=avformat_new_stream(d->inner,NULL);
        if(!st) return AVERROR(ENOMEM);
        if((ret=avcodec_parameters_copy(st->codecpar,d->outer->streams[i]->codecpar))<0) return ret;
        st->id=d->outer->streams[i]->id;
        avpriv_set_pts_info(st,32,1,90000);
        ffstream(st)->need_parsing=st->codecpar->codec_type==AVMEDIA_TYPE_VIDEO ? AVSTREAM_PARSE_NONE : AVSTREAM_PARSE_FULL;
    }
    return 0;
}

static int copy_streams(ThruDvd *d)
{
    for(unsigned i=0;i<d->inner->nb_streams;i++) {
        AVStream *src=d->inner->streams[i];
        if(d->menu && src->codecpar->codec_type==AVMEDIA_TYPE_SUBTITLE) continue;
        unsigned j;
        for(j=0;j<d->outer->nb_streams;j++) if(d->outer->streams[j]->id==src->id) break;
        if(j<d->outer->nb_streams) continue;
        if(d->outer->nb_streams>=48) return AVERROR_INVALIDDATA;
        AVStream *out=avformat_new_stream(d->outer,NULL);
        if(!out) return AVERROR(ENOMEM);
        int ret=avcodec_parameters_copy(out->codecpar,src->codecpar);
        if(ret<0) return ret;
        out->id=src->id; out->disposition=src->disposition;
        out->sample_aspect_ratio=src->sample_aspect_ratio;
        out->avg_frame_rate=src->avg_frame_rate;
        avpriv_set_pts_info(out,32,1,90000);
        av_dict_copy(&out->metadata,src->metadata,0);
        ffstream(out)->need_parsing=AVSTREAM_PARSE_HEADERS;
        ffstream(out)->display_aspect_ratio=ffstream(src)->display_aspect_ratio;
    }
    return 0;
}

int thru_dvd_open(ThruDvd **out, AVFormatContext *outer, void *source,
                 int (*blocks)(void *,void *,int,int),int title,int menu,int header_only)
{
    ThruDvd *d=av_mallocz(sizeof(*d));
    if(!d) return AVERROR(ENOMEM);
    *out=d; d->outer=outer; d->selected=-1; d->menu=menu;
    d->audio_index=d->subtitle_index=-1;
    d->io=(DvdIO){.context=outer,.source=source,.blocks=blocks}; d->nav_io=d->io;
    dvd_logger_cb log={quiet_dvdread}; dvdnav_logger_cb navlog={quiet_dvdnav};
    d->reader=DVDOpenStream2(&d->io,&log,&dvd_io_callbacks);
    if(!d->reader || !(d->vmg=ifoOpen(d->reader,0))) {
        thru_dvd_close(out);
        return ff_check_interrupt(&outer->interrupt_callback) ? AVERROR_EXIT : 0;
    }
    if(dvdnav_open_stream2(&d->nav,&d->nav_io,&navlog,&dvd_io_callbacks)!=DVDNAV_STATUS_OK) return AVERROR_INVALIDDATA;
    dvdnav_set_readahead_flag(d->nav,0); dvdnav_set_PGC_positioning_flag(d->nav,1);
    int ret=title_scan(d,title);
    if(ret<0) return ret;
    if(header_only) return 1;
    if(menu) {
        if(!d->has_menu) return AVERROR_STREAM_NOT_FOUND;
        d->plane=av_mallocz(DVD_PLANE*4);
        if(!d->plane) return AVERROR(ENOMEM);
        dvdnav_title_play(d->nav,d->titles[d->selected].number);
        if(call_menu(d)!=DVDNAV_STATUS_OK) return AVERROR_INVALIDDATA;
        uint32_t w=0,h=0;
        dvdnav_get_video_resolution(d->nav,&w,&h);
        if(w>0 && w<=720 && h>0 && h<=576) { d->width=w; d->height=h; }
        outer->duration=AV_NOPTS_VALUE;
        AVStream *video=avformat_new_stream(outer,NULL);
        if(!video) return AVERROR(ENOMEM);
        video->id=0x1e0; video->codecpar->codec_type=AVMEDIA_TYPE_VIDEO;
        video->codecpar->codec_id=AV_CODEC_ID_MPEG2VIDEO;
        video->codecpar->width=d->width; video->codecpar->height=d->height;
        video->sample_aspect_ratio=av_mul_q(dvdnav_get_video_aspect(d->nav)==3 ? (AVRational){16,9} : (AVRational){4,3}, (AVRational){d->height,d->width});
        video->codecpar->sample_aspect_ratio=video->sample_aspect_ratio;
        video->avg_frame_rate=d->height==576 ? (AVRational){25,1} : (AVRational){30000,1001};
        ffstream(video)->need_parsing=AVSTREAM_PARSE_FULL;
        avpriv_set_pts_info(video,32,1,90000);
        for(int i=0;i<8;i++) {
            audio_attr_t attr={0}; DVDVideoPGCAudioStreamEntry entry={0};
            int logical=dvdnav_get_audio_logical_stream(d->nav,i);
            if(logical<0 || dvdnav_get_audio_attr(d->nav,logical,&attr)!=DVDNAV_STATUS_OK) continue;
            if(dvdvideo_audio_stream_analyze(outer,attr,i<<8,&entry)>=0 &&
                (ret=dvdvideo_audio_stream_add(outer,&entry))<0) return ret;
        }
        outer->ctx_flags|=AVFMTCTX_UNSEEKABLE;
        av_dict_set(&outer->metadata,"thru3d_disc_menu","1",0);
        pthread_mutex_lock(&dvd_data_lock);
        if(dvd_menu) { pthread_mutex_unlock(&dvd_data_lock); return AVERROR(EBUSY); }
        dvd_menu=d; dvd_head=dvd_tail=0; d->version=++dvd_version;
        pthread_mutex_unlock(&dvd_data_lock);
        ret=menu_transport_open(d);
    } else {
        dvdnav_close(d->nav); d->nav=NULL;
        d->inner=avformat_alloc_context();
        if(!d->inner) return AVERROR(ENOMEM);
        d->inner->pb=outer->pb; d->inner->flags=AVFMT_FLAG_CUSTOM_IO;
        d->inner->interrupt_callback=outer->interrupt_callback;
        d->inner->opaque=&d->io;
        AVDictionary *opts=NULL;
        av_dict_set_int(&opts,"title",d->titles[d->selected].number,0);
        av_dict_set(&opts,"trim","0",0);
        ret=avformat_open_input(&d->inner,"",&ff_thru3d_dvd_title_demuxer.p,&opts);
        av_dict_free(&opts);
        if(ret>=0) ret=copy_streams(d);
        if(ret>=0) for(unsigned i=0;i<d->inner->nb_chapters;i++) {
            AVChapter *c=d->inner->chapters[i];
            if(!avpriv_new_chapter(outer,c->id,c->time_base,c->start,c->end,NULL)) return AVERROR(ENOMEM);
        }
    }
    outer->start_time=0;
    return ret<0 ? ret : 1;
}

void thru_dvd_close(ThruDvd **ptr)
{
    ThruDvd *d=*ptr;
    if(!d) return;
    pthread_mutex_lock(&dvd_data_lock);
    if(dvd_menu==d) { dvd_menu=NULL; dvd_head=dvd_tail=0; ++dvd_version; }
    pthread_mutex_unlock(&dvd_data_lock);
    menu_transport_close(d);
    if(d->nav) dvdnav_close(d->nav);
    if(d->vmg) ifoClose(d->vmg);
    if(d->reader) DVDClose(d->reader);
    for(int i=0;i<d->count;i++) free(d->titles[i].ends);
    av_packet_free(&d->video_unit);
    av_packet_free(&d->still_picture);
    av_free(d->spu); av_free(d->plane); av_freep(ptr);
}

/* A complete static-menu VOBU contains one I picture with its sequence header.
 * It has no B pictures to reorder. Signal low delay only for that unit and
 * terminate the elementary sequence so both parsers and the decoder present
 * it immediately. Multi-picture animation is passed through unchanged. */
static int finish_menu_video(AVPacket *packet)
{
    int pictures=0, sequence=0, intra=0;
    for(int i=0;i+8<packet->size;i++) {
        unsigned code=AV_RB32(packet->data+i);
        if(code==0x000001b3) sequence=1;
        if(code==0x00000100) { pictures++; intra=((packet->data[i+5]>>3)&7)==1; }
    }
    av_log(NULL,AV_LOG_DEBUG,"DVD menu VOBU video %d bytes %d pictures sequence %d intra %d\n",packet->size,pictures,sequence,intra);
    if(pictures!=1 || !sequence || !intra) return 0;
    for(int i=0;i+10<=packet->size;i++)
        if(AV_RB32(packet->data+i)==0x000001b5 && (packet->data[i+4]>>4)==1)
            packet->data[i+9]|=0x80; /* sequence_extension.low_delay */
    int size=packet->size;
    int ret=av_grow_packet(packet,4);
    if(ret<0) return ret;
    AV_WB32(packet->data+size,0x000001b7);
    return 1;
}

int thru_dvd_packet(ThruDvd *d,AVPacket *pkt)
{
    for(;;) {
        if(d->menu && !d->inner) {
            int ret=menu_transport_open(d); if(ret<0) return ret;
        }
        int ret=av_read_frame(d->inner,pkt);
        if(ret<0) {
            if(d->menu && d->reset && ret==AVERROR_EOF) {
                d->reset=0; menu_transport_close(d);
                if(d->video_unit && d->video_unit->size) {
                    av_packet_move_ref(pkt,d->video_unit);
                    if(pkt->pts!=AV_NOPTS_VALUE) pkt->pts+=d->packet_offset;
                    if(pkt->dts!=AV_NOPTS_VALUE) pkt->dts+=d->packet_offset;
                    ret=finish_menu_video(pkt);
                    if(ret<0) return ret;
                    av_packet_free(&d->still_picture);
                    if(ret>0 && !(d->still_picture=av_packet_clone(pkt))) return AVERROR(ENOMEM);
                } else if(d->still_picture) {
                    /* A still background followed by audio-only VOBUs must
                     * still advance the video queue. Otherwise mpv keeps
                     * searching for a second frame and reads the entire menu
                     * ahead, executing its post-command before it is shown. */
                    if((ret=av_packet_ref(pkt,d->still_picture))<0) return ret;
                    pkt->pts=pkt->dts=d->packet_time;
                    pkt->duration=FFMAX(1,d->packet_end-d->packet_time);
                }
                d->packet_offset=d->epoch_offset;
                d->packet_time=d->last_end+d->epoch_offset;
                /* A NAV boundary already describes the following VOBU. */
                if(d->pci.pci_gi.vobu_e_ptm==d->last_end)
                    d->packet_time=d->pci.pci_gi.vobu_s_ptm+d->epoch_offset;
                d->packet_end=d->epoch_end;
                if(pkt->size) return 0;
                continue;
            }
            return ret;
        }
        AVStream *src=d->inner->streams[pkt->stream_index];
        if(d->menu && src->codecpar->codec_type==AVMEDIA_TYPE_VIDEO) {
            if(!d->video_unit) d->video_unit=av_packet_alloc();
            if(!d->video_unit) { av_packet_unref(pkt); return AVERROR(ENOMEM); }
            int size=d->video_unit->size;
            if(pkt->size>8*1024*1024-size) { av_packet_unref(pkt); return AVERROR_INVALIDDATA; }
            if((ret=av_grow_packet(d->video_unit,pkt->size))<0) { av_packet_unref(pkt); return ret; }
            memcpy(d->video_unit->data+size,pkt->data,pkt->size);
            if(!size) { d->video_unit->pts=pkt->pts; d->video_unit->dts=pkt->dts; d->video_unit->stream_index=0; }
            av_packet_unref(pkt); continue;
        }
        if(d->menu && src->codecpar->codec_type==AVMEDIA_TYPE_SUBTITLE) {
            if((src->id&31)==d->spu_stream && spu_decode(d,pkt->data,pkt->size)>=0) menu_publish(d);
            av_packet_unref(pkt); continue;
        }
        if((ret=copy_streams(d))<0) { av_packet_unref(pkt); return ret; }
        int mapped=-1;
        for(unsigned i=0;i<d->outer->nb_streams;i++) if(d->outer->streams[i]->id==src->id) { mapped=i; break; }
        if(mapped<0) { av_packet_unref(pkt); continue; }
        av_packet_rescale_ts(pkt,src->time_base,d->outer->streams[mapped]->time_base);
        pkt->stream_index=mapped; pkt->pos=-1;
        if(d->menu) {
            if(pkt->pts!=AV_NOPTS_VALUE) pkt->pts+=d->packet_offset;
            if(pkt->dts!=AV_NOPTS_VALUE) pkt->dts+=d->packet_offset;
        }
        return 0;
    }
}

int thru_dvd_seek(ThruDvd *d,int stream,int64_t timestamp,int flags)
{
    if(d->menu) return AVERROR(ENOSYS);
    if(stream<0 || stream>=(int)d->outer->nb_streams) return AVERROR(EINVAL);
    av_log(d->outer,AV_LOG_DEBUG,"DVD title seek stream=%d timestamp=%"PRId64" flags=%d\n",stream,timestamp,flags);
    return av_seek_frame(d->inner,stream,FFMAX(0,timestamp),flags);
}

int thru_dvd_info(ThruDvd *d,int *width,int *height,int *selected,char *json,int capacity)
{
    *width=d->width; *height=d->height; *selected=d->titles[d->selected].number;
    if(!json) return 0;
    int at=snprintf(json,capacity,"{\"disc_type\":\"dvd\",\"menu\":\"%s\",\"titles\":[",d->has_menu?"dvd":"none");
    if(at<0 || at>=capacity) return AVERROR(ENOSPC);
    for(int i=0;i<d->count;i++) {
        DvdTitle *t=&d->titles[i];
        int n=snprintf(json+at,capacity-at,"%s{\"playlist\":%d,\"dvd_title\":%d,\"duration_ms\":%"PRId64",\"chapters\":%d,\"height\":%d,\"audio\":%d,\"subtitles\":%d,\"angles\":%d,\"stereo\":false}",
            i?",":"",t->number,t->number,t->duration/90,t->chapters,t->height,t->audio,t->subtitles,t->angles);
        if(n<0 || n>=capacity-at) return AVERROR(ENOSPC);
        at+=n;
    }
    if(capacity-at<3) return AVERROR(ENOSPC);
    memcpy(json+at,"]}",3); return 0;
}

int thru_dvd_menu_state(char *json,int capacity)
{
    pthread_mutex_lock(&dvd_data_lock);
    ThruDvd *d=dvd_menu;
    int n=0;
    if(d) n=snprintf(json,capacity,"{\"active\":true,\"version\":%"PRIu64",\"width\":%d,\"height\":%d,\"title\":%d,\"playlist\":%d,\"chapter\":%d,\"chapter_ms\":%"PRId64",\"menu\":%s,\"seen\":%s,\"buttons\":%s,\"error\":%s,\"audio_index\":%d,\"subtitle_index\":%d}",
        d->version,d->width,d->height,d->title,d->title,d->chapter,d->chapter_ms,d->in_menu?"true":"false",d->seen?"true":"false",d->x1>d->x0?"true":"false",d->error?"true":"false",d->audio_index,d->subtitle_index);
    pthread_mutex_unlock(&dvd_data_lock);
    return n>=capacity ? AVERROR(ENOSPC) : n;
}

int thru_dvd_menu_overlay(uint64_t version,uint8_t *rgba,int capacity,int *rect)
{
    int ret=0;
    pthread_mutex_lock(&dvd_data_lock);
    ThruDvd *d=dvd_menu;
    if(!d || d->version!=version) { ret=AVERROR(EAGAIN); goto done; }
    int w=d->x1-d->x0,h=d->y1-d->y0;
    if(w<=0 || h<=0) goto done;
    if((int64_t)w*h*4>capacity) { ret=AVERROR(ENOSPC); goto done; }
    rect[0]=d->x0;rect[1]=d->y0;rect[2]=w;rect[3]=h;rect[4]=d->width;rect[5]=d->height;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        uint32_t p=d->plane[(y+d->y0)*d->width+x+d->x0],a=p>>24;
        uint8_t *v=rgba+(y*w+x)*4;
        v[0]=((p>>16&255)*a+127)/255; v[1]=((p>>8&255)*a+127)/255;
        v[2]=((p&255)*a+127)/255; v[3]=a;
    }
    ret=w*h*4;
done:
    pthread_mutex_unlock(&dvd_data_lock); return ret;
}

int thru_dvd_menu_input(int kind,int x,int y)
{
    pthread_mutex_lock(&dvd_data_lock);
    int ret=-1;
    if(dvd_menu && dvd_tail-dvd_head<32 && (kind==0 || kind==1 || kind==7 || kind==8)) {
        dvd_commands[dvd_tail%32].kind=kind; dvd_commands[dvd_tail%32].x=x; dvd_commands[dvd_tail%32].y=y;
        dvd_tail++; ret=1;
    }
    pthread_mutex_unlock(&dvd_data_lock); return ret;
}
