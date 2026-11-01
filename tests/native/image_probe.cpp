#include "image_core.h"
#include <avif/avif.h>
#include <fstream>
#include <iostream>
int main(int argc,char** argv){
    try{if(argc<3)return 2;
        if(argc>4&&std::string(argv[4])=="encoded16"){
            auto* decoder=avifDecoderCreate();if(!decoder)return 1;
            if(avifDecoderSetIOFile(decoder,argv[1])!=AVIF_RESULT_OK||avifDecoderParse(decoder)!=AVIF_RESULT_OK||avifDecoderNextImage(decoder)!=AVIF_RESULT_OK){avifDecoderDestroy(decoder);return 1;}
            auto* image=decoder->image;avifRGBImage rgb;avifRGBImageSetDefaults(&rgb,image);rgb.depth=16;rgb.format=AVIF_RGB_FORMAT_RGBA;
            std::vector<uint16_t> pixels(size_t(image->width)*image->height*4);rgb.pixels=reinterpret_cast<uint8_t*>(pixels.data());rgb.rowBytes=image->width*8;
            if(avifImageYUVToRGB(image,&rgb)!=AVIF_RESULT_OK){avifDecoderDestroy(decoder);return 1;}
            std::ofstream file(std::string(argv[2])+".rgba16",std::ios::binary);file.write(reinterpret_cast<const char*>(pixels.data()),std::streamsize(pixels.size()*2));
            std::cout<<"{\"width\":"<<image->width<<",\"height\":"<<image->height<<",\"primaries\":"<<int(image->colorPrimaries)<<",\"transfer\":"<<int(image->transferCharacteristics)<<"}\n";
            avifDecoderDestroy(decoder);return 0;
        }
        auto decoder=thru::image::open(argv[1],argc>3?std::stoi(argv[3]):2048,argc>4&&std::string(argv[4])=="preview",{},
            argc>5?std::stoull(argv[5])*1024*1024:512ULL*1024*1024,argc>6?std::stoull(argv[6])*1024*1024:128ULL*1024*1024);
        if(argc>4&&std::string(argv[4])=="recover"){
            auto budget=decoder->memory_budget;decoder->memory_budget=0;bool rejected=false;thru::image::Frame pressure;
            try{decoder->next(pressure,{});}catch(const std::exception& e){rejected=std::string(e.what())=="PHOTO_OUT_OF_MEMORY";}
            if(!rejected)return 5;decoder->memory_budget=budget;
        }
        thru::image::Frame frame;int count=0;while(decoder->next(frame,{})){
            std::ofstream file(std::string(argv[2])+"-"+std::to_string(count)+".rgba",std::ios::binary);file.write(reinterpret_cast<const char*>(frame.rgba.data()),std::streamsize(frame.rgba.size()));
            std::cout<<"{\"frame\":"<<count<<",\"width\":"<<frame.width<<",\"height\":"<<frame.height<<",\"duration_us\":"<<frame.duration_us<<",\"kind\":"<<int(decoder->info.kind)<<",\"orientation\":"<<decoder->info.orientation<<",\"plays\":"<<decoder->info.plays<<",\"preview\":"<<(decoder->info.preview?"true":"false")<<"}\n";if(++count>1000)return 3;}
        return count?0:4;
    }catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
}
