#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>
namespace thru::image {
enum class Kind { Unknown=0, Avif=1, Webp=2, Gif=3, Apng=4, Raw=5 };
struct Info {
    Kind kind=Kind::Unknown;
    int width=0, height=0, frames=1, orientation=1;
    int64_t plays=1; // 0 means infinite; unknown fields never imply infinite.
    bool alpha=false, preview=false;
};
struct Frame { int width=0,height=0; int64_t duration_us=0; std::vector<uint8_t> rgba; };
using Check=std::function<void()>;
class Decoder {
public:
    Info info;
    virtual ~Decoder()=default;
    virtual bool next(Frame&,const Check&)=0;
    virtual void reset()=0;
};
Kind sniff(const std::string& path, bool raw_hint=false);
std::unique_ptr<Decoder> open(const std::string& path, int edge, bool preview, const Check& check={});
Info raw_info(const std::string& path);
}
