#pragma once
// Reuse the project's pinned libjpeg-turbo (also used by the TIFF decoder).
#include <cstdio>
#include <cstdint>
#include <csetjmp>
#include <stdexcept>
#include <jpeglib.h>

namespace quest::pipshot {
class Jpeg {
    struct Error { jpeg_error_mgr base{}; std::jmp_buf recovery; } error;
    jpeg_compress_struct codec{};
    FILE* file=nullptr;
    bool created=false;
    static void failed(j_common_ptr value) {
        auto* state=reinterpret_cast<Error*>(value->err);
        std::longjmp(state->recovery,1);
    }
public:
    Jpeg(const char* path,int width,int height) {
        codec.err=jpeg_std_error(&error.base);error.base.error_exit=failed;
        if(setjmp(error.recovery)) {
            if(created)jpeg_destroy_compress(&codec);
            if(file)std::fclose(file);
            throw std::runtime_error("JPEG encoder failed");
        }
        jpeg_create_compress(&codec);created=true;
        file=std::fopen(path,"wb");
        if(!file) {jpeg_destroy_compress(&codec);created=false;throw std::runtime_error("JPEG open failed");}
        jpeg_stdio_dest(&codec,file);
        codec.image_width=width;codec.image_height=height;codec.input_components=4;codec.in_color_space=JCS_EXT_RGBA;
        jpeg_set_defaults(&codec);
        jpeg_set_quality(&codec,100,TRUE);
        codec.optimize_coding=FALSE;
        jpeg_start_compress(&codec,TRUE);
    }
    Jpeg(const Jpeg&)=delete;
    Jpeg& operator=(const Jpeg&)=delete;
    void row(const uint8_t* pixels) {
        if(setjmp(error.recovery))throw std::runtime_error("JPEG write failed");
        JSAMPROW rows[]={const_cast<uint8_t*>(pixels)};
        if(jpeg_write_scanlines(&codec,rows,1)!=1)throw std::runtime_error("JPEG row failed");
    }
    void finish() {
        if(setjmp(error.recovery))throw std::runtime_error("JPEG finish failed");
        jpeg_finish_compress(&codec);
        if(std::fflush(file))throw std::runtime_error("JPEG flush failed");
    }
    ~Jpeg(){if(created)jpeg_destroy_compress(&codec);if(file)std::fclose(file);}
};
} // namespace quest::pipshot
