// Host parity oracle: execute the existing production still-photo gradient limit.
#include "../../native/rvm/photo_depth.h"
#include <fstream>
#include <string>
#include <cstdio>
int main(int argc, char** argv) {
    if (argc==2 && std::string(argv[1])=="--check-strengths") {
        int checks=0, failures=0;
        const auto check=[&](bool ok) { ++checks; if (!ok) ++failures; };
        for (int width : {16,320,2048,3547,4096}) {
            float previous=quest::photo_half_shift(width,0);
            check(previous==0);
            for (int percent=1;percent<=200;++percent) {
                const float half=quest::photo_half_shift(width,percent/100.f);
                check(half>previous); previous=half;
            }
            const float normal=quest::photo_half_shift(width,1);
            check(std::abs(normal-std::max(2.f,std::min(96.f,width*.035f))*.5f)<.00001f);
            check(std::abs(previous-2*normal)<.00001f && previous<=96.f);
        }
        std::printf("Photo strength range: %d checks, %d failures\n",checks,failures);
        return failures ? 1 : 0;
    }
    if (argc==4 && std::string(argv[1])=="--half-shift") {
        std::printf("%.9f\n",quest::photo_half_shift(std::stoi(argv[2]),std::stof(argv[3])));
        return 0;
    }
    if (argc != 11) return 2;
    const int w=std::stoi(argv[3]), h=std::stoi(argv[4]);
    const int x=std::stoi(argv[5]), y=std::stoi(argv[6]), cw=std::stoi(argv[7]), ch=std::stoi(argv[8]);
    const float hx=std::stof(argv[9]), hy=std::stof(argv[10]);
    if (w<1 || h<1 || w>518 || h>518) return 3;
    std::vector<float> values(static_cast<size_t>(w)*h), transposed(values.size());
    if (!std::ifstream(argv[1],std::ios::binary).read(reinterpret_cast<char*>(values.data()),values.size()*sizeof(float))) return 4;
    quest::photo_limit_gradient(values.data(),w,h,x,y,cw,ch,hx);
    if (hy>0) {
        for (int row=0;row<h;++row) for (int col=0;col<w;++col) transposed[col*h+row]=values[row*w+col];
        quest::photo_limit_gradient(transposed.data(),h,w,y,x,ch,cw,hy);
        for (int row=0;row<h;++row) for (int col=0;col<w;++col) values[row*w+col]=transposed[col*h+row];
    }
    return std::ofstream(argv[2],std::ios::binary).write(reinterpret_cast<char*>(values.data()),values.size()*sizeof(float)) ? 0 : 5;
}
