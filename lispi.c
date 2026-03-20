// Small lisp implementation to learn lisp
// Example (+ 1 2)

#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdnoreturn.h>
#include <string.h>

#define cast(T) (T)
#define zero(v) memset((v), 0, sizeof(*(v)))

typedef uint8_t   u8;
typedef int32_t   i32;
typedef size_t    isize;
typedef ptrdiff_t usize;
typedef uintptr_t uintptr;

typedef struct Arena_Block {
    struct Arena_Block *next;
    void               *memory;
    usize              cap;
    usize              len;
} Arena_Block;

noreturn void fatalf(char const *format, ...) {
    va_list list;
    va_start(list, format);

    vfprintf(stderr, format, list);

    va_end(list);
    exit(1);
}

#define ALIGNMENT_PADDING(value, alignment) ((alignment) - ((value) & ((alignment) - 1))) & ((alignment) - 1)

void *arena_block_alloc_align(Arena_Block *block, isize size, usize align) {
    if (size <= 0) {
        fatalf("Invalid negative or zero size supplied to arena_block_alloc_align\n");
    }

    usize unsigned_size     = cast(usize)size;
    usize padding           = ALIGNMENT_PADDING(block->len, align);

    if (block->len + padding + unsigned_size > block->cap) {
        return NULL;
    }

    block->len += padding;
    void *data  = cast(void*)(cast(uintptr)block->memory) + block->len;
    block->len += size;
    return data;
}

void *arena_block_alloc(Arena_Block *block, isize size) {
    return arena_block_alloc_align(block, size, 16);
}

Arena_Block *arena_block_new(usize size) {
    Arena_Block *block = calloc(1, sizeof(Arena_Block) + size);
    if (!block) {
        fatalf("OOM\n");
    }
    block->memory = cast(void*) (cast(uintptr)block) + sizeof(Arena_Block);
    block->cap    = size;
    return block;
}

Arena_Block *arena_block_new_min(usize default_size, usize size) {
    usize block_size = default_size < size ? size : default_size;
    return arena_block_new(block_size);
}

typedef struct Arena {
    Arena_Block *first;
    Arena_Block *current;
    usize       default_mem_block_size;
    usize       len;
} Arena;

void *arena_alloc_align(Arena *arena, isize size, usize align) {
    if (size <= 0) {
        fatalf("Invalid negative or zero size supplied to arena_block_alloc_align\n");
    }

    if (!arena->current) {
        if (!arena->default_mem_block_size) {
            arena->default_mem_block_size = 1024 * 1024 * 64; // NOTE: 64MB
        }

        Arena_Block *block = arena_block_new_min(arena->default_mem_block_size, size);
        arena->current = block;
        arena->first   = block;

        void *data = arena_block_alloc_align(arena->current, size, align);
        if (data) {
            arena->len += size;
        }
        return data;
    }

    void *data = arena_block_alloc_align(arena->current, size, align);
    if (!data) {
        // Not enough space in block
        arena->current->next = arena_block_new_min(arena->default_mem_block_size, size);
        arena->current = arena->current->next;
        data = arena_block_alloc_align(arena->current, size, align);
    }

    if (data) {
        arena->len += size;
    }
    return data;
}

void *arena_alloc(Arena *arena, isize size) {
    return arena_alloc_align(arena, size, 16);
}

void arena_reset_to(Arena *arena, usize pos) {
    Arena_Block *block = arena->current;

    for (; block && pos > block->len; block = block->next) {
        pos -= block->len;
    }

    if (!block) {
        // NOTE: pos outside of allocated blocks
        return;
    }

    if (block->len > pos) {
        memset(cast(void*)(cast(uintptr)block->memory + pos), 0, block->len - pos);
        block->len = pos;
    }

    Arena_Block *current_block = block->next;
    block->next                = NULL;
    Arena_Block *next_block    = current_block ? current_block->next : NULL;
    while (current_block) {
        free(current_block->memory);
        if (!next_block) {
            break;
        }

        current_block = next_block;
        next_block    = next_block->next;
    }
}

typedef struct Arena_Temp {
    Arena *arena;
    usize pos;
} Arena_Temp;

Arena_Temp arena_get_temp(Arena *arena) {
    return (Arena_Temp){
        .arena = arena,
        .pos   = arena->len,
    };
}

void arena_reset_temp(Arena_Temp temp) {
    arena_reset_to(temp.arena, temp.pos);
}

void arena_temp_cleanup(Arena_Temp *temp) {
    arena_reset_temp(*temp);
}

void free_wrapper(void *data) {
    free(*(cast(void**)data));
}

