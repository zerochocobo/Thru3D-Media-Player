#include "usb_fs.h"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <sys/stat.h>
#include <linux/fs.h>
extern "C" {
#include "ff.h"
#include "diskio.h"
#include "device.h"
#include "volume.h"
#include "inode.h"
#include "attrib.h"
#include "dir.h"
#include "unistr.h"
#include "logging.h"
}
namespace {
struct Volume {
    usb::ReadAt read; uint64_t length = 0, cursor = 0; unsigned sector = 512;
    int slot = -1; FATFS fat{}; ntfs_volume* nt = nullptr;
};
struct File {
    uint64_t owner = 0, length = 0; FIL fat{};
    ntfs_inode* inode = nullptr; ntfs_attr* attr = nullptr;
};
std::recursive_mutex guard;
std::map<uint64_t, std::unique_ptr<Volume>> volumes;
std::map<uint64_t, std::unique_ptr<File>> files;
Volume* slots[10]{};
uint64_t sequence = 0;
uint64_t write_attempts = 0;
void require(bool ok, const char* msg) { if (!ok) throw std::runtime_error(msg); }
std::string safe_path(const std::string& path) {
    require(path.size() <= 8192 && !path.empty() && path[0] == '/' && path.find('\0') == std::string::npos && path.find('\\') == std::string::npos, "Invalid USB path");
    size_t at = 1;
    while (at < path.size()) { auto end = path.find('/', at); auto part = path.substr(at, end-at); require(part != "." && part != ".." && !part.empty(), "Invalid USB path"); if (end == std::string::npos) break; at = end+1; }
    return path;
}
Volume& volume(uint64_t id) { auto i = volumes.find(id); require(i != volumes.end(), "USB storage unavailable"); return *i->second; }
File& file(uint64_t id) { auto i = files.find(id); require(i != files.end(), "USB reader closed"); return *i->second; }
bool read_at(Volume* v, uint64_t at, void* data, size_t count) { return at <= v->length && count <= v->length-at && v->read(at,data,count); }
std::string fat_path(Volume& v, const std::string& path) { return std::to_string(v.slot) + ":" + safe_path(path); }
int nd_open(ntfs_device* d, int flags) { if ((flags&O_ACCMODE) != O_RDONLY) { errno=EROFS; return -1; } NDevSetReadOnly(d); NDevSetOpen(d); return 0; }
int nd_close(ntfs_device* d) { NDevClearOpen(d); return 0; }
s64 nd_seek(ntfs_device* d, s64 off, int whence) {
    auto* v = static_cast<Volume*>(d->d_private); s64 base = whence==SEEK_SET?0:whence==SEEK_CUR?static_cast<s64>(v->cursor):whence==SEEK_END?static_cast<s64>(v->length):-1;
    if (base<0 || off < -base || (off>0 && static_cast<uint64_t>(off)>v->length-static_cast<uint64_t>(base))) { errno=EINVAL; return -1; }
    v->cursor=base+off; return v->cursor;
}
s64 nd_pread(ntfs_device* d, void* b, s64 n, s64 at) {
    auto* v=static_cast<Volume*>(d->d_private);
    if (n<0 || at<0 || static_cast<uint64_t>(at)>v->length) { errno=EINVAL; return -1; }
    auto count=std::min<uint64_t>(n,v->length-at);
    if (!read_at(v,at,b,count)) { errno=EIO; return -1; } return count;
}
s64 nd_read(ntfs_device* d, void* b, s64 n) { auto* v=static_cast<Volume*>(d->d_private); s64 got=nd_pread(d,b,n,v->cursor); if(got>0) v->cursor+=got; return got; }
s64 nd_write(ntfs_device*, const void*, s64) { ++write_attempts; errno=EROFS; return -1; }
s64 nd_pwrite(ntfs_device*, const void*, s64, s64) { ++write_attempts; errno=EROFS; return -1; }
int nd_sync(ntfs_device*) { return 0; }
int nd_stat(ntfs_device* d, struct stat* s) { auto* v=static_cast<Volume*>(d->d_private); std::memset(s,0,sizeof(*s)); s->st_mode=S_IFREG|0444; s->st_size=v->length; s->st_blksize=v->sector; s->st_blocks=v->length/512; return 0; }
int nd_ioctl(ntfs_device* d, unsigned long code, void* arg) {
    auto* v=static_cast<Volume*>(d->d_private);
    if(code==BLKGETSIZE64) { *static_cast<uint64_t*>(arg)=v->length; return 0; }
    if(code==BLKGETSIZE) { *static_cast<unsigned long*>(arg)=v->length/512; return 0; }
    if(code==BLKSSZGET || code==BLKBSZGET) { *static_cast<int*>(arg)=v->sector; return 0; }
    errno=ENOTTY; return -1;
}
ntfs_device_operations ops{nd_open,nd_close,nd_seek,nd_read,nd_write,nd_pread,nd_pwrite,nd_sync,nd_stat,nd_ioctl};
ntfs_inode* inode(Volume& v, const std::string& path) {
    auto* n=ntfs_pathname_to_inode(v.nt,nullptr,safe_path(path).c_str());
    require(n!=nullptr,"USB file unavailable");
    if (n->flags & (FILE_ATTR_REPARSE_POINT|FILE_ATTR_ENCRYPTED)) { ntfs_inode_close(n); throw std::runtime_error("Unsupported NTFS file"); } return n;
}
struct Listing { Volume* volume; std::vector<usb::Entry> entries; bool failed=false; };
int nt_entry(void* opaque,const ntfschar* name,const int length,const int name_type,const s64,const MFT_REF ref,const unsigned type) {
    if(name_type==FILE_NAME_DOS) return 0;
    auto* listing=static_cast<Listing*>(opaque);
    if(listing->entries.size()>=100000) { listing->failed=true; return -1; }
    char* text=nullptr;
    if(ntfs_ucstombs(name,length,&text,0)<0) { listing->failed=true; return -1; }
    std::string value=text; free(text);
    if(value=="." || value==".." || value.empty()) return 0;
    auto* n=ntfs_inode_open(listing->volume->nt,ref);
    if(!n) { listing->failed=true; return -1; }
    if(!(n->flags&(FILE_ATTR_REPARSE_POINT|FILE_ATTR_ENCRYPTED|FILE_ATTR_SYSTEM))) {
        bool dir=type==NTFS_DT_DIR;
        listing->entries.push_back({value,dir,dir?0:static_cast<uint64_t>(std::max<s64>(0,n->data_size))});
    }
    ntfs_inode_close(n); return 0;
}
}
extern "C" {
DSTATUS disk_initialize(BYTE p) { return p<10 && slots[p]?0:STA_NOINIT; }
DSTATUS disk_status(BYTE p) { return disk_initialize(p); }
DRESULT disk_read(BYTE p,BYTE* data,LBA_t sector,UINT count) { if(p>=10||!slots[p]) return RES_NOTRDY; auto* v=slots[p]; if(sector>v->length/v->sector || count>v->length/v->sector-sector) return RES_PARERR; return read_at(v,sector*v->sector,data,static_cast<size_t>(count)*v->sector)?RES_OK:RES_ERROR; }
DRESULT disk_ioctl(BYTE p,BYTE code,void* arg) { if(p>=10||!slots[p]) return RES_NOTRDY; if(code==GET_SECTOR_SIZE) { *static_cast<WORD*>(arg)=slots[p]->sector; return RES_OK; } return RES_PARERR; }
void* ff_memalloc(UINT n) { return malloc(n); }
void ff_memfree(void* p) { free(p); }
}
namespace usb {
uint64_t rejected_writes() { std::lock_guard<std::recursive_mutex> lock(guard); return write_attempts; }
uint64_t mount(ReadAt reader,uint64_t length,unsigned sector,bool is_ntfs) {
    std::lock_guard<std::recursive_mutex> lock(guard);
    require(length>0 && length<=INT64_MAX && (sector==512||sector==1024||sector==2048||sector==4096),"Invalid USB volume geometry");
    auto v=std::make_unique<Volume>(); v->read=std::move(reader); v->length=length; v->sector=sector;
    if(is_ntfs) {
        ntfs_log_set_handler(ntfs_log_handler_null);
        ntfs_set_char_encoding("UTF-8");
        auto* dev=ntfs_device_alloc("thru3d-usb",0,&ops,v.get()); require(dev,"NTFS device allocation failed");
        v->nt=ntfs_device_mount(dev,NTFS_MNT_RDONLY|NTFS_MNT_FORENSIC);
        if(!v->nt) { ntfs_device_free(dev); throw std::runtime_error("NTFS volume unavailable"); }
    } else {
        for(int i=0;i<10;i++) if(!slots[i]) { v->slot=i; slots[i]=v.get(); break; }
        require(v->slot>=0,"Too many open USB volumes");
        auto path=std::to_string(v->slot)+":";
        if(f_mount(&v->fat,path.c_str(),1)!=FR_OK) { f_mount(nullptr,path.c_str(),0); slots[v->slot]=nullptr; throw std::runtime_error("FAT volume unavailable"); }
    }
    uint64_t id=++sequence; volumes.emplace(id,std::move(v)); return id;
}
std::vector<Entry> list(uint64_t id,const std::string& path) {
    std::lock_guard<std::recursive_mutex> lock(guard); auto& v=volume(id);
    std::vector<Entry> out;
    if(v.nt) {
        auto* dir=inode(v,path); Listing listing{&v,{}}; s64 position=0;
        int result=ntfs_readdir(dir,&position,&listing,nt_entry); ntfs_inode_close(dir);
        require(result==0 && !listing.failed,"NTFS directory read failed"); out=std::move(listing.entries);
    } else {
        DIR dir{}; FILINFO info{};
        require(f_opendir(&dir,fat_path(v,path).c_str())==FR_OK,"USB directory unavailable");
        FRESULT result=FR_OK;
        while((result=f_readdir(&dir,&info))==FR_OK && info.fname[0]) {
            if(out.size()>=100000) { result=FR_INT_ERR; break; }
            if(!(info.fattrib&AM_SYS)) out.push_back({info.fname,(info.fattrib&AM_DIR)!=0,info.fsize});
        }
        f_closedir(&dir); require(result==FR_OK,"FAT directory read failed");
    }
    return out;
}
uint64_t open(uint64_t id,const std::string& path) {
    std::lock_guard<std::recursive_mutex> lock(guard); auto& v=volume(id); auto f=std::make_unique<File>(); f->owner=id;
    if(v.nt) { f->inode=inode(v,path); f->attr=ntfs_attr_open(f->inode,AT_DATA,AT_UNNAMED,0); if(!f->attr) { ntfs_inode_close(f->inode); throw std::runtime_error("NTFS data unavailable"); } f->length=f->attr->data_size; }
    else { require(f_open(&f->fat,fat_path(v,path).c_str(),FA_READ)==FR_OK,"USB file unavailable"); f->length=f_size(&f->fat); }
    auto key=++sequence; files.emplace(key,std::move(f)); return key;
}
uint64_t size(uint64_t id) { std::lock_guard<std::recursive_mutex> lock(guard); return file(id).length; }
size_t read(uint64_t id,uint64_t offset,void* data,size_t n) {
    std::lock_guard<std::recursive_mutex> lock(guard); auto& f=file(id); volume(f.owner); require(offset<=f.length,"USB read outside file"); n=std::min<uint64_t>(n,f.length-offset); require(n<=1024*1024,"USB read too large");
    if(!n) return 0;
    if(f.attr) { s64 count=ntfs_attr_pread(f.attr,offset,n,data); require(count>=0,"NTFS read failed"); return count; }
    require(f_lseek(&f.fat,offset)==FR_OK && f_tell(&f.fat)==offset,"USB seek failed"); UINT got=0; require(f_read(&f.fat,data,n,&got)==FR_OK,"FAT read failed"); return got;
}
void close_file(uint64_t id) {
    std::lock_guard<std::recursive_mutex> lock(guard); auto i=files.find(id); if(i==files.end()) return; auto& f=*i->second;
    if(f.attr) { ntfs_attr_close(f.attr); ntfs_inode_close(f.inode); } else f_close(&f.fat); files.erase(i);
}
void close_volume(uint64_t id) {
    std::lock_guard<std::recursive_mutex> lock(guard); auto i=volumes.find(id); if(i==volumes.end()) return;
    for(auto f=files.begin();f!=files.end();) { auto key=f->first; bool owned=f->second->owner==id; ++f; if(owned) close_file(key); }
    auto& v=*i->second;
    if(v.nt) ntfs_umount(v.nt,FALSE); else { auto path=std::to_string(v.slot)+":"; f_mount(nullptr,path.c_str(),0); slots[v.slot]=nullptr; }
    volumes.erase(i);
}
}
