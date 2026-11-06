/* Host fixture using the actual pinned protocol handlers. No APK or headset. */
#include <stdio.h>
#include "raop.h"
#include "logger.h"
#include "../airplay_profile.h"

static void video(void *ctx, raop_ntp_t *ntp, video_decode_struct *packet) {}
static void audio(void *ctx, raop_ntp_t *ntp, audio_decode_struct *packet) {}
static double initial_volume(void *ctx) { return 0.0; }
static void log_error(void *ctx, int level, const char *message) {
    if (level <= LOGGER_ERR) fprintf(stderr, "%s\n", message);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    raop_callbacks_t callbacks = {0};
    callbacks.video_process = video;
    callbacks.audio_process = audio;
    callbacks.audio_set_client_volume = initial_volume;
    raop_t *server = raop_init(&callbacks);
    if (!server) return 3;
    raop_set_log_callback(server, log_error, NULL);
    raop_set_log_level(server, LOGGER_ERR);
    if (raop_init2(server, 0, "02:00:00:00:00:01", argv[1]) < 0) return 4;
    char address[6] = {2, 0, 0, 0, 0, 1};
    int dns_error = 0;
    dnssd_t *dns = dnssd_init("ProtocolTest", 12, address, 6, &dns_error, 1);
    if (!dns) return 6;
    airplay_configure_profile(server, dns);
    raop_set_dnssd(server, dns);
    raop_set_plist(server, "pin", 14321);
    unsigned short port = 0;
    if (raop_start_httpd(server, &port) < 0) return 5;
    printf("%u\n", port);
    fflush(stdout);
    getchar();
    raop_stop_httpd(server);
    raop_destroy(server);
    dnssd_destroy(dns);
    return 0;
}
