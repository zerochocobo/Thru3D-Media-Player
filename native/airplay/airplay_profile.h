#ifndef THRU3D_AIRPLAY_PROFILE_H
#define THRU3D_AIRPLAY_PROFILE_H

#include "raop.h"
#include "android_dnssd_shim.h"

/* Password mode displays a fresh four-digit code for each connection (UxPlay -pw).
   Open mode keeps encrypted pairing, without requiring a user-entered code. */
static inline unsigned char airplay_access_mode(int required) { return required ? 3 : 0; }
static inline const char *airplay_access_password(int required, int *length) {
    *length = required ? -1 : 0;
    return NULL;
}

static inline void airplay_configure_profile(raop_t *raop, dnssd_t *dns) {
    /* A square limit preserves a 1920-pixel long edge for portrait as well as landscape. */
    raop_set_plist(raop, "width", 1920);
    raop_set_plist(raop, "height", 1920);
    raop_set_plist(raop, "maxFPS", 30);
    raop_set_plist(raop, "refreshRate", 30);
    raop_set_plist(raop, "hls", 0);
    android_dnssd_set_codecs(dns, 0, 1);
    /* This is mirror audio support, not an audio-only UI switch. Disabling bit 9
       makes iOS tear down video after ~60 seconds (UxPlay issue #303). */
    dnssd_set_airplay_features(dns, 9, 1);
    dnssd_set_airplay_features(dns, 42, 0); /* AVC, not HEVC */
    dnssd_set_airplay_features(dns, 0, 0);  /* no HLS/video casting */
    dnssd_set_airplay_features(dns, 4, 0);
}
#endif
