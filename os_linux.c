#include "core.h"
#include "os.h"

#include <dirent.h>
#include <unistd.h>

struct Dir_Walker {
    DIR *dir;
};

Dir_Walker dir_walker_new(Arena *arena, String dir) {
    TEMP_ARENA(arena);
    opendir();
}
void dir_walker_destroy(Dir_Walker *walker);

String dir_walker_next(Dir_Walker *walker, Arena *arena);
