/* Spatial metadata in the same render transaction as the selected stereo frame. */
#ifndef QUEST_SPATIAL_METADATA_H
#define QUEST_SPATIAL_METADATA_H
#include <math.h>
#include <string.h>
#include <libavutil/stereo3d.h>
#include "include/mpv/quest_frame.h"

static inline void quest_spatial_metadata_read(quest_mpv_spatial_metadata *out,
                                               const AVStereo3D *stereo)
{
    memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
    if (!stereo)
        return;
    if (stereo->baseline) {
        out->baseline_meters = stereo->baseline * 1e-6;
        out->flags |= QUEST_MPV_SPATIAL_BASELINE;
    }
    AVRational fov = stereo->horizontal_field_of_view;
    if (fov.den > 0) {
        double value = (double)fov.num / fov.den;
        if (isfinite(value) && value > 0 && value < 180) {
            out->horizontal_fov_degrees = value;
            out->flags |= QUEST_MPV_SPATIAL_FOV;
        }
    }
    AVRational disparity = stereo->horizontal_disparity_adjustment;
    if (disparity.den > 0) {
        double value = (double)disparity.num / disparity.den;
        if (isfinite(value) && fabs(value) <= 1) {
            out->horizontal_disparity = value;
            out->flags |= QUEST_MPV_SPATIAL_DISPARITY;
        }
    }
}
#endif
