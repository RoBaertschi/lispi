#include "core.h"
#include "os.h"

#include <dirent.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>

struct Dir_Walker {
    DIR *dir;
};

Dir_Walker *dir_walker_new(String dir) {
    TEMP_ARENA_EMPTY;
    char const *cdir = arena_clone_to_cstr(temp.arena, dir);

    DIR *dir_fd = opendir(cdir);
    if (!dir_fd) {
        return NULL;
    }
    Dir_Walker *walker = calloc(1, sizeof(Dir_Walker));
    walker->dir        = dir_fd;
    return walker;
}

void dir_walker_destroy(Dir_Walker *walker) {
    closedir(walker->dir);
    walker->dir = NULL;
    free(walker);
}

String dir_walker_next(Dir_Walker *walker, Arena *arena) {
    struct dirent *dirent = readdir(walker->dir);
    if (dirent == NULL) {
        return (String) { 0 };
    }
    return arena_clone_from_cstr(arena, dirent->d_name);
}

struct File {
    int fd;
};

File *file_open(String file, File_Open_Flags flags) {
    TEMP_ARENA_EMPTY;
    char const *cfile = arena_clone_to_cstr(temp.arena, file);

    int oflags = 0;
    if (FILE_OPEN_READ & flags && FILE_OPEN_WRITE & flags) {
        oflags |= O_RDWR;
    } else if (FILE_OPEN_READ & flags) {
        oflags |= O_RDONLY;
    } else if (FILE_OPEN_WRITE & flags) {
        oflags |= O_WRONLY;
    }

    if (FILE_OPEN_CREATE & flags) {
        oflags |= O_CREAT;
    }

    if (FILE_OPEN_APPEND & flags) {
        oflags |= O_APPEND;
    }

    if (FILE_OPEN_TRUNCATE & flags) {
        oflags |= O_TRUNC;
    }

    int fd = open(cfile, oflags, 0644);
    if (fd == -1) {
        return NULL;
    }

    File *f = calloc(1, sizeof(File));
    f->fd = fd;
    return f;
}

void file_destroy(File *file) {
    close(file->fd);
    free(file);
}

isize file_read(File *file, u8 *buffer, isize buffer_size) {
    return read(file->fd, buffer, cast(usize)buffer_size);
}
isize file_write(File *file, u8 *buffer, isize buffer_size) {
    return write(file->fd, buffer, cast(usize)buffer_size);
}
