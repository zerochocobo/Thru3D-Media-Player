#include "../../native/mpv/live/live_capture_core.h"
#include <cassert>
#include <iostream>

int main() {
    auto run=[](const std::vector<int64_t>& pts,bool missing) {
        quest::live::MatroskaTimeline timeline;
        std::vector<int64_t> actual;int64_t last=AV_NOPTS_VALUE;
        auto sink=[&](quest::live::Packet packet) {
            assert(packet->dts<=packet->pts);
            assert(last==AV_NOPTS_VALUE||last<=packet->dts);last=packet->dts;
            assert(packet->duration==(missing?0:1000));actual.push_back(packet->pts);
        };
        for(size_t i=0;i<pts.size();++i) {
            auto packet=quest::capture::packet();packet->pts=pts[i];
            packet->dts=missing?AV_NOPTS_VALUE:static_cast<int64_t>(i)*1000-2000;
            packet->duration=missing?-1000000:1000;
            timeline.push(quest::live::retain(packet.get()),sink);
            assert(packet->duration==(missing?-1000000:1000)); // Never mutate playback's packet.
        }
        timeline.finish(sink);assert(actual==pts);
    };
    run({0,3000,1000,2000,6000,4000,5000},false);
    run({0,3000,1000,2000,6000,4000,5000},true);
    run({0,9000,1000,5000,25000,12000,20000},true); // VFR: no manufactured frame rate.
    std::vector<int64_t> maximum_reorder;
    for(int group=0;group<8;++group)for(int frame=15;frame>=0;--frame)maximum_reorder.push_back(group*16000+frame*1000);
    run(maximum_reorder,true);
    bool rejected=false;
    try {std::vector<int64_t> beyond_bound(65);for(int i=0;i<64;++i)beyond_bound[i]=100000+i*1000;beyond_bound[64]=0;run(beyond_bound,true);}
    catch(const std::runtime_error& error){rejected=std::string(error.what())=="Clip timestamps unavailable";}
    assert(rejected);
    std::cout<<"Live timestamp checks passed (known/missing DTS, VFR, reorder bound, unchanged PTS/source packets)\n";
}
