#include "CNative.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/sha.h>
#endif
int mc_open_root(const char *p) { return open(p, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); }
int mc_open_dir(int p, const char *n) { return openat(p,n,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); }
int mc_open_file(int p, const char *n) { return openat(p,n,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC); }
int mc_create_file(int p, const char *n, uint32_t m) { return openat(p,n,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,m); }
static void convert(const struct stat *s, mc_stat *o) {
    o->device=s->st_dev; o->inode=s->st_ino; o->links=s->st_nlink; o->size=s->st_size; o->mode=s->st_mode;
    o->regular=S_ISREG(s->st_mode); o->directory=S_ISDIR(s->st_mode); o->symlink=S_ISLNK(s->st_mode);
#ifdef __APPLE__
    o->modified_seconds=s->st_mtimespec.tv_sec; o->modified_nanoseconds=s->st_mtimespec.tv_nsec;
#else
    o->modified_seconds=s->st_mtim.tv_sec; o->modified_nanoseconds=s->st_mtim.tv_nsec;
#endif
}
int mc_fstat(int fd, mc_stat *o) { struct stat s; int r=fstat(fd,&s); if(!r)convert(&s,o); return r; }
int mc_lstat_at(int p,const char *n,mc_stat *o) { struct stat s; int r=fstatat(p,n,&s,AT_SYMLINK_NOFOLLOW); if(!r)convert(&s,o); return r; }
int mc_fd_path(int fd,char *out,size_t size) {
#ifdef __APPLE__
    if(size<PATH_MAX){errno=ENAMETOOLONG;return -1;} return fcntl(fd,F_GETPATH,out);
#else
    char p[64]; snprintf(p,sizeof p,"/proc/self/fd/%d",fd); ssize_t n=readlink(p,out,size-1);
    if(n<0)return -1; if((size_t)n>=size-1){errno=ENAMETOOLONG;return -1;}out[n]=0;return 0;
#endif
}
int mc_dup(int fd) { return fcntl(fd,F_DUPFD_CLOEXEC,0); }
void mc_sha256(const uint8_t *b,size_t n,uint8_t out[32]) {
#ifdef __APPLE__
    // Callers have a 64 MiB ceiling, below CC_LONG's limit.
    CC_SHA256(b,(CC_LONG)n,out);
#else
    SHA256(b,n,out);
#endif
}
int mc_rename_exclusive(int s,const char *n,int d,const char *t) {
#ifdef __APPLE__
    return renameatx_np(s,n,d,t,RENAME_EXCL);
#else
    errno=ENOTSUP; return -1;
#endif
}
