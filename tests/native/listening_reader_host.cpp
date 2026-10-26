// Exercise the production reader on desktop FFmpeg without Android or a headset.
#include "../../native/narration/listening_jni.cpp"
#include <fstream>
#include <iostream>
#include <functional>
struct FileInput:ListeningReadAt {
    std::ifstream file;int64_t length;
    std::function<void()> afterRead;
    explicit FileInput(const char* path):file(path,std::ios::binary){file.seekg(0,std::ios::end);length=file.tellg();}
    int64_t size()const override{return length;}
    int read(int64_t offset,uint8_t* bytes,int count)override{
        file.clear();file.seekg(offset);file.read(reinterpret_cast<char*>(bytes),std::min<int64_t>(count,length-offset));
        if(afterRead)afterRead();
        return file.gcount()>0?int(file.gcount()):AVERROR_EOF;
    }
};
int main(int argc,char** argv){
    if(argc<5||argc>7)return 2;
    try{
        std::atomic<bool> cancelled{false};AudioReader reader(&cancelled);
        const bool yieldTest=argc==7&&std::string(argv[6])=="input-yield";
        auto input=argc==7&&(std::string(argv[6])=="input"||yieldTest)?std::make_unique<FileInput>(argv[1]):nullptr;
        auto* source=input.get();bool expired=false,yielded=false;
        reader.open(argv[1],"",std::stoi(argv[2]),std::stod(argv[3]),false,-1,
                    argc>=6?std::stod(argv[5]):std::numeric_limits<double>::quiet_NaN(),true,
                    std::move(input));
        if(yieldTest)source->afterRead=[&]{if(!expired){expired=true;reader.deadline=std::chrono::steady_clock::now()-std::chrono::milliseconds(1);}};
        if(argc==7&&std::string(argv[6])=="buffered")reader.format->pb->direct=0;
        std::ofstream output(argv[4],std::ios::binary);size_t count=0;
        while(!reader.eof){auto samples=reader.read();if(samples.size()>16000)return 3;
            if(yieldTest&&expired&&!reader.eof&&samples.size()<16000)yielded=true;
            output.write(reinterpret_cast<const char*>(samples.data()),std::streamsize(samples.size()*sizeof(float)));count+=samples.size();
            if(count>16000*180)return 4;
        }
        cancelled=true;bool interrupted=false;try{reader.read();}catch(const std::exception&){interrupted=true;}
        if(!interrupted)return 5;
        if(yieldTest&&(!expired||!yielded))return 6;
        std::cout<<"{\"samples\":"<<count<<",\"through\":"<<reader.start+reader.cursor/16000.
                 <<",\"audio_spans\":"<<reader.audioSpans().size()/2
                 <<",\"demux_bytes_read\":"<<(reader.format->pb?reader.format->pb->bytes_read:0)
                 <<",\"budget_yielded\":"<<(yielded?"true":"false")<<",\"cancelled\":true}\n";
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
