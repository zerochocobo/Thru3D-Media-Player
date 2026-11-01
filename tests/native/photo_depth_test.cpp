#include "../../native/rvm/photo_depth.h"
#include "../../native/rvm/photo_rotation.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <vector>

int main() {
    int failures = 0, checks = 0;
    auto check = [&](bool ok, const char* name) { ++checks; if (!ok) { ++failures; std::fprintf(stderr, "%s\n", name); } };
    for (int turns : {0, 1, 2, 3}) {
        const int w = 7, h = 4, rw = turns % 2 ? h : w, rh = turns % 2 ? w : h;
        std::vector<int> counts(w*h);
        bool roundtrip = true;
        for (int y=0; y<h; ++y) for (int x=0; x<w; ++x) {
            const auto p = quest::photo_rotated_pixel(x,y,w,h,turns);
            check(p.first>=0 && p.first<rw && p.second>=0 && p.second<rh,"Rotated depth pixel stays in bounds");
            ++counts[p.second*rw+p.first];
            roundtrip &= quest::photo_rotated_pixel(p.first,p.second,rw,rh,(4-turns)%4)==std::make_pair(x,y);
        }
        check(roundtrip && std::all_of(counts.begin(),counts.end(),[](int n){return n==1;}),"Depth rotation is bijective with exact inverse");
        const std::array<float,4> rect{{.125f,.25f,.5f,.625f}};
        const auto rotated=quest::photo_rotated_rect(rect,turns);
        const auto restored=quest::photo_rotated_rect(rotated,(4-turns)%4);
        check(restored==rect,"Asymmetric padded content rect survives rotation/inverse");
    }
    bool invalid_rotation=false;
    try { quest::photo_rotated_pixel(0,0,2,2,4); } catch (const std::invalid_argument&) { invalid_rotation=true; }
    check(invalid_rotation,"Invalid rotation rejected");
    for (bool portrait : {false, true}) {
        const int w = 518, h = 518, x = portrait ? 76 : 0, y = portrait ? 0 : 76;
        const int cw = portrait ? 366 : w, ch = portrait ? h : 366;
        std::vector<float> a(w*h, -10000.f), b(w*h, 10000.f), na(w*h), nb(w*h);
        for (int row = y; row < y+ch; ++row) for (int col = x; col < x+cw; ++col)
            a[row*w+col] = b[row*w+col] = 1.f + static_cast<float>(col-x) / (cw-1);
        quest::photo_near_map(a.data(),w,h,x,y,cw,ch,na.data());
        quest::photo_near_map(b.data(),w,h,x,y,cw,ch,nb.data());
        check(na == nb, "Changing only padding must not alter normalization or dilation");
        check(na[(y+ch/2)*w+x] < .01f && na[(y+ch/2)*w+x+cw-1] > .99f, "Content must retain its full near/far range");
        check(std::all_of(na.begin(),na.end(),[](float v) { return std::isfinite(v) && v>=0 && v<=1; }), "Finite bounded output");
        bool extended = true;
        for (int row=0;row<h;++row) for(int col=0;col<w;++col)
            if (row<y || row>=y+ch || col<x || col>=x+cw)
                extended &= na[row*w+col] == na[std::clamp(row,y,y+ch-1)*w+std::clamp(col,x,x+cw-1)];
        check(extended,"Padding must replicate the content edge for linear sampling");
        // Constant or invalid content remains on the screen, regardless of arbitrary padding.
        for (float value : {2.f, std::numeric_limits<float>::quiet_NaN()}) {
            for(int row=y;row<y+ch;++row) for(int col=x;col<x+cw;++col) a[row*w+col]=value;
            quest::photo_near_map(a.data(),w,h,x,y,cw,ch,na.data());
            check(std::all_of(na.begin(),na.end(),[](float v) { return v==.35f; }),"Flat/invalid photo must be neutral");
        }
        // A hard foreground block: every horizontal fall is limited (the hole fill cannot reach back
        // into the subject), while the subject's plateau and the far background stay untouched.
        for(int row=y;row<y+ch;++row) for(int col=x;col<x+cw;++col)
            a[row*w+col] = (col-x > cw/3 && col-x < 2*cw/3) ? 5.f : 1.f;
        a[y*w+x] = 0.f; // keep a 5 % tail below the background so the band is not degenerate
        quest::photo_near_map(a.data(),w,h,x,y,cw,ch,na.data());
        for (float strength : {1.f, 2.f}) {
            nb = na;
            const float half = .0175f * strength * cw; // one eye's shift in model columns
            quest::photo_limit_gradient(nb.data(),w,h,x,y,cw,ch,half);
            float worst = 0;
            for(int row=y;row<y+ch;++row) for(int col=x;col+1<x+cw;++col)
                worst = std::max(worst, std::abs(nb[row*w+col+1]-nb[row*w+col]));
            const int mid = (y+ch/2)*w + x;
            check(worst <= .9f / half + 1e-5f, "Horizontal near falls must respect the disparity-gradient limit");
            check(nb[mid+cw/2] > .99f && nb[mid+3] < .01f && nb[mid+cw-4] < .01f, "Plateaus must keep their depth");
            check(nb[mid+cw/3-2] > .5f && nb[mid+cw/3-2] < nb[mid+cw/3+2], "The fall beside the subject becomes a ramp");
            bool padded = true;
            for (int row=0;row<h;++row) for(int col=0;col<w;++col)
                if (row<y || row>=y+ch || col<x || col>=x+cw)
                    padded &= nb[row*w+col] == nb[std::clamp(row,y,y+ch-1)*w+std::clamp(col,x,x+cw-1)];
            check(padded, "Limited padding still replicates the content edge");
        }
        nb = na; quest::photo_limit_gradient(nb.data(),w,h,x,y,cw,ch,0.f);
        check(nb == na, "Zero strength leaves the map unchanged");
        bool rejected = false;
        try { quest::photo_near_map(a.data(),w,h,x,y,w+1,ch,na.data()); }
        catch(const std::invalid_argument&) { rejected=true; }
        check(rejected,"Reject out-of-bounds content before reading buffers");
        quest::photo_near_map(a.data(),w,h,0,0,1,1,na.data());
        check(na[0]==.35f,"Tiny content remains bounded and neutral");
    }
    std::printf("Photo depth normalization: %d checks, %d failures\n",checks,failures);
    return failures ? 1 : 0;
}
