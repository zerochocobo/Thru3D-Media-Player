#include "../../native/mpv/mvc/mvc_config.h"
#undef NDEBUG
#include <assert.h>
#include <stdio.h>

int main(void)
{
    const uint8_t avc[] = {1,100,0,41,255,225,0,2,0x67,0x80,1,0,2,0x68,0x80,253,248,248,0};
    const uint8_t mvc[] = {1,128,0,41,255,2,0,2,0x67,0x80,0,2,0x6f,0x80,1,0,2,0x68,0x80};
    ThruMvcConfig config;
    assert(thru_mvc_config(avc,sizeof(avc),NULL,0,0,&config)==0);
    assert(thru_mvc_config(avc,sizeof(avc),mvc,sizeof(mvc),1,&config)==1);
    assert(config.length_size==4 && config.base_right==1);
    for(size_t i=0;i<15;++i)
        assert(thru_mvc_config(avc,i,mvc,sizeof(mvc),0,&config)<0);
    for(size_t i=0;i<sizeof(mvc);++i)
        assert(thru_mvc_config(avc,sizeof(avc),mvc,i,0,&config)<0);
    uint8_t legacy[128]={0};
    memcpy(legacy,avc,sizeof(avc));
    thru_mvc_put32(legacy+sizeof(avc),sizeof(mvc)+4);
    memcpy(legacy+sizeof(avc)+4,"mvcC",4);
    memcpy(legacy+sizeof(avc)+8,mvc,sizeof(mvc));
    size_t size=sizeof(avc)+8+sizeof(mvc);
    assert(thru_mvc_config(legacy,size,NULL,0,0,&config)==1);
    uint8_t wrapper[256]={0};
    memcpy(wrapper,"T3MV",4);wrapper[4]=1;
    thru_mvc_put32(wrapper+8,sizeof(avc));thru_mvc_put32(wrapper+12,sizeof(mvc));
    memcpy(wrapper+16,avc,sizeof(avc));memcpy(wrapper+16+sizeof(avc),mvc,sizeof(mvc));
    size=16+sizeof(avc)+sizeof(mvc);
    assert(thru_mvc_unpack(wrapper,size,&config)==0);
    for(size_t i=0;i<size;++i) assert(thru_mvc_unpack(wrapper,i,&config)<0);
    wrapper[5]=2;assert(thru_mvc_unpack(wrapper,size,&config)<0);wrapper[5]=0;
    wrapper[8]=255;assert(thru_mvc_unpack(wrapper,size,&config)<0);wrapper[8]=0;
    wrapper[16+sizeof(avc)+4]=254;assert(thru_mvc_unpack(wrapper,size,&config)<0);
    puts("MVC configuration: mapping, legacy, wrapper, truncation and length/eye bounds passed");
}
