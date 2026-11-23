#pragma once
#include "voice_vad.h"
#include <algorithm>
#include <cstdint>
#include <vector>
// Silero speech segmentation for look-ahead subtitles: start after min speech, end after
// min silence, split at the maximum length. Segments keep a little audio before
// the first and after the last voiced window so word edges are not clipped.
// Times are sample offsets.
class SpeechSegmenter {
    VoiceVad vad;
    std::vector<float> pending,current,history;
    int64_t consumed=0,start=-1,silence=0,speech=0;
public:
    struct Segment {int64_t start;std::vector<float> samples;};
    // Desktop study on 72 min of Japanese films (2026-11-23): .3 with 0.3 s lead-in
    // and 0.2 s tail matched sherpa-onnx's speech coverage with fewer false lines.
    // An 8 s cap (99% of reference lines are shorter than 7 s) kept the same
    // accuracy as 12 s and cut the longest whole-segment decode step from 3.5 s to
    // 1.2 s; ListeningCueCache.SETTLE_SECONDS (12) must stay above cap + padding.
    float threshold=.3f;int64_t minSilence=6400,minSpeech=4000,maxSpeech=128000,before=4800,after=3200;
    explicit SpeechSegmenter(const char* path):vad(path){vad.reset();}
    /** Sample offset where the segment still being collected began, or -1. */
    int64_t openStart()const{return start;}
    std::vector<Segment> accept(const float* samples,size_t count,bool finish=false){
        std::vector<Segment> done;pending.insert(pending.end(),samples,samples+count);
        auto close=[&](bool full){
            const int64_t keep=full?int64_t(current.size()):std::min<int64_t>(int64_t(current.size()),speech+std::min(after,silence));
            if(speech>=minSpeech){current.resize(size_t(keep));done.push_back({start,current});}
            start=-1;current.clear();silence=speech=0;
        };
        size_t used=0;
        for(;used+512<=pending.size();used+=512){
            const float* window=pending.data()+used;const bool voiced=vad.run(window)>threshold;
            if(start<0){
                if(voiced){
                    // Lead-in from the audio just before this window.
                    const int64_t lead=std::min<int64_t>(before,int64_t(history.size()));
                    current.assign(history.end()-lead,history.end());current.insert(current.end(),window,window+512);
                    start=consumed-lead;speech=lead+512;silence=0;
                }
            }else{
                current.insert(current.end(),window,window+512);
                if(voiced){speech+=512+silence;silence=0;}else silence+=512;
                const bool ended=silence>=minSilence,full=int64_t(current.size())>=maxSpeech;
                if(ended||full)close(full&&!ended);
            }
            history.insert(history.end(),window,window+512);
            if(int64_t(history.size())>before+512)history.erase(history.begin(),history.end()-(before+512));
            consumed+=512;
        }
        pending.erase(pending.begin(),pending.begin()+used);
        if(finish&&start>=0)close(false);
        return done;
    }
};