#define ARENA_TEMP_GUARD(temp, arena) __attribute__((cleanup(arena_temp_cleanup))) Arena_Temp temp = arena_get_temp(arena);
#define TEMP_ARENA_COUNT 2
__thread Arena temp_arenas[TEMP_ARENA_COUNT];

Arena *temp_arena_get(Arena **collisions, isize collision_count) {
    for (isize i = 0; i < TEMP_ARENA_COUNT; i++) {
        for (isize j = 0; j < collision_count; j++) {
            if (collisions[j] != &temp_arenas[i]) {
                return &temp_arenas[i];
            }
        }
    }

    fatalf("Could not find temp arena.\n");
    return NULL;
}
#define TEMP_ARENA_VAR(temp, ...) ARENA_TEMP_GUARD(temp, temp_arena_get((Arena*[]){ __VA_ARGS__ }, sizeof(((Arena*[]){ __VA_ARGS__ })) / sizeof(((Arena*[]){ __VA_ARGS__ })[0])))
#define TEMP_ARENA(...) TEMP_ARENA_VAR(temp, __VA_ARGS__)

typedef struct Context {
    Arena        symbol_strings;
    Arena        things;
    struct Thing *dead_things;

    struct Thing *nil;
} Context;

typedef enum Thing_Type {
    THING_NUM,
    THING_CONS,
    THING_SYMBOL,

    THING_NIL,

    // Unused and free to use
    THING_DEAD,
} Thing_Type;

typedef struct Thing {
    Thing_Type type;
    union {
        i32 num;
        struct {
            struct Thing *car;
            struct Thing *cdr;
        } cons;
        struct {
            u8    *name;
            isize name_len;
        } symbol;
        struct Thing *next_dead;
    };
} Thing;

Thing *thing_new(Context *ctx, Thing_Type type) {
    if (ctx->dead_things) {
        Thing *new_thing = ctx->dead_things;
        ctx->dead_things = ctx->dead_things->next_dead;
        zero(new_thing);
        new_thing->type = type;
        return new_thing;
    }

    Thing *thing = arena_alloc_align(&ctx->things, sizeof(Thing), sizeof(struct Thing *));
    thing->type = type;
    return thing;
}

Thing *thing_num(Context *ctx, i32 num) {
    Thing *thing = thing_new(ctx, THING_NUM);
    thing->num = num;
    return thing;
}

Thing *thing_cons(Context *ctx, Thing *car, Thing *cdr) {
    Thing *thing = thing_new(ctx, THING_CONS);
    thing->cons.car = car;
    thing->cons.cdr = cdr;
    return thing;
}

Thing *thing_symbol(Context *ctx, char const *name) {
    Thing *thing           = thing_new(ctx, THING_SYMBOL);
    isize name_len         = strlen(name);
    thing->symbol.name     = arena_alloc_align(&ctx->symbol_strings, name_len, 1);
    thing->symbol.name_len = name_len;
    memcpy(thing->symbol.name, name, name_len);
    return thing;
}

void thing_kill(Context *ctx, Thing *thing) {
    thing->type      = THING_DEAD;
    thing->next_dead = ctx->dead_things;
    ctx->dead_things = thing;
}

void print(Thing *t) {
    switch (t->type) {
    case THING_NUM:
        printf("%d", t->num);
        break;
    case THING_CONS:
        printf("(");
        print(t->cons.car);
        printf(" . ");
        print(t->cons.cdr);
        printf(")");
        break;
    case THING_SYMBOL:
        printf(":%.*s", (int)t->symbol.name_len, t->symbol.name);
        break;
    case THING_NIL:
        printf("nil");
        break;
    case THING_DEAD:
        printf("<dead>");
        break;
    }
}

// Parser

// FILE *input;
//
// Thing *read(void) {
//     u8 c = getc(input);
//     switch (c) {
//         case '(': { // start list
//             Thing *head = nil;
//             Thing *current = nil;
//             while (1) {
//                 Thing *next = read();
//                 if (next == nil) {
//                     break;
//                 }
//
//                 if (head == nil) {
//                     head = thing_cons(next, nil);
//                     current = head;
//                 } else {
//                     current = (current->cons.cdr = thing_cons(next, nil));
//                 }
//             }
//             return head;
//         }
//     default:
//         fatalf("Unexpected %c", c);
//     }
// }

void ctx_init(Context *ctx) {
    ctx->nil = thing_new(ctx, THING_NIL);
}

int main(void) {
    Context ctx = { 0 };
    ctx_init(&ctx);

    print(thing_cons(&ctx, thing_num(&ctx, 23), thing_cons(&ctx, thing_symbol(&ctx, "test"), ctx.nil)));
}
