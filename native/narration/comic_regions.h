#pragma once
#include <algorithm>
#include <cstdint>
#include <utility>
#include <vector>

namespace comic {
struct Rect {
    int x0=0,y0=0,x1=0,y1=0;
    int w()const{return x1-x0;} int h()const{return y1-y0;}
    int area()const{return w()*h();}
    double cx()const{return (x0+x1)*.5;} double cy()const{return (y0+y1)*.5;}
    std::vector<int> json()const{return {x0,y0,x1,y1};}
};
inline int overlap(int a,int b,int c,int d){return std::max(0,std::min(b,d)-std::max(a,c));}
inline int intersection(Rect a,Rect b){return overlap(a.x0,a.x1,b.x0,b.x1)*overlap(a.y0,a.y1,b.y0,b.y1);}
inline Rect merge(Rect a,Rect b){return {std::min(a.x0,b.x0),std::min(a.y0,b.y0),std::max(a.x1,b.x1),std::max(a.y1,b.y1)};}
struct Component {Rect box;int pixels=0;double score=0;};
struct Components {std::vector<int> labels;std::vector<Component> regions;};
inline Components components(const std::vector<uint8_t>& mask,int w,int h,const float* probabilities=nullptr,int connectivity=8){
    Components out;out.labels.resize(mask.size());out.regions.push_back({});std::vector<int> queue;
    for(int at=0;at<w*h;++at){
        if(!mask[at]||out.labels[at])continue;
        const int id=int(out.regions.size());Component c{{at%w,at/w,at%w+1,at/w+1},0,0};
        queue.clear();queue.push_back(at);out.labels[at]=id;
        for(size_t n=0;n<queue.size();++n){
            int p=queue[n],x=p%w,y=p/w;c.box=merge(c.box,{x,y,x+1,y+1});++c.pixels;
            if(probabilities)c.score+=probabilities[p];
            for(int dy=-1;dy<=1;++dy)for(int dx=-1;dx<=1;++dx){
                if(connectivity==4&&dx&&dy)continue;
                int xx=x+dx,yy=y+dy;if(xx<0||xx>=w||yy<0||yy>=h)continue;int q=yy*w+xx;
                if(mask[q]&&!out.labels[q]){out.labels[q]=id;queue.push_back(q);}
            }
        }
        if(c.pixels)c.score/=c.pixels;out.regions.push_back(c);
    }
    return out;
}
inline bool bounded(const Component& c,int w,int h){
    const auto& b=c.box;
    return b.x0>0&&b.y0>0&&b.x1<w&&b.y1<h&&c.pixels<w*h*.15;
}
inline bool clippedBalloon(const Component& c,int w,int h){
    const auto& b=c.box;
    int edges=int(b.x0==0)+int(b.y0==0)+int(b.x1==w)+int(b.y1==h);
    return edges==1&&c.pixels<w*h*.15&&b.area()<w*h*.2&&c.pixels>b.area()*.4;
}
inline bool clipContainsText(const Component& c,Rect core,int w,int h,double font){
    const auto& b=c.box;
    return clippedBalloon(c,w,h)&&(b.x0!=0||core.x0>=font*.25)
        &&(b.y0!=0||core.y0>=font*.25)&&(b.x1!=w||w-core.x1>=font*.25)
        &&(b.y1!=h||h-core.y1>=font*.25);
}
inline bool borderArtwork(const Component& c,int w,int h,double font){
    const auto& b=c.box;
    return (b.x0==0||b.y0==0||b.x1==w||b.y1==h)&&std::max(b.w(),b.h())>font*2&&c.pixels>font*font*.1;
}
// Straight top/bottom rims distinguish a caption rectangle from rounded
// balloons, including very tall capsules whose middle rows are nearly flat.
inline bool rectangularRim(const std::vector<std::pair<int,int>>& rows,int width){
    if(rows.size()<6||width<6)return false;
    int full=0,top=0,bottom=0;
    for(auto row:rows)full+=row.second-row.first>=width*.95;
    for(size_t i=0;i<3;++i){top=std::max(top,rows[i].second-rows[i].first);
        const auto& row=rows[rows.size()-1-i];bottom=std::max(bottom,row.second-row.first);}
    return full>rows.size()*.9&&top>=width*.9&&bottom>=width*.9;
}

// A sparse panel corner can be convex yet contain artwork and a sound effect.
// Combine its two straight edge supports with the existing 12x text-area
// budget; either cue alone also occurs in genuine balloons touching a frame.
inline bool sparsePanelCorner(const std::vector<std::pair<int,int>>& rows,Rect bounds,Rect text,int white_pixels){
    if(rows.empty()||bounds.w()<=0||bounds.h()<=0||white_pixels<=text.area()*12)return false;
    const int band=std::min(int(rows.size()),std::max(2,bounds.h()/50));
    int top=0,bottom=0,left=0,right=0;
    for(int i=0;i<band;++i){top=std::max(top,rows[i].second-rows[i].first);
        const auto& row=rows[rows.size()-1-i];bottom=std::max(bottom,row.second-row.first);}
    for(auto row:rows){left+=row.first<=bounds.x0+2;right+=row.second>=bounds.x1-2;}
    return std::max(top,bottom)>=bounds.w()*.9&&std::max(left,right)>=bounds.h()*.5;
}
// Filled contour area / convex-hull area. Internal glyph holes are filled by
// row spans; deep concavities of white holes in title lettering remain visible.
inline double silhouetteSolidity(const std::vector<std::pair<int,int>>& rows){
    struct Point {int x,y;};std::vector<Point> points;double filled=0;
    for(size_t y=0;y<rows.size();++y){auto [left,right]=rows[y];if(right<=left)continue;
        filled+=right-left;points.push_back({left,int(y)});points.push_back({right,int(y)});
        points.push_back({left,int(y)+1});points.push_back({right,int(y)+1});
    }
    if(points.size()<3)return 0;
    std::sort(points.begin(),points.end(),[](Point a,Point b){return a.x==b.x?a.y<b.y:a.x<b.x;});
    auto cross=[](Point a,Point b,Point c){return int64_t(b.x-a.x)*(c.y-a.y)-int64_t(b.y-a.y)*(c.x-a.x);};
    std::vector<Point> hull;
    for(auto p:points){while(hull.size()>1&&cross(hull[hull.size()-2],hull.back(),p)<=0)hull.pop_back();hull.push_back(p);}
    size_t lower=hull.size();
    for(auto it=points.rbegin()+1;it!=points.rend();++it){while(hull.size()>lower&&cross(hull[hull.size()-2],hull.back(),*it)<=0)hull.pop_back();hull.push_back(*it);}
    double area=0;for(size_t i=1;i<hull.size();++i)area+=double(hull[i-1].x)*hull[i].y-double(hull[i].x)*hull[i-1].y;
    return area>0?filled/(area*.5):0;
}
// Joined speech lobes can be concave as a whole. Split only in the blank
// vertical gaps between established paragraphs, and require each lobe to pass
// the same convexity test. This never joins different connected components.
inline bool paragraphLobes(const std::vector<std::pair<int,int>>& rows,int top,std::vector<Rect> cores){
    if(cores.size()<2||cores.size()>6||rows.empty())return false;
    std::sort(cores.begin(),cores.end(),[](Rect a,Rect b){return a.y0<b.y0;});
    int start=0;
    for(size_t i=0;i<cores.size();++i){
        if(cores[i].y0<top||cores[i].y1>top+int(rows.size()))return false;
        if(i+1<cores.size()&&cores[i].y1>=cores[i+1].y0)return false;
        int end=i+1==cores.size()?int(rows.size()):(cores[i].y1+cores[i+1].y0)/2-top;
        if(end<=start)return false;
        std::vector<std::pair<int,int>> lobe(rows.begin()+start,rows.begin()+end);
        if(std::any_of(lobe.begin(),lobe.end(),[](auto row){return row.second<=row.first;})||silhouetteSolidity(lobe)<.8)return false;
        start=end;
    }
    return true;
}
// Opening of the light background = closing of the ink outline. Replicated
// image edges keep cropped balloons attached to the exterior (never invent a
// frame around an open page). Integral sums make each scale O(width*height).
inline std::vector<uint8_t> openBackground(const std::vector<uint8_t>& mask,int w,int h,int radius){
    auto square=[&](const std::vector<uint8_t>& input,bool erode){
        std::vector<int> sums(size_t(w+1)*(h+1));
        for(int y=0;y<h;++y){int row=0;for(int x=0;x<w;++x){row+=input[y*w+x];sums[(y+1)*(w+1)+x+1]=sums[y*(w+1)+x+1]+row;}}
        std::vector<uint8_t> result(mask.size());
        for(int y=0;y<h;++y)for(int x=0;x<w;++x){
            int x0=std::max(0,x-radius),x1=std::min(w,x+radius+1),y0=std::max(0,y-radius),y1=std::min(h,y+radius+1);
            int sum=sums[y1*(w+1)+x1]-sums[y0*(w+1)+x1]-sums[y1*(w+1)+x0]+sums[y0*(w+1)+x0];
            result[y*w+x]=erode?sum==(x1-x0)*(y1-y0):sum>0;
        }
        return result;
    };
    return square(square(mask,true),false);
}
// Keep every recovered pocket, not just the largest child of outside paper.
// Check each text seed against the filled row contour. Opening can remove
// narrow white spaces inside complete glyphs; those holes are not lost text.
// Reject a child whose actual silhouette cuts a detected core.
inline void recoverPockets(Components& original,const std::vector<uint8_t>& mask,int w,int h,int radius,const std::vector<Rect>& seeds={}){
    auto split=components(openBackground(mask,w,h,radius),w,h,nullptr,4);
    std::vector<int> recovered(split.regions.size()),owner(split.regions.size());
    for(size_t p=0;p<mask.size();++p)if(split.labels[p]&&original.labels[p])owner[split.labels[p]]=original.labels[p];
    for(size_t i=1;i<split.regions.size();++i){const auto c=split.regions[i];const auto b=c.box;
        if(!bounded(c,w,h)||c.pixels<80||std::min(b.w(),b.h())<12||c.pixels<b.area()*.35)continue;
        const int source=owner[i];bool safe=true,seeded=false;
        std::vector<std::pair<int,int>> rows(b.h(),{w,0});
        for(int y=b.y0;y<b.y1;++y)for(int x=b.x0;x<b.x1;++x)if(split.labels[y*w+x]==int(i)){
            rows[y-b.y0].first=std::min(rows[y-b.y0].first,x);rows[y-b.y0].second=std::max(rows[y-b.y0].second,x+1);}
        for(auto seed:seeds){
            if(!intersection(seed,b))continue;
            int covered=0;
            for(int y=std::max(seed.y0,b.y0);y<std::min(seed.y1,b.y1);++y){auto row=rows[y-b.y0];
                covered+=overlap(seed.x0,seed.x1,row.first,row.second);}
            if(covered<seed.area()*.1)continue;
            if(covered<seed.area()*.98){safe=false;break;}
            seeded=true;
        }
        if(!safe)continue;
        if(source&&bounded(original.regions[source],w,h)&&(!seeded||b.area()>=original.regions[source].box.area()*.9))continue;
        recovered[i]=int(original.regions.size());original.regions.push_back(c);
    }
    for(size_t p=0;p<mask.size();++p)if(recovered[split.labels[p]])original.labels[p]=recovered[split.labels[p]];
}
}
