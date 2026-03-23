#ifndef OS_H
#define OS_H

#include "core.h"

typedef struct Dir_Walker Dir_Walker;
Dir_Walker dir_walker_new(Arena *arena, String dir);
void dir_walker_destroy(Dir_Walker *walker);

String dir_walker_next(Dir_Walker *walker, Arena *arena);

#endif // OS_H
