/* Host fixture using the actual pinned protocol handlers. No APK or headset. */
#include <stdio.h>
#include <string.h>
#include "raop.h"
#include "logger.h"
#include "raop_rtp_mirror.h"
#include "../airplay_profile.h"

static void video(void *ctx, raop_ntp_t *ntp, video_decode_struct *packet) {}
static void audio(void *ctx, raop_ntp_t *ntp, audio_decode_struct *packet) {}
static double initial_volume(void *ctx) { return 0.0; }
static void log_error(void *ctx, int level, const char *message);
static const char *password(void *ctx, int *length) {
    return airplay_access_password(*(int *)ctx, length);
}
static void show_pin(void *ctx, char *value) {
    /* Synthetic host-only code, sent over the fixture pipe, never a device credential. */
    printf("PIN %s\n", value); fflush(stdout);
}
static void deny_media(void *ctx, char *id, char *model, char *name, bool *allowed) {
    *allowed = false; /* Stop after access control; this fixture does not stream media. */
}
static int mirror_codec(void *ctx, video_codec_t codec) { return codec == VIDEO_CODEC_H264 ? 0 : -1; }
static void mirror_packet(void *ctx, raop_ntp_t *ntp, video_decode_struct *packet) {
    int sps = 0, pps = 0, idr = 0;
    for (int i = 0; i + 4 < packet->data_len; ++i) {
        if (!memcmp(packet->data + i, "\0\0\0\1", 4)) {
            int type = packet->data[i + 4] & 31;
            sps += type == 7; pps += type == 8; idr += type == 5;
        }
    }
    printf("VIDEO %d %d %d %d\n", packet->data[0] != 0, sps, pps, idr); fflush(stdout);
}
static int mirror_fixture(void) {
    logger_t *log = logger_init();
    logger_set_callback(log, log_error, NULL); logger_set_level(log, LOGGER_ERR);
    raop_callbacks_t callbacks = {0};
    callbacks.video_process = mirror_packet; callbacks.video_set_codec = mirror_codec;
    char remote[] = "127.0.0.1";
    unsigned char key[16]; for (int i = 0; i < 16; ++i) key[i] = i;
    timing_protocol_t timing = TP_NONE;
    raop_ntp_t *ntp = raop_ntp_init(log, &callbacks, remote, 4, 0, &timing);
    raop_rtp_mirror_t *mirror = raop_rtp_mirror_init(log, &callbacks, ntp, remote, 4, key);
    uint64_t connection = 7; raop_rtp_mirror_init_aes(mirror, &connection);
    unsigned short port = 0; raop_rtp_mirror_start(mirror, &port, 0);
    printf("%u\n", port); fflush(stdout);
    getchar();
    raop_rtp_mirror_destroy(mirror); raop_ntp_destroy(ntp); logger_destroy(log);
    return 0;
}
static void log_error(void *ctx, int level, const char *message) {
    if (level <= LOGGER_ERR) fprintf(stderr, "%s\n", message);
}
static const char *txt(dnssd_t *dns, int airplay, const char *key) {
    int count = airplay ? android_dnssd_get_airplay_txt_count(dns) : android_dnssd_get_raop_txt_count(dns);
    for (int i = 0; i < count; ++i) {
        const char *name = airplay ? android_dnssd_get_airplay_txt_key(dns, i) : android_dnssd_get_raop_txt_key(dns, i);
        if (!strcmp(name, key)) return airplay ? android_dnssd_get_airplay_txt_val(dns, i) : android_dnssd_get_raop_txt_val(dns, i);
    }
    return "missing";
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--mirror")) return mirror_fixture();
    if (argc < 2 || argc > 3 || (argc == 3 && strcmp(argv[2], "--pin") && strcmp(argv[2], "--password"))) return 2;
    const int require_pin = argc == 3 && !strcmp(argv[2], "--pin");
    int require_password = argc == 3 && !strcmp(argv[2], "--password");
    raop_callbacks_t callbacks = {0};
    callbacks.cls = &require_password;
    callbacks.video_process = video;
    callbacks.audio_process = audio;
    callbacks.audio_set_client_volume = initial_volume;
    callbacks.passwd = password;
    callbacks.display_pin = show_pin;
    callbacks.report_client_request = deny_media;
    raop_t *server = raop_init(&callbacks);
    if (!server) return 3;
    raop_set_log_callback(server, log_error, NULL);
    raop_set_log_level(server, LOGGER_ERR);
    if (raop_init2(server, 0, "02:00:00:00:00:01", argv[1]) < 0) return 4;
    char address[6] = {2, 0, 0, 0, 0, 1};
    int dns_error = 0;
    dnssd_t *dns = dnssd_init("ProtocolTest", 12, address, 6, &dns_error, require_pin ? 1 : airplay_access_mode(require_password));
    if (!dns) return 6;
    airplay_configure_profile(server, dns);
    raop_set_dnssd(server, dns);
    if (require_pin) raop_set_plist(server, "pin", 14321);
    unsigned short port = 0;
    if (raop_start_httpd(server, &port) < 0) return 5;
    dnssd_register_raop(dns, port);
    dnssd_register_airplay(dns, port);
    printf("%u\n", port);
    printf("raop_pw=%s airplay_pw=%s raop_sf=%s\n", txt(dns, 0, "pw"), txt(dns, 1, "pw"), txt(dns, 0, "sf"));
    fflush(stdout);
    getchar();
    raop_stop_httpd(server);
    raop_destroy(server);
    dnssd_destroy(dns);
    return 0;
}
