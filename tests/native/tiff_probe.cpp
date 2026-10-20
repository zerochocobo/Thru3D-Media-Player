#include "../../native/tiff/tiff_image.h"
#include <cstdio>
#include <fstream>
#include <sys/resource.h>
int main(int argc, char **argv) {
    try {
        if (argc < 3) return 2;
        const auto info = thru::tiff_info(argv[1]);
        const int sample = argc > 3 ? std::stoi(argv[3]) : 1;
        const int left = argc > 4 ? std::stoi(argv[4]) : 0, top = argc > 5 ? std::stoi(argv[5]) : 0;
        const int width = argc > 6 ? std::stoi(argv[6]) : info.width;
        const int height = argc > 7 ? std::stoi(argv[7]) : info.height;
        auto rgba = thru::tiff_pixels(argv[1], left, top, width, height, sample, [] {}, argc > 8 ? argv[8] : "");
        std::ofstream out(argv[2], std::ios::binary); out.write(reinterpret_cast<char *>(rgba.data()), rgba.size());
        rusage usage = {}; getrusage(RUSAGE_SELF, &usage);
        std::printf("%d %d orientation=%d bytes=%zu maxrss_kb=%ld\n", info.width, info.height, info.orientation, rgba.size(), usage.ru_maxrss);
        return out.good() ? 0 : 3;
    } catch (...) { std::puts("TIFF_FAILED"); return 1; }
}
