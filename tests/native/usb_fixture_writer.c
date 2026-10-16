/* Test-image generator. This write-enabled FatFs build is never linked into the player. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ff.h"
#include "diskio.h"
static FILE* image;
static unsigned sector_size=512;
static unsigned long long image_size=128ULL*1024*1024;
DSTATUS disk_initialize(BYTE d) { return d?STA_NOINIT:0; }
DSTATUS disk_status(BYTE d) { return disk_initialize(d); }
DRESULT disk_read(BYTE d,BYTE* p,LBA_t at,UINT n) { return !d&&!fseeko(image,at*sector_size,SEEK_SET)&&fread(p,sector_size,n,image)==n?RES_OK:RES_ERROR; }
DRESULT disk_write(BYTE d,const BYTE* p,LBA_t at,UINT n) { return !d&&!fseeko(image,at*sector_size,SEEK_SET)&&fwrite(p,sector_size,n,image)==n?RES_OK:RES_ERROR; }
DRESULT disk_ioctl(BYTE d,BYTE cmd,void* p) {
    if(d) return RES_PARERR;
    switch(cmd) {
    case CTRL_SYNC: return fflush(image)?RES_ERROR:RES_OK;
    case GET_SECTOR_COUNT: *(LBA_t*)p=image_size/sector_size; return RES_OK;
    case GET_SECTOR_SIZE: *(WORD*)p=sector_size; return RES_OK;
    case GET_BLOCK_SIZE: *(DWORD*)p=1; return RES_OK;
    default: return RES_PARERR;
    }
}
void* ff_memalloc(UINT n) { return malloc(n); }
void ff_memfree(void* p) { free(p); }
static void check(int ok,const char* why) { if(!ok) { fprintf(stderr,"fixture: %s\n",why); exit(1); } }
int main(int argc,char** argv) {
    check(argc==6||argc==7,"usage: writer fat|exfat image data filename sector [large]");
    if(argc==7) image_size=8ULL*1024*1024*1024;
    sector_size=atoi(argv[5]); check(sector_size==512||sector_size==4096,"sector size");
    if(argc==6 && sector_size==4096 && strcmp(argv[1],"exfat")!=0) image_size=512ULL*1024*1024;
    image=fopen(argv[2],"w+b"); check(image!=NULL,"open image");
    check(!fseeko(image,image_size-1,SEEK_SET)&&fputc(0,image)!=EOF&&!fflush(image),"image size");
    MKFS_PARM options={0}; options.fmt=(strcmp(argv[1],"exfat")==0?FM_EXFAT:FM_FAT32)|FM_SFD;
    unsigned char work[65536]; check(f_mkfs("0:",&options,work,sizeof(work))==FR_OK,"mkfs");
    FATFS fs; check(f_mount(&fs,"0:",1)==FR_OK,"mount");
    FILE* data=fopen(argv[3],"rb"); check(data!=NULL,"data");
    FIL out; check(f_open(&out,argv[4],FA_CREATE_ALWAYS|FA_WRITE)==FR_OK,"create");
    size_t got; while((got=fread(work,1,sizeof(work),data))>0) { UINT wrote; check(f_write(&out,work,got,&wrote)==FR_OK&&wrote==got,"write"); }
    if(argc==7) {
        check(f_lseek(&out,5ULL*1024*1024*1024+17)==FR_OK,"large seek"); rewind(data);
        while((got=fread(work,1,sizeof(work),data))>0) { UINT wrote; check(f_write(&out,work,got,&wrote)==FR_OK&&wrote==got,"large write"); }
    }
    check(f_close(&out)==FR_OK,"close"); f_mount(NULL,"0:",0); fclose(data); fclose(image); return 0;
}
