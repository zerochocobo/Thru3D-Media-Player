// Real production HTTP demux/audio decoding and cancellation, without a model,
// Android services, or a headset. directAudio=false matches non-cloud playback.
#include "../../native/narration/listening_jni.cpp"
#include <fstream>
#include <iostream>
#include <thread>

int main(int argc,char** argv){
    if(argc!=5)return 2;
    std::atomic<bool> cancelled{false};
    const bool cancel=std::string(argv[3])=="cancel";
    const auto began=std::chrono::steady_clock::now();
    std::thread interrupter;
    if(cancel)interrupter=std::thread([&]{std::this_thread::sleep_for(std::chrono::milliseconds(250));cancelled=true;});
    size_t samples=0;std::string failure;
    try{
        AudioReader reader(&cancelled);
        reader.open(argv[1],"",1,std::stod(argv[2]),false,-1,0.0,false);
        std::ofstream output(argv[4],std::ios::binary);
        if(!output)throw std::runtime_error("output_unavailable");
        while(!reader.eof){
            auto pcm=reader.read();samples+=pcm.size();
            if(samples>16000*60)throw std::runtime_error("unexpected_audio_length");
            output.write(reinterpret_cast<const char*>(pcm.data()),std::streamsize(pcm.size()*sizeof(float)));
        }
    }catch(const std::exception& error){failure=error.what();}
    if(interrupter.joinable())interrupter.join();
    const double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count();
    // Only fixed exception codes are printed, never a source URL or transcript.
    std::cout<<"{\"ok\":"<<(failure.empty()?"true":"false")<<",\"cancelled\":"<<(cancelled?"true":"false")
             <<",\"seconds\":"<<seconds<<",\"samples\":"<<samples<<",\"error\":\""<<failure<<"\"}\n";
    return failure.empty()?0:1;
}
