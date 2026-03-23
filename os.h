#ifndef OS_H
#define OS_H

#include "core.h"

typedef struct Dir_Walker Dir_Walker;
Dir_Walker *dir_walker_new(String dir);
void dir_walker_destroy(Dir_Walker *walker);
String dir_walker_next(Dir_Walker *walker, Arena *arena);

typedef enum File_Open_Flags {
    FILE_OPEN_READ     = BIT(0),
    FILE_OPEN_WRITE    = BIT(1),
    FILE_OPEN_CREATE   = BIT(2),
    FILE_OPEN_APPEND   = BIT(3),
    FILE_OPEN_TRUNCATE = BIT(4),
} File_Open_Flags;

typedef struct File File;
File *file_open(String file, File_Open_Flags flags);
void file_destroy(File *file);
isize file_read(File *file, u8 *buffer, isize buffer_size);
isize file_write(File *file, u8 *buffer, isize buffer_size);

#endif // OS_H
