// Exercise the production JNI registry against a deliberately stalled model
// destructor. Cancellation of another video must not wait for that destructor.
#include "../../native/narration/listening_jni.cpp"
#include <future>
#include <iostream>
#include <thread>
static std::promise<void> destroying, released;
static auto releaseDestruction=released.get_future().share();
extern "C" void moonshine_free_transcriber(int32_t){destroying.set_value();releaseDestruction.wait();}
extern "C" int32_t moonshine_free_stream(int32_t,int32_t){return 0;}
int main(){
    auto slow=std::make_shared<Engine>();slow->model=1;engines.emplace(1,std::move(slow));
    auto active=std::make_shared<Engine>();engines.emplace(2,active);
    std::thread destroy([]{Java_org_vrpassthroughplayer_plugin_ListeningNative_destroy(nullptr,nullptr,1);});
    destroying.get_future().wait();
    auto cancel=std::async(std::launch::async,[]{Java_org_vrpassthroughplayer_plugin_ListeningNative_cancel(nullptr,nullptr,2);});
    bool responsive=cancel.wait_for(std::chrono::milliseconds(200))==std::future_status::ready;
    released.set_value();destroy.join();cancel.get();
    if(!responsive||!active->cancelled)return 1;
    Java_org_vrpassthroughplayer_plugin_ListeningNative_begin(nullptr,nullptr,2);
    if(active->cancelled)return 2;
    Java_org_vrpassthroughplayer_plugin_ListeningNative_cancel(nullptr,nullptr,2);
    // open must not clear a cancellation arriving after the controller's begin.
    if(!active->cancelled)return 3;
    engines.clear();
    std::cout<<"Slow model destruction leaves cancellation responsive\n";
}
