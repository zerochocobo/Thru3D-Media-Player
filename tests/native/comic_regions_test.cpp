#include "comic_regions.h"
#include <cassert>
#include <iostream>
#undef assert
#define assert(condition) do { if(!(condition)){std::cerr<<"FAIL line "<<__LINE__<<"\n";return 1;} } while(false)
using namespace comic;
int main(){
    const int w=400,h=240;std::vector<uint8_t> mask(w*h,1);
    auto rectangle=[&](int x0,int y0,int x1,int y1){
        for(int x=x0;x<=x1;++x)mask[y0*w+x]=mask[y1*w+x]=0;
        for(int y=y0;y<=y1;++y)mask[y*w+x0]=mask[y*w+x1]=0;
    };
    // Two balloon outlines have gaps to the SAME exterior component. Keeping
    // only its largest opened child loses both (the largest child is paper).
    rectangle(15,15,90,115);rectangle(130,25,210,110);
    for(int y=60;y<63;++y)mask[y*w+15]=1;
    mask[60*w+210]=1;
    auto regions=components(mask,w,h);
    assert(regions.labels[50*w+40]==regions.labels[50*w+170]);
    for(int radius:{1,2,3})recoverPockets(regions,mask,w,h,radius);
    int first=regions.labels[50*w+40],second=regions.labels[50*w+170],outside=regions.labels[5*w+5];
    assert(first&&second&&first!=second&&first!=outside&&second!=outside);
    assert(bounded(regions.regions[first],w,h)&&bounded(regions.regions[second],w,h));
    assert(!bounded(regions.regions[outside],w,h));
    // Page-edge opening must never close an artificial frame around paper.
    std::vector<uint8_t> blank(w*h,1);auto page=components(blank,w,h);
    for(int radius:{1,2,3})recoverPockets(page,blank,w,h,radius);
    assert(page.regions.size()==2&&!bounded(page.regions[1],w,h));
    // Dense glyphs split light spaces after erosion. An already closed bubble
    // must retain its original identity, pixels and internal narrow corridors.
    std::fill(mask.begin(),mask.end(),uint8_t(1));rectangle(60,30,120,90);
    for(int y=32;y<88;++y)if(y!=60)mask[y*w+90]=0;
    auto tight=components(mask,w,h);int id=tight.labels[50*w+70];auto original=tight.labels;
    for(int radius:{1,2,3})recoverPockets(tight,mask,w,h,radius);
    assert(tight.labels==original&&tight.labels[50*w+110]==id);
    // Light and dark topology are dual: diagonally touching light pockets
    // should not leak through a diagonal ink outline (4-connected light).
    std::vector<uint8_t> diagonal{1,0,0,1};
    assert(components(diagonal,2,2,nullptr,4).regions.size()==3);
    assert(components(diagonal,2,2).regions.size()==2);
    std::vector<std::pair<int,int>> rectangle_rows(100,{10,110}),cross_rows;
    for(int y=0;y<100;++y)cross_rows.push_back(y<30||y>=70?std::pair<int,int>{40,80}:std::pair<int,int>{10,110});
    assert(silhouetteSolidity(rectangle_rows)==1);
    assert(silhouetteSolidity(cross_rows)<.8);
    assert(borderArtwork({{0,20,100,140},1000,0},150,160,30));
    assert(!borderArtwork({{12,20,40,45},200,0},150,160,30));
    assert(!borderArtwork({{0,20,20,45},200,0},150,160,30));
    std::vector<std::pair<int,int>> panel_rows,rounded_rows;
    for(int y=0;y<100;++y){panel_rows.push_back({y<60?0:y-60,100});
        int inset=y<50?50-y:y-49;rounded_rows.push_back({inset,100-inset});}
    assert(sparsePanelCorner(panel_rows,{0,0,100,100},{60,60,75,75},8000));
    assert(!sparsePanelCorner(panel_rows,{0,0,100,100},{10,10,80,80},8000));
    assert(!sparsePanelCorner(rounded_rows,{0,0,100,100},{40,40,55,55},7000));
    assert(rectangularRim(rectangle_rows,100));
    assert(!rectangularRim(rounded_rows,100));
    std::vector<std::pair<int,int>> capsule(400,{0,20});
    capsule[0]=capsule.back()={8,12};capsule[1]=capsule[398]={5,15};capsule[2]=capsule[397]={3,17};
    assert(!rectangularRim(capsule,20));
    Component clipped{{0,60,45,150},3000,0};
    assert(!bounded(clipped,w,h)&&clippedBalloon(clipped,w,h));
    assert(clipContainsText(clipped,{12,80,35,130},w,h,20));
    assert(!clipContainsText(clipped,{1,80,35,130},w,h,20));
    assert(!clippedBalloon({{0,0,45,150},3000,0},w,h));
    assert(!clippedBalloon({{0,0,w,h},w*h,0},w,h));
    // Opening removes narrow white spaces INSIDE dense glyphs. Protect the
    // filled silhouette, not those internal white pixels, while separating a
    // small balloon from a bounded panel background through a narrow gap.
    std::fill(mask.begin(),mask.end(),uint8_t(1));
    rectangle(20,20,150,105);rectangle(70,30,125,95);mask[60*w+70]=1;
    Rect seed{88,43,106,84};
    for(int y=seed.y0;y<seed.y1;++y)for(int x=seed.x0;x<seed.x1;++x)
        if(x%4==0||y%5==0)mask[y*w+x]=0;
    auto dense=components(mask,w,h);int panel=dense.labels[25*w+25];
    assert(dense.labels[35*w+80]==panel&&bounded(dense.regions[panel],w,h));
    recoverPockets(dense,mask,w,h,1,{seed});
    int balloon=dense.labels[35*w+80];
    assert(balloon!=panel&&bounded(dense.regions[balloon],w,h));
    assert(intersection(seed,dense.regions[balloon].box)==seed.area());
    // Conversely, a contour cutting a text core must leave that seed's
    // component unchanged even if its bounding rectangle intersects the core.
    auto unsafe=components(mask,w,h);int prior=unsafe.labels[35*w+80];
    recoverPockets(unsafe,mask,w,h,1,{{65,43,90,84}});
    assert(unsafe.labels[35*w+80]==prior);
    // Two offset lobes form a concave connected bubble. Each paragraph's
    // lobe remains convex, unlike an unrelated concavity inside a text span.
    std::vector<std::pair<int,int>> joined;
    for(int y=0;y<140;++y){int left=y<60?60:y>=80?0:60-(y-60)*3;joined.push_back({left,left+60});}
    std::vector<Rect> paragraphs{{70,20,95,50},{15,90,35,125}};
    assert(silhouetteSolidity(joined)<.8&&paragraphLobes(joined,0,paragraphs));
    assert(!paragraphLobes(joined,0,{{70,20,95,110},{15,100,35,125}}));
    assert(!paragraphLobes(joined,0,{paragraphs[0]}));
    auto broken=joined;broken[70]={0,0};assert(!paragraphLobes(broken,0,paragraphs));
    auto pinched=joined;for(int y=20;y<45;++y)pinched[y]={85,95};
    assert(!paragraphLobes(pinched,0,paragraphs));
    // Page margin is measured in single-line print size, not the combined
    // width of several columns. Truly clipped glyphs must still fail.
    Component bottom{{50,h-100,190,h},10000,0};
    assert(clipContainsText(bottom,{70,h-80,90,h-8},w,h,20));
    assert(!clipContainsText(bottom,{70,h-80,170,h-8},w,h,100));
    assert(!clipContainsText(bottom,{70,h-80,90,h-2},w,h,20));
    std::cout<<"comic_regions: 13 topology/shape/ink/clip/seed/panel/rim/lobe cases passed\n";
}
