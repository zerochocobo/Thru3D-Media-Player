/* Private DVD delegate for the existing optical-disc ABI. LGPL-2.1-or-later. */
#ifndef THRU3D_DVD_NAV_H
#define THRU3D_DVD_NAV_H
#include "avformat.h"
typedef struct ThruDvd ThruDvd;
/* 1: DVD, 0: not a DVD, negative: recognized but invalid/cancelled DVD. */
int thru_dvd_open(ThruDvd **dvd, AVFormatContext *outer, void *source,
                 int (*blocks)(void *, void *, int, int), int title, int menu, int header_only);
void thru_dvd_close(ThruDvd **dvd);
int thru_dvd_packet(ThruDvd *dvd, AVPacket *packet);
int thru_dvd_seek(ThruDvd *dvd, int stream, int64_t timestamp, int flags);
int thru_dvd_info(ThruDvd *dvd, int *width, int *height, int *selected, char *json, int capacity);
int thru_dvd_menu_state(char *json, int capacity);
int thru_dvd_menu_overlay(uint64_t version, uint8_t *rgba, int capacity, int *rect);
int thru_dvd_menu_input(int kind, int x, int y);
#endif
