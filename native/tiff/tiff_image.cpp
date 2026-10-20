#include "tiff_image.h"
#include <tiffio.h>
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <fstream>
#include <cstring>

namespace thru {
namespace {
using Image = std::unique_ptr<TIFF, decltype(&TIFFClose)>;
int quiet(TIFF *, void *, const char *, const char *, va_list) { return 1; }
Image open(const std::string &path) {
    auto *options = TIFFOpenOptionsAlloc();
    if (!options) throw std::runtime_error("TIFF options");
    TIFFOpenOptionsSetMaxSingleMemAlloc(options, 64 * 1024 * 1024);
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(options, 96 * 1024 * 1024);
    TIFFOpenOptionsSetErrorHandlerExtR(options, quiet, nullptr);
    TIFFOpenOptionsSetWarningHandlerExtR(options, quiet, nullptr);
    // Disable mmap: scanning a GB-sized mapped original otherwise makes its pages count
    // toward Android's resident memory even though the decoded bands are small.
    TIFF *image = TIFFOpenExt(path.c_str(), "rmC", options);
    TIFFOpenOptionsFree(options);
    if (!image) throw std::runtime_error("TIFF open");
    return Image(image, TIFFClose);
}
TiffInfo info(TIFF *image) {
    uint32_t w = 0, h = 0; uint16_t orientation = 1;
    if (!TIFFGetField(image, TIFFTAG_IMAGEWIDTH, &w) || !TIFFGetField(image, TIFFTAG_IMAGELENGTH, &h) ||
        w == 0 || h == 0 || w > 65535 || h > 65535 || uint64_t(w) * h > 1000000000)
        throw std::runtime_error("TIFF dimensions");
    TIFFGetFieldDefaulted(image, TIFFTAG_ORIENTATION, &orientation);
    char reason[1024] = {};
    if (!TIFFRGBAImageOK(image, reason)) throw std::runtime_error("TIFF format");
    uint16_t bits = 0, samples = 0, planar = 0, photo = 0;
    TIFFGetFieldDefaulted(image, TIFFTAG_BITSPERSAMPLE, &bits);
    TIFFGetFieldDefaulted(image, TIFFTAG_SAMPLESPERPIXEL, &samples);
    TIFFGetFieldDefaulted(image, TIFFTAG_PLANARCONFIG, &planar);
    TIFFGetField(image, TIFFTAG_PHOTOMETRIC, &photo);
    const bool scanlines = !TIFFIsTiled(image) && TIFFStripSize64(image) > 64 * 1024 * 1024 &&
        planar == PLANARCONFIG_CONTIG && (bits == 8 || bits == 16) &&
        ((photo == PHOTOMETRIC_RGB && samples == 3) ||
         ((photo == PHOTOMETRIC_MINISBLACK || photo == PHOTOMETRIC_MINISWHITE) && samples == 1));
    return {int(w), int(h), orientation >= 1 && orientation <= 8 ? orientation : 1, scanlines};
}

std::vector<uint8_t> scanlines(TIFF *image, const TiffInfo &size, int left, int top,
        int width, int height, int sample, const std::function<void()> &checkpoint, const std::string &cache) {
    uint16_t bits = 0, samples = 0, photo = 0;
    TIFFGetFieldDefaulted(image, TIFFTAG_BITSPERSAMPLE, &bits);
    TIFFGetFieldDefaulted(image, TIFFTAG_SAMPLESPERPIXEL, &samples);
    TIFFGetField(image, TIFFTAG_PHOTOMETRIC, &photo);
    const int ow = (width + sample - 1) / sample, oh = (height + sample - 1) / sample;
    std::vector<uint8_t> output(size_t(ow) * oh * 4);
    const uint64_t row_bytes = TIFFScanlineSize64(image);
    if (row_bytes == 0 || row_bytes > 4 * 1024 * 1024) throw std::runtime_error("TIFF row size");
    std::vector<uint8_t> input(size_t(row_bytes), 0), rgba(size_t(size.width) * 4);
    std::ofstream raw;
    if (!cache.empty()) {
        if (left || top || width != size.width || height != size.height) throw std::runtime_error("TIFF cache region");
        raw.open(cache, std::ios::binary | std::ios::trunc);
        uint8_t header[16] = {'T', '3', 'D', 'I'};
        for (int b = 0; b < 4; ++b) {
            header[4+b] = uint8_t(uint32_t(size.width) >> (8*b));
            header[8+b] = uint8_t(uint32_t(size.height) >> (8*b));
        }
        header[12] = 1;
        raw.write(reinterpret_cast<const char *>(header), sizeof(header));
        if (!raw) throw std::runtime_error("TIFF cache output");
    }
    for (int y = 0; y < top + height; ++y) {
        checkpoint();
        if (TIFFReadScanline(image, input.data(), uint32_t(y), 0) < 0) throw std::runtime_error("TIFF scanline");
        if (y < top || (!raw.is_open() && (y-top) % sample)) continue;
        auto value = [&](size_t i) -> uint8_t {
            if (bits == 8) return input[i];
            uint16_t v = 0; std::memcpy(&v, input.data() + i*2, 2);
            return photo == PHOTOMETRIC_RGB ? uint8_t((uint32_t(v)*255 + 32767)/65535) : uint8_t(v >> 8);
        };
        for (int x = 0; x < size.width; ++x) {
            const size_t at = size_t(x)*4;
            if (photo == PHOTOMETRIC_RGB) {
                rgba[at] = value(size_t(x)*samples); rgba[at+1] = value(size_t(x)*samples+1); rgba[at+2] = value(size_t(x)*samples+2);
            } else {
                auto gray = value(size_t(x));
                if (photo == PHOTOMETRIC_MINISWHITE) gray = uint8_t(255-gray);
                rgba[at] = rgba[at+1] = rgba[at+2] = gray;
            }
            rgba[at+3] = 255;
        }
        if (raw.is_open()) {
            raw.write(reinterpret_cast<const char *>(rgba.data()), rgba.size());
            if (!raw) throw std::runtime_error("TIFF cache output");
        }
        if ((y-top) % sample) continue;
        for (int x = 0; x < width; x += sample) {
            const size_t at = (size_t((y-top)/sample)*ow + x/sample)*4;
            std::memcpy(output.data()+at, rgba.data()+size_t(left+x)*4, 4);
        }
    }
    if (raw.is_open()) { raw.flush(); if (!raw) throw std::runtime_error("TIFF cache output"); }
    checkpoint();
    return output;
}
}
TiffInfo tiff_info(const std::string &path) { auto image = open(path); return info(image.get()); }

std::vector<uint8_t> tiff_pixels(const std::string &path, int left, int top, int width,
                                int height, int sample, const std::function<void()> &checkpoint, const std::string &cache) {
    auto image = open(path); const auto size = info(image.get());
    if (left < 0 || top < 0 || width < 1 || height < 1 || sample < 1 || sample > 65535 ||
        int64_t(left) + width > size.width || int64_t(top) + height > size.height)
        throw std::runtime_error("TIFF region");
    const int out_w = (width + sample - 1) / sample, out_h = (height + sample - 1) / sample;
    if (int64_t(out_w) * out_h > 8 * 1024 * 1024) throw std::runtime_error("TIFF output limit");
    if (size.scanlines) return scanlines(image.get(), size, left, top, width, height, sample, checkpoint, cache);
    std::vector<uint8_t> output(size_t(out_w) * out_h * 4);
    // Decode short bands. Even a GB-sized original never allocates a full decoded bitmap.
    // TIFF's strip-chopping mode also bounds uncompressed single-strip originals.
    TIFFSetField(image.get(), TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT);
    TIFFRGBAImage rgba = {}; char reason[1024] = {};
    if (!TIFFRGBAImageBegin(&rgba, image.get(), 1, reason)) throw std::runtime_error("TIFF decode begin");
    struct End { TIFFRGBAImage *rgba; ~End() { TIFFRGBAImageEnd(rgba); } } end{&rgba};
    rgba.req_orientation = ORIENTATION_TOPLEFT;
    const int band = 32;
    // Read full stored rows before cropping. libtiff's stripped 16-bit path applies
    // col_offset in bytes rather than samples; cropping here preserves exact pixels.
    std::vector<uint32_t> raster(size_t(size.width) * band);
    for (int y = 0; y < height; y += band) {
        checkpoint();
        const int rows = std::min(band, height - y);
        rgba.row_offset = top + y; rgba.col_offset = 0;
        if (!TIFFRGBAImageGet(&rgba, raster.data(), uint32_t(size.width), uint32_t(rows)))
            throw std::runtime_error("TIFF decode");
        for (int row = 0; row < rows; ++row) {
            if ((y + row) % sample) continue;
            for (int x = 0; x < width; x += sample) {
                const uint32_t pixel = raster[size_t(row) * size.width + left + x];
                const size_t at = (size_t((y + row) / sample) * out_w + x / sample) * 4;
                output[at] = TIFFGetR(pixel); output[at + 1] = TIFFGetG(pixel);
                output[at + 2] = TIFFGetB(pixel); output[at + 3] = TIFFGetA(pixel);
            }
        }
    }
    checkpoint();
    return output;
}
}
