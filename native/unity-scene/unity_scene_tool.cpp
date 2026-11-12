// Desktop front end: unity_scene_unpack <bundle> <output> [max_texture] [max_sky_texture]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "etc2_encoder.h"
#include "unity_scene.h"

#ifdef _WIN32
#include <windows.h>

static std::string utf8(const wchar_t* text) {
    int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    std::string out(size > 0 ? size_t(size) - 1 : 0, '\0');
    if (size > 1) WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
    return out;
}

int wmain(int argc, wchar_t** argv) {
    // A corrupt download must end as an error code, never as a crash dialog.
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (argc < 3) { std::fprintf(stderr, "usage: unity_scene_unpack <bundle> <output> [max_texture] [max_sky_texture]\n"); return 2; }
    std::string input = utf8(argv[1]), output = utf8(argv[2]);
    int max_texture = argc > 3 ? _wtoi(argv[3]) : 0, max_sky = argc > 4 ? _wtoi(argv[4]) : 0;
#else
int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: unity_scene_unpack <bundle> <output> [max_texture] [max_sky_texture]\n"); return 2; }
    std::string input = argv[1], output = argv[2];
    int max_texture = argc > 3 ? std::atoi(argv[3]) : 0, max_sky = argc > 4 ? std::atoi(argv[4]) : 0;
#endif
    // etc2 <rgba file> <width> <height> <alpha 0|1> <chain 0|1> <output>: encoder check for the tests.
    if (input == "etc2" && argc >= 8) {
#ifdef _WIN32
        std::string source = utf8(argv[2]), target = utf8(argv[7]);
        int width = _wtoi(argv[3]), height = _wtoi(argv[4]), alpha = _wtoi(argv[5]), chain = _wtoi(argv[6]);
#else
        std::string source = argv[2], target = argv[7];
        int width = std::atoi(argv[3]), height = std::atoi(argv[4]), alpha = std::atoi(argv[5]), chain = std::atoi(argv[6]);
#endif
        std::ifstream in(std::filesystem::u8path(source), std::ios::binary);
        std::vector<char> pixels((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        size_t size = chain ? thru3d_etc2_chain_size(width, height, alpha) : thru3d_etc2_level_size(width, height, alpha);
        std::vector<uint8_t> encoded(size);
        if (size == 0 || thru3d_etc2_encode(reinterpret_cast<const uint8_t*>(pixels.data()), pixels.size(), width, height, alpha, chain, encoded.data(), encoded.size(), 4) != 0) {
            std::fputs("pixels do not match the given size\n", stderr);
            return 1;
        }
        std::ofstream out(std::filesystem::u8path(target), std::ios::binary | std::ios::trunc);
        out.write(reinterpret_cast<const char*>(encoded.data()), std::streamsize(encoded.size()));
        return out ? 0 : 1;
    }
    char error[256] = {};
    int result = thru3d_unity_scene_unpack(input.c_str(), output.c_str(), max_texture, max_sky, error, sizeof error);
    if (result != 0) std::fprintf(stderr, "%s\n", error);
    return result;
}
