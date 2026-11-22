// Host regression for the Profile 5 frame predicate shared by libmpv's decoder
// import, frame ticket and GPU renderer (native/mpv/dovi/quest_dovi_profile.h).
#undef NDEBUG // These checks must also run in Release configurations.
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
#include <libavutil/buffer.h>

struct mp_ff_side_data { enum AVFrameSideDataType type; AVBufferRef *buf; };
struct mp_image {
    AVBufferRef *dovi;
    bool quest_dovi_profile5_hw;
    int num_ff_side_data;
    struct mp_ff_side_data *ff_side_data;
};
#include "dovi/quest_dovi_profile.h"

int main(void)
{
    // MediaCodec Profile 5 frames carry IPT_C2 only with their RPU attached.
    AVFrame frame = {.format = AV_PIX_FMT_MEDIACODEC, .colorspace = AVCOL_SPC_IPT_C2};
    assert(quest_dovi_profile5_hw_frame(&frame));
    frame.colorspace = AVCOL_SPC_BT2020_NCL; // Profile 8 base layer, ordinary HDR10.
    assert(!quest_dovi_profile5_hw_frame(&frame));
    frame.format = AV_PIX_FMT_YUV420P10LE;
    frame.colorspace = AVCOL_SPC_IPT_C2; // Software frames keep the in-band header test.
    assert(!quest_dovi_profile5_hw_frame(&frame));

    struct Metadata { AVDOVIMetadata meta; AVDOVIRpuDataHeader header; } metadata = {
        .meta.header_offset = offsetof(struct Metadata, header),
        .header = {.vdr_rpu_profile = 0, .bl_video_full_range_flag = 1, .disable_residual_flag = 1}
    };
    AVBufferRef buffer = {.data = (void *)&metadata, .size = sizeof(metadata)};
    struct mp_ff_side_data sd = {.type = AV_FRAME_DATA_DOVI_METADATA, .buf = &buffer};
    struct mp_image image = {.dovi = &buffer, .num_ff_side_data = 1, .ff_side_data = &sd};

    assert(quest_dovi_profile5(&image)); // Standard Profile 5 RPU header.
    const int standard = quest_dovi_signature(quest_dovi_state(&image));

    // The synthetic fixture header: an RPU outside the usual Profile 5 values.
    metadata.header.vdr_rpu_profile = 1;
    assert(!quest_dovi_profile5(&image)); // The header alone rejects it (the old judgment).
    image.quest_dovi_profile5_hw = true;
    assert(quest_dovi_profile5(&image)); // The decoder's marker keeps it.
    const int marked = quest_dovi_signature(quest_dovi_state(&image));
    assert(marked != standard);

    // The marker never stands in for metadata the renderer cannot map.
    struct mp_image unmapped = {.quest_dovi_profile5_hw = true};
    assert(!quest_dovi_profile5(&unmapped) && !quest_dovi_profile5(NULL));
    image.quest_dovi_profile5_hw = false;
    image.num_ff_side_data = 0;
    metadata.header.vdr_rpu_profile = 0;
    assert(!quest_dovi_profile5(&image));

    // Each lost link gives its own logged signature; non-Dolby frames log nothing.
    struct mp_image plain = {0};
    const int no_rpu = quest_dovi_signature(quest_dovi_state(&image));
    assert(quest_dovi_signature(quest_dovi_state(&plain)) == 0 &&
           quest_dovi_signature(quest_dovi_state(NULL)) == 0);
    assert(no_rpu && no_rpu != standard && no_rpu != marked);
    assert(quest_dovi_signature(quest_dovi_state(&unmapped)) != no_rpu);
    struct quest_dovi_state header = quest_dovi_state(&(struct mp_image){
        .dovi = &buffer, .num_ff_side_data = 1, .ff_side_data = &sd});
    assert(header.rpu && header.vdr_rpu_profile == 0 && header.full_range && header.disable_residual);
    puts("Dolby Vision Profile 5 frame predicate checks passed");
}
