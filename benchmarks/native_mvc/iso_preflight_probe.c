#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
extern int avformat_thru3d_bd_probe(const char *, int *, int *, int64_t *, int *);
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    int width = 0, height = 0, mvc = 0; int64_t duration = 0;
    int status = avformat_thru3d_bd_probe(argv[1], &width, &height, &duration, &mvc);
    if (status < 0 || width <= 0 || height <= 0 || duration <= 0) return 2;
    printf("{\"width\":%d,\"height\":%d,\"mvc\":%d,\"duration_us\":%" PRId64 "}\n", width, height, mvc, duration);
    return 0;
}
