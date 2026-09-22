#ifndef LUTI_NATIVE_H
#define LUTI_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct {
    uint64_t device, inode, links;
    int64_t size, modified_seconds, modified_nanoseconds;
    uint32_t mode;
    int regular, directory, symlink;
} mc_stat;
int mc_open_root(const char *path);
int mc_open_dir(int parent, const char *name);
int mc_open_file(int parent, const char *name);
int mc_create_file(int parent, const char *name, uint32_t mode);
int mc_fstat(int fd, mc_stat *out);
int mc_lstat_at(int parent, const char *name, mc_stat *out);
int mc_fd_path(int fd, char *out, size_t size);
int mc_dup(int fd);
void mc_sha256(const uint8_t *bytes, size_t count, uint8_t out[32]);
int mc_rename_exclusive(int source, const char *name, int destination, const char *target);
#endif
