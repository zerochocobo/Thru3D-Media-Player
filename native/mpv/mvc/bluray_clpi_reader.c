/* Compile the unmodified pinned CLPI parser with a file-callback entry point.
 * Its normal public API requires a filesystem path, unavailable for Android
 * anonymous memory. This replaces exactly the original archive object.
 * libbluray and this adapter are LGPL-2.1-or-later. */
#include THRU3D_BLURAY_CLPI_SOURCE

CLPI_CL *thru3d_clpi_from_file(BD_FILE_H *file);
CLPI_CL *thru3d_clpi_from_file(BD_FILE_H *file)
{
    return _clpi_parse(file);
}
