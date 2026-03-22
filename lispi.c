// Small lisp implementation to learn lisp
// Example (+ 1 2)

#include <assert.h>
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
typedef uint32_t  u32;
typedef i32       b32;
typedef size_t    isize;
typedef ptrdiff_t usize;
typedef uintptr_t uintptr;

#define false 0
#define true 1

#define global static

typedef struct String {
    u8 const *data;
    isize     len;
} String;

#define STR(...) (String){ .data = cast(u8 const*)(__VA_ARGS__), .len = sizeof(__VA_ARGS__)-1 }

b32 string_eq(String a, String b) {
    if (a.len != b.len) {
        return false;
    }

    for (isize i = 0; i < a.len; i++) {
        if (a.data[i] != b.data[i]) {
            return false;
        }
    }

    return true;
}

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
    void *data  = cast(void*)((cast(uintptr)block->memory) + block->len);
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
    block->memory = cast(void*)((cast(uintptr)block) + sizeof(Arena_Block));
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
        free(current_block);
        if (!next_block) {
            break;
        }

        current_block = next_block;
        next_block    = next_block->next;
    }
}

void arena_destroy(Arena *arena) {
    Arena_Block *current_block = arena->first;
    Arena_Block *next_block    = current_block ? current_block->next : NULL;
    while (current_block) {
        free(current_block);
        if (!next_block) {
            break;
        }

        current_block = next_block;
        next_block    = next_block->next;
    }

    zero(arena);
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

#define ARENA_TEMP_GUARD(temp, arena) __attribute__((cleanup(arena_temp_cleanup))) Arena_Temp temp = arena_get_temp(arena);
#define TEMP_ARENA_COUNT 2
__thread Arena temp_arenas[TEMP_ARENA_COUNT];

Arena *temp_arena_get(Arena **collisions, isize collision_count) {
    for (isize i = 0; i < TEMP_ARENA_COUNT; i++) {
        for (isize j = 0; j < collision_count; j++) {
            if (collisions[j] == &temp_arenas[i]) {
                goto skip;
            }
        }

        return &temp_arenas[i];
skip:
        ;
    }

    fatalf("Could not find temp arena.\n");
    return NULL;
}

void temp_arenas_destroy(void) {
    for (isize i = 0; i < TEMP_ARENA_COUNT; i++) {
        arena_destroy(&temp_arenas[i]);
    }
}

#define TEMP_ARENA_VAR(temp, ...) ARENA_TEMP_GUARD(temp, temp_arena_get((Arena*[]){ __VA_ARGS__ }, sizeof(((Arena*[]){ __VA_ARGS__ })) / sizeof(((Arena*[]){ __VA_ARGS__ })[0])))
#define TEMP_ARENA(...) TEMP_ARENA_VAR(temp, __VA_ARGS__)
#define TEMP_ARENA_EMPTY ARENA_TEMP_GUARD(temp, temp_arena_get(NULL, 0))

// Bit array

void bits_clear(u32 *bits, isize from, isize to) {
    isize from_index  = from / 32;
    isize to_index    = to / 32;
    isize from_offset = from % 32;
    isize to_offset   = to % 32;

    if (from_index == to_index) {
        u32 *ptr = &bits[from_index];
        u32 mask = ((cast(u32)1 << (to_offset - from_offset)) - cast(u32)1) << from_offset;
        *ptr &= ~mask;
        return;
    }

    u32 from_mask = ((cast(u32)1 << from_offset) - cast(u32)1);
    bits[from_index] &= from_mask;

    u32 to_mask = ~((cast(u32)1 << to_offset) - cast(u32)1);
    bits[to_index] &= to_mask;

    for (isize i = from_index + 1; i < to_index; i++) {
        bits[i] = 0;
    }
}

void bits_fill(u32 *bits, isize from, isize to) {
    isize from_index  = from / 32;
    isize to_index    = to / 32;
    isize from_offset = from % 32;
    isize to_offset   = to % 32;

    if (from_index == to_index) {
        u32 *ptr = &bits[from_index];
        u32 mask = ((cast(u32)1 << (to_offset - from_offset)) - cast(u32)1) << from_offset;
        *ptr |= mask;
        return;
    }

    u32 from_mask = ((cast(u32)1 << from_offset) - cast(u32)1);
    bits[from_index] |= ~from_mask;

    u32 to_mask = ((cast(u32)1 << to_offset) - cast(u32)1);
    bits[to_index] |= to_mask;

    for (isize i = from_index + 1; i < to_index; i++) {
        bits[i] = ~cast(u32)0;
    }
}

void bits_set_bit(u32 *bits, isize i) {
    isize index    = i / 32;
    isize actual_i = i % 32;

    bits[index] |= cast(u32)1 << actual_i;
}

void bits_clear_bit(u32 *bits, isize i) {
    isize index    = i / 32;
    isize actual_i = i % 32;

    bits[index] &= ~(cast(u32)1 << actual_i);
}

#define PAGE_SIZE 1024 * 4

typedef struct Bit_Array {
    struct Bit_Array *next;
    isize            len;
    u32              bits[];
} Bit_Array;

global isize const bit_array_size = PAGE_SIZE;
global isize const bit_array_bits_size = bit_array_size - offsetof(Bit_Array, bits);
global isize const bit_array_bits_size_bits = bit_array_bits_size * 8;

// NOTE: array_arena is used to extend the Bit_Array
void bit_array_set(Arena *array_arena, Bit_Array *array, isize pos) {
    isize arrays   = pos / bit_array_bits_size_bits;
    isize actual_i = pos % bit_array_bits_size_bits;

    Bit_Array *found_array = array;
    for (isize i = 0; i < arrays; i++) {
        if (found_array->len < bit_array_bits_size_bits) {
            bits_clear(found_array->bits, found_array->len, bit_array_bits_size_bits);
            found_array->len = bit_array_bits_size_bits;
        }

        if (!found_array->next) {
            found_array->next = arena_alloc_align(array_arena, bit_array_size, 16);
        }

        found_array = found_array->next;
    }

    if (found_array->len < actual_i) {
        found_array->len = actual_i + 1;
    }

    bits_set_bit(found_array->bits, actual_i);
}

b32 bit_array_get(Bit_Array *array, isize pos) {
    isize arrays   = pos / bit_array_bits_size_bits;
    isize actual_i = pos % bit_array_bits_size_bits;

    Bit_Array *found_array = array;
    for (isize i = 0; i < arrays; i++) {
        if (found_array->len < bit_array_bits_size_bits) {
            return false;
        }

        if (!found_array->next) {
            return false;
        }

        found_array = found_array->next;
    }

    isize bits_index = actual_i / 32;
    isize bits_i     = actual_i % 32;

    return !!(found_array->bits[bits_index] & (cast(u32)1 << bits_i));
}

void bit_array_clear_all(Bit_Array *head) {
    for (Bit_Array *array = head; array; array = array->next) {
        memset(array->bits, 0, bit_array_bits_size);
        array->len = 0;
    }
}

// Symbol Map

u32 hash(String s) {
    u32 hash = 2166136261u;
    for (isize i = 0; i < s.len; i++) {
        hash ^= s.data[i];
        hash *= 16777619u;
    }
    return hash;
}

typedef struct Symbol {
    struct Thing *thing;
} Symbol;

typedef struct Symbol_Map {
    struct Symbol_Map *child[4];
    String            key;
    Symbol            value;
} Symbol_Map;

Symbol *symbol_map_upsert(Symbol_Map **m, String key, Arena *arena) {
    for (u32 h = hash(key); *m; h <<= 2) {
        if (string_eq(key, (*m)->key)) {
            return &(*m)->value;
        }
        m = &(*m)->child[h>>30];
    }
    if (!arena) {
        return NULL;
    }

    *m          = arena_alloc_align(arena, sizeof(Symbol_Map), sizeof(void *));
    (*m)->key   = key;
    return &(*m)->value;
}

Symbol *symbol_map_upsert_free_list(Symbol_Map **m, String key, Symbol_Map **free_list, Arena *arena) {
    for (u32 h = hash(key); *m; h <<= 2) {
        if (string_eq(key, (*m)->key)) {
            return &(*m)->value;
        }
        m = &(*m)->child[h>>30];
    }
    if (!arena) {
        return NULL;
    }

    if (*free_list) {
        *m         = *free_list;
        *free_list = (*free_list)->child[0];
    } else {
        *m = arena_alloc_align(arena, sizeof(Symbol_Map), sizeof(void *));
    }

    (*m)->key = key;
    return &(*m)->value;
}

// Basics

typedef struct Context {
    Arena        things; // NOTE: It is assumed that this arena only contains Thing's and nothing else, do not use it for anything else
    isize        alive_things;
    isize        total_things;
    struct Thing *dead_things;

    Arena        symbols; // NOTE: Contains both the symbol interning table and the environment table
    Symbol_Map   *symbol_map;
    Symbol_Map   *dead_envs;
    struct Thing *env;

    isize gc_things_threshold; // when reached, the gc will be run on the next thing_new

    struct Thing *nil;
} Context;

struct Root;

typedef struct Thing *(*Builtin)(Context *ctx, struct Root *root, struct Thing *env, struct Thing *args);

typedef enum Thing_Type {
    THING_NUM,
    THING_CONS,
    THING_SYMBOL,
    THING_FUNCTION,
    THING_MACRO,
    THING_BUILTIN,
    THING_ENV,

    THING_NIL,

    // Unused and free to use
    THING_DEAD,
} Thing_Type;

typedef struct Thing {
    Thing_Type type;
    b32        marked; // TODO(robin): merge into bit set, this fills up the padding so no memory actually wasted yet
    union {
        i32 num;
        struct {
            struct Thing *car;
            struct Thing *cdr;
        } cons;
        String symbol;
        struct {
            struct Thing *params;
            struct Thing *code;
            struct Thing *env;
        } function;
        Builtin builtin;
        struct {
            struct Thing *parent;
            Symbol_Map   *vars;
        } env;
        struct Thing *next_dead;
    };
} Thing;

// GC - Mark and sweep garbage collector

// Roots
// Roots are a linked list of arrays of things, they are needed for the gc to track which are the actual roots of the program so
// that we can traverse the roots and mark still used things

typedef struct Root {
    struct Root  *parent;
    isize        thing_count;
    struct Thing ***things; // Array of pointers to stack variables, man c syntax is fucking ass
} Root;

#define ROOT_NEW(size) TEMP_ARENA_EMPTY;                                                                            \
    root = &(Root) { .parent = root, .thing_count = (size) };                                                       \
    root->things = arena_alloc_align(temp.arena, sizeof(struct Thing **) * root->thing_count, sizeof(struct Root *))

#define ROOT_VARS1(var1) ROOT_NEW(1);\
    Thing *(var1) = NULL;            \
    root->things[0] = &(var1)

#define ROOT_VARS2(var1, var2) ROOT_NEW(2);\
    Thing *(var1) = NULL;                  \
    root->things[0] = &(var1);             \
    Thing *(var2) = NULL;                  \
    root->things[1] = &(var2)

#define ROOT_VARS3(var1, var2, var3) ROOT_NEW(3);\
    Thing *(var1) = NULL;                        \
    root->things[0] = &(var1);                   \
    Thing *(var2) = NULL;                        \
    root->things[1] = &(var2);                   \
    Thing *(var3) = NULL;                        \
    root->things[2] = &(var3)

#define ROOT_VARS4(var1, var2, var3, var4) ROOT_NEW(4);\
    Thing *(var1) = NULL;                              \
    root->things[0] = &(var1);                         \
    Thing *(var2) = NULL;                              \
    root->things[1] = &(var2);                         \
    Thing *(var3) = NULL;                              \
    root->things[2] = &(var3);                         \
    Thing *(var4) = NULL;                              \
    root->things[3] = &(var4)


void gc_mark_symbol_map(Context *ctx, Symbol_Map *map);

void gc_mark(Context *ctx, Thing *thing) {
    if (!thing || thing->marked /* avoid marking things more than once (avoids circular dependencies to) */) {
        return;
    }

    thing->marked = true;
    switch (thing->type) {
    case THING_NUM:
    case THING_NIL:
    case THING_DEAD:
    case THING_SYMBOL:
    case THING_BUILTIN:
        break;

    case THING_CONS:
        gc_mark(ctx, thing->cons.car);
        gc_mark(ctx, thing->cons.cdr);
        break;
    case THING_FUNCTION:
    case THING_MACRO:
        gc_mark(ctx, thing->function.code);
        gc_mark(ctx, thing->function.env);
        gc_mark(ctx, thing->function.params);
        break;
    case THING_ENV:
        gc_mark(ctx, thing->env.parent);
        gc_mark_symbol_map(ctx, thing->env.vars);
        break;
    }
}

void thing_kill(Context *ctx, Thing *thing);

void gc_mark_symbol_map(Context *ctx, Symbol_Map *map) {
    if (map->value.thing) {
        gc_mark(ctx, map->value.thing);
    }

    for (isize i = 0; i < 4; i++) {
        if (map->child[i]) {
            gc_mark_symbol_map(ctx, map->child[i]);
        }
    }
}

isize gc_sweep_symbol_map(Context *ctx, Symbol_Map *map) {
    if (!map) {
        return 0;
    }
    isize count = 0;

    for (isize i = 0; i < 4; i++) {
        if (map->child[i]) {
            count += gc_sweep_symbol_map(ctx, map->child[i]);
        }
    }

    zero(map);
    map->child[0]  = ctx->dead_envs;
    ctx->dead_envs = map;
    return count + 1;
}

void gc(Context *ctx, Root *root) {
    printf("Running gc %zd\n", ctx->gc_things_threshold);
    gc_mark(ctx, ctx->env);
    gc_mark(ctx, ctx->nil);
    gc_mark_symbol_map(ctx, ctx->symbol_map);

    for(Root *current_root = root; current_root; current_root = current_root->parent) {
        for (isize i = 0; i < current_root->thing_count; i++) {
            Thing **local_thing = current_root->things[i];
            if (!local_thing || !*local_thing) {
                // TODO(robin): maybe warn?
                continue;
            }
            gc_mark(ctx, *local_thing);
        }
    }

    isize killed = 0;
    isize symbols_maps_killed = 0;

    // sweep
    for (Arena_Block *block = ctx->things.first; block; block = block->next) {
        Thing *things = block->memory;
        isize thing_count = block->len / sizeof(Thing);

        for (isize i = 0; i < thing_count; i++) {
            Thing *thing = &things[i];
            if (thing->marked) {
                goto done;
            }

            switch (thing->type) {
            case THING_DEAD:
                break;
            case THING_ENV:
                // free all symbols
                symbols_maps_killed += gc_sweep_symbol_map(ctx, thing->env.vars);

                goto kill;
            default:
kill:
                killed += 1;
                thing_kill(ctx, thing);
            }

done:
            thing->marked = false;
        }
    }

    printf("GC done, killed %zd things and %zd symbol maps\n", killed, symbols_maps_killed);
}

// Alloc functions

Thing *thing_new(Context *ctx, Root *root, Thing_Type type) {
    if (ctx->gc_things_threshold < ctx->alive_things) {
        // run gc
        gc(ctx, root);
        ctx->gc_things_threshold = ctx->alive_things * 2;
    }

    if (ctx->dead_things) {
        Thing *new_thing = ctx->dead_things;
        ctx->dead_things = ctx->dead_things->next_dead;
        zero(new_thing);
        new_thing->type = type;

        ctx->alive_things += 1;
        return new_thing;
    }

    Thing *thing = arena_alloc_align(&ctx->things, sizeof(Thing), sizeof(struct Thing *));
    thing->type = type;

    ctx->alive_things += 1;
    ctx->total_things += 1;
    return thing;
}

Thing *thing_num(Context *ctx, Root *root, i32 num) {
    Thing *thing = thing_new(ctx, root, THING_NUM);
    thing->num = num;
    return thing;
}

Thing *thing_cons(Context *ctx, Root *root, Thing *car, Thing *cdr) {
    Thing *thing = thing_new(ctx, root, THING_CONS);
    thing->cons.car = car;
    thing->cons.cdr = cdr;
    return thing;
}

Thing *thing_symbol(Context *ctx, Root *root, String name) {
    Thing *thing       = thing_new(ctx, root, THING_SYMBOL);
    thing->symbol.data = arena_alloc_align(&ctx->symbols, name.len, 1);
    thing->symbol.len  = name.len;
    memcpy((u8*)thing->symbol.data, name.data, name.len);
    return thing;
}

Thing *thing_symbol_intern(Context *ctx, Root *root, String name) {
    ROOT_VARS1(sym);

    Symbol *symbol = symbol_map_upsert(&ctx->symbol_map, name, &ctx->symbols);
    if (symbol->thing) {
        return symbol->thing;
    }

    symbol->thing = thing_symbol(ctx, root, name);
    return symbol->thing;
}

Thing *thing_function(Context *ctx, Root *root, Thing *params, Thing *code, Thing *env, Thing_Type type) {
    assert(type == THING_FUNCTION || type == THING_MACRO);

    Thing *thing           = thing_new(ctx, root, type);
    thing->function.params = params;
    thing->function.code   = code;
    thing->function.env    = env;
    return thing;
}

Thing *thing_builtin(Context *ctx, Root *root, Builtin builtin) {
    Thing *thing   = thing_new(ctx, root, THING_BUILTIN);
    thing->builtin = builtin;
    return thing;
}

Thing *thing_env(Context *ctx, Root *root, Thing *parent, Symbol_Map *vars) {
    Thing *thing      = thing_new(ctx, root, THING_ENV);
    thing->env.parent = parent;
    thing->env.vars   = vars;
    return thing;
}

void thing_kill(Context *ctx, Thing *thing) {
    thing->type        =  THING_DEAD;
    thing->next_dead   =  ctx->dead_things;
    ctx->dead_things   =  thing;
    ctx->alive_things -= 1;
}

Thing *thing_acons(Context *ctx, Root *root, Thing *x, Thing *y, Thing *a) {
    ROOT_VARS1(cell);
    cell = thing_cons(ctx, root, x, y);
    return thing_cons(ctx, root, cell, a);
}

// Printer

void print(Context *ctx, Thing *t) {
    switch (t->type) {
    case THING_NUM:
        printf("%d", t->num);
        break;
    case THING_CONS:
        printf("(");
        Thing *current = t;
        for (; current->type == THING_CONS; current = current->cons.cdr) {
            if (current != t) {
                printf(" ");
            }
            print(ctx, current->cons.car);
        }

        if (current != ctx->nil) {
            printf(" . ");
            print(ctx, t->cons.cdr);
        }

        printf(")");
        break;
    case THING_SYMBOL:
        printf(":%.*s", (int)t->symbol.len, t->symbol.data);
        break;
    case THING_NIL:
        printf("nil");
        break;
    case THING_DEAD:
        printf("<dead>");
        break;
    case THING_FUNCTION:
        printf("<function>");
        break;
    case THING_MACRO:
        printf("<macro>");
        break;
    case THING_BUILTIN:
        printf("<builtin>");
        break;
    case THING_ENV:
        printf("<env>");
        break;
    }
}

// Parser

typedef enum Token_Type {
    TOKEN_INVALID,
    TOKEN_EOF,
    TOKEN_POPEN,
    TOKEN_PCLOSE,
    TOKEN_DOT,
    TOKEN_QUOTE,

    TOKEN_SYMBOL,
    TOKEN_NUM,
} Token_Type;

typedef struct Token {
    Token_Type type;
    isize      pos;
    isize      len;
} Token;

typedef struct Parser {
    Context *ctx;
    String  input;

    isize ch_pos;
    u8    ch;

    Arena tokens;
    Token *current_token;
    Token *peek_token;
} Parser;

Token *parser_clone_token(Parser *parser, Token token) {
    Token *cloned = arena_alloc_align(&parser->tokens, sizeof(Token), sizeof(usize));
    *cloned = token;
    return cloned;
}

void parser_read_ch(Parser *parser) {
    if (parser->ch_pos < parser->input.len) {
        parser->ch     =  parser->input.data[parser->ch_pos];
    } else {
        parser->ch = 0;
    }
    parser->ch_pos += 1;
}

u8 parser_peek_ch(Parser *parser) {
    if (parser->ch_pos < parser->input.len) {
        return parser->input.data[parser->ch_pos];
    }
    return 0;
}

b32 is_whitespace_ch(u8 ch) {
    return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
}

b32 is_reserved_ch(u8 ch) {
    return ch == '(' || ch == ')' || ch == ':';
}

b32 is_digit(u8 ch) {
    return '0' <= ch && ch <= '9';
}

void parser_skip_whitespace(Parser *parser) {
    while (is_whitespace_ch(parser->ch)) {
        parser_read_ch(parser);
    }
}

Token *parser_read_identifier(Parser *parser) {
    Token t = { .type = TOKEN_SYMBOL, .pos = parser->ch_pos - 1 };

    while (!is_reserved_ch(parser->ch) && !is_whitespace_ch(parser->ch) && parser->ch != 0) {
        parser_read_ch(parser);
    }

    t.len = parser->ch_pos - 1 - t.pos;

    return parser_clone_token(parser, t);
}

Token *parser_read_num(Parser *parser) {
    Token t = { .type = TOKEN_NUM, .pos = parser->ch_pos - 1 };

    if (parser->ch == '-') {
        parser_read_ch(parser);
    }

    while (is_digit(parser->ch)) {
        parser_read_ch(parser);
    }

    t.len = parser->ch_pos - 1 - t.pos;

    return parser_clone_token(parser, t);
}

Token *parser_read_token(Parser *parser) {
    parser_skip_whitespace(parser);
    Token t = { .pos = parser->ch_pos - 1, .len = 1 };

    switch (parser->ch) {
    case 0:    t.type = TOKEN_EOF;    break;
    case '(':  t.type = TOKEN_POPEN;  break;
    case ')':  t.type = TOKEN_PCLOSE; break;
    case '.':  t.type = TOKEN_DOT;    break;
    case '\'': t.type = TOKEN_QUOTE;  break;
    case '-':
        if (is_digit(parser_peek_ch(parser))) {
            return parser_read_num(parser);
        }
        goto skip_num;
    default: {
        if (is_digit(parser->ch)) {
            return parser_read_num(parser);
        }

skip_num:
        return parser_read_identifier(parser);
    }
    }

    parser_read_ch(parser);
    return parser_clone_token(parser, t);
}

void parser_next_token(Parser *parser) {
    parser->current_token = parser->peek_token;
    parser->peek_token = parser_read_token(parser);
}

void parser_init(Parser *parser, Context *ctx, String input) {
    parser->ctx   = ctx;
    parser->input = input;
    parser_read_ch(parser);
    parser_next_token(parser);
    parser_next_token(parser);
}

void parser_destroy(Parser *parser) {
    arena_destroy(&parser->tokens);
    zero(parser);
}

// Current token is new, ends on next new token
Thing *parser_read(Parser *parser, Root *root) {
    Thing *simple = NULL;

    switch (parser->current_token->type) {
    case TOKEN_INVALID:
        fatalf("Invalid token");
    case TOKEN_EOF:
        fatalf("Unexpected EOF");
    case TOKEN_QUOTE: {
        ROOT_VARS2(list, sym);
        parser_next_token(parser);
        sym = thing_symbol_intern(parser->ctx, root, STR("quote"));
        list = parser_read(parser, root);
        list = thing_cons(parser->ctx, root, list, parser->ctx->nil);
        list = thing_cons(parser->ctx, root, sym, list);
        return list;
    }
    case TOKEN_POPEN: {
        // start list
        parser_next_token(parser);

        if (parser->current_token->type == TOKEN_PCLOSE) {
            parser_next_token(parser);
            return parser->ctx->nil;
        }

        ROOT_VARS4(start, head, current, t);

        start = parser_read(parser, root);

        if (parser->current_token->type == TOKEN_DOT) {
            parser_next_token(parser);
            head = parser_read(parser, root);
            if (parser->current_token->type != TOKEN_PCLOSE) {
                fatalf("Expected a ')' after a cons");
            }
            parser_next_token(parser);
            start = thing_cons(parser->ctx, root, start, head);
            return start;
        }

        head = thing_cons(parser->ctx, root, start, parser->ctx->nil);
        current = head;

        while (parser->current_token->type != TOKEN_PCLOSE) {
            t = parser_read(parser, root);
            current = current->cons.cdr = thing_cons(parser->ctx, root, t, parser->ctx->nil);
        }
        parser_next_token(parser);
        return head;
    }
    case TOKEN_PCLOSE:
        fatalf("Unexpected ')'");
    case TOKEN_DOT:
        fatalf("Unexpected '.'");
    case TOKEN_SYMBOL:
        simple = thing_symbol_intern(parser->ctx, root,
                (String){ .data = parser->input.data + parser->current_token->pos,
                .len = parser->current_token->len });
        break;
    case TOKEN_NUM: {
        i32 value = 0;
        b32 neg   = false;

        if (parser->current_token->len > 0 && parser->input.data[parser->current_token->pos] == '-') {
            neg = true;
        }

        for (isize i = neg ? 1 : 0; i < parser->current_token->len; i++) {
            u8 digit = parser->input.data[parser->current_token->pos+i];
            value *= 10;
            value += cast(i32)(digit - '0');
        }

        if (neg) {
            value = -value;
        }

        simple = thing_num(parser->ctx, root, value);
        break;
    default:
        fatalf("BUG: Unhandled token %d", parser->current_token->type);
    }
    }

    parser_next_token(parser);

    return simple;
}

// Eval

b32 is_list(Context *ctx, Thing *t) {
    return t == ctx->nil || t->type == THING_CONS;
}

isize list_length(Context *ctx, Thing *t) {
    isize len = 0;

    for (;;) {
        if (t == ctx->nil) {
            return len;
        }

        if (t->type != THING_CONS) {
            fatalf("length: Invalid, non-cons, list item");
        }

        t    = t->cons.cdr;
        len += 1;
    }
}

Thing *eval(Context *ctx, Root *root, Thing *env, Thing *code);
Thing *progn(Context *ctx, Root *root, Thing *env, Thing *list);

Thing *env_find(Context *ctx, Thing *env, Thing *sym) {
    for (; env != ctx->nil; env = env->env.parent) {
        Symbol *symbol = symbol_map_upsert(&env->env.vars, sym->symbol, NULL);
        if (symbol) {
            return symbol->thing;
        }
    }

    return NULL;
}

Thing *env_from_lists(Context *ctx, Root *root, Thing *env, Thing *keys, Thing *values) {
    ROOT_VARS2(k, v);

    Symbol_Map *vars = NULL;
    k = keys, v = values;

    for (; k != ctx->nil && v != ctx->nil; k = k->cons.cdr, v = v->cons.cdr) {
        Symbol *symbol = symbol_map_upsert_free_list(&vars, k->cons.car->symbol, &ctx->dead_envs, &ctx->symbols);
        symbol->thing = v->cons.car;
    }

    if (k != ctx->nil || v != ctx->nil) {
        fatalf("apply: Mismatch in length for keys and values");
    }

    return thing_env(ctx, root, env, vars);
}

void env_add_builtin(Context *ctx, Root *root, Thing *env, String name, Builtin builtin) {
    ROOT_VARS2(sym, builtin_thing);
    sym            = thing_symbol_intern(ctx, root, name);
    builtin_thing  = thing_builtin(ctx, root, builtin);
    Symbol *symbol = symbol_map_upsert_free_list(&env->env.vars, sym->symbol, &ctx->dead_envs, &ctx->symbols);
    symbol->thing  = builtin_thing;
}

void env_add_variable(Context *ctx, Thing *env, Thing *key, Thing *value) {
    Symbol *symbol = symbol_map_upsert_free_list(&env->env.vars, key->symbol, &ctx->dead_envs, &ctx->symbols);
    symbol->thing  = value;
}

Thing *eval_list(Context *ctx, Root *root, Thing *env, Thing *list) {
    ROOT_VARS4(head, current, t, element);

    for (element = list; element != ctx->nil; element = element->cons.cdr) {
        t = eval(ctx, root, env, element->cons.car);
        if (head == NULL) {
            current = head = thing_cons(ctx, root, t, ctx->nil);
        } else {
            current = current->cons.cdr = thing_cons(ctx, root, t, ctx->nil);
        }
    }

    return head;
}

Thing *apply(Context *ctx, Root *root, Thing *env, Thing *fn, Thing *args) {
    if (!is_list(ctx, args)) {
        fatalf("apply: args must be a list");
    }
    if (fn->type == THING_BUILTIN) {
        return fn->builtin(ctx, root, env, args);
    }

    ROOT_VARS2(evaluated_args, new_env);

    evaluated_args = eval_list(ctx, root, env, args);
    new_env        = env_from_lists(ctx, root, fn->function.env, fn->function.params, evaluated_args);
    return progn(ctx, root, new_env, fn->function.code);
}

Thing *progn(Context *ctx, Root *root, Thing *env, Thing *list) {
    ROOT_VARS1(result);
    for (Thing *element = list; element != ctx->nil; element = element->cons.cdr) {
        result = eval(ctx, root, env, element->cons.car);
    }
    return result;
}

// Tries to apply a macro application
Thing *macro_expand(Context *ctx, Root *root, Thing *env, Thing *t) {
    if (t->type != THING_CONS || t->cons.car->type != THING_SYMBOL) {
        return t;
    }

    Thing *macro = env_find(ctx, env, t->cons.car);
    if (!macro || macro->type != THING_MACRO) {
        return t;
    }

    ROOT_VARS3(args, params, new_env);

    args = t->cons.cdr;
    params = macro->function.params;
    new_env = env_from_lists(ctx, root, env, params, args);
    return progn(ctx, root, new_env, macro->function.code);
}

Thing *eval(Context *ctx, Root *root, Thing *env, Thing *code) {
    switch (code->type) {
    case THING_NUM:
    case THING_NIL:
    case THING_FUNCTION:
    case THING_BUILTIN:
        return code;

    case THING_CONS: {
        ROOT_VARS3(expaneded, fn, args);

        expaneded = macro_expand(ctx, root, env, code);
        if (expaneded != code) {
            return eval(ctx, root, env, expaneded);
        }

        fn   = eval(ctx, root, env, expaneded->cons.car);
        args = expaneded->cons.cdr;
        if (fn->type != THING_BUILTIN && fn->type != THING_FUNCTION) {
            fatalf("Expected function to call, got %d", fn->type);
        }
        return apply(ctx, root, env, fn, args);
    }
    case THING_SYMBOL: {
        Thing *t = env_find(ctx, env, code);
        if (!t) {
            fatalf("Could not find symbol: %.*s", cast(int)code->symbol.len, code->symbol.data);
        }
        return t;
    }
    default:
        fatalf("Invalid thing type in eval: %d", code->type);
        break;
    }
}

// Builtins

typedef enum Math_Operator {
    MATH_OP_ADD,
    MATH_OP_SUB,
    MATH_OP_MUL,
    MATH_OP_DIV,
} Math_Operator;

Thing *handle_math(Context *ctx, Root *root, Thing *env, Thing *args, Math_Operator op) {
    cast(void)env;

    ROOT_VARS2(evaluated_args, num);

    evaluated_args = eval_list(ctx, root, env, args);
    if (evaluated_args->type != THING_CONS) {
        fatalf("op: one argument is required at least");
    }

    num = evaluated_args->cons.car;
    if (num->type != THING_NUM) {
        fatalf("Invalid argument type to '+' of type %d", num->type);
    }
    i32 result = num->num;
    evaluated_args = evaluated_args->cons.cdr;

#define HANDLE_MATH_FOR_EACH(op)                                                                  \
    for (Thing *num_cons = evaluated_args; num_cons != ctx->nil; num_cons = num_cons->cons.cdr) { \
        Thing *num = num_cons->cons.car;                                                          \
        if (num->type != THING_NUM) {                                                             \
            fatalf("Invalid argument to '+' of type %d", num->type);                              \
        }                                                                                         \
        result op##= num->num;                                                                    \
    }

    switch (op) {
    case MATH_OP_ADD:
        HANDLE_MATH_FOR_EACH(+);
        break;
    case MATH_OP_SUB:
        HANDLE_MATH_FOR_EACH(-);
        break;
    case MATH_OP_MUL:
        HANDLE_MATH_FOR_EACH(*);
        break;
    case MATH_OP_DIV:
        HANDLE_MATH_FOR_EACH(/);
        break;
    }
#undef HANDLE_MATH_FOR_EACH

    return thing_num(ctx, root, result);
}

Thing *builtin_add(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_ADD);
}

Thing *builtin_sub(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_SUB);
}

Thing *builtin_mul(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_MUL);
}

Thing *builtin_div(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_DIV);
}

Thing *handle_function(Context *ctx, Root *root, Thing *env, Thing *args, Thing_Type type) {
    if (args->type != THING_CONS || !is_list(ctx, args->cons.car)) {
        fatalf("deffun: Parameter list must be a list");
    }

    if (args->cons.cdr->type != THING_CONS) {
        fatalf("deffun: Body must be a list");
    }

    // Validate params
    Thing *param = args->cons.car;
    for (; param->type == THING_CONS; param = param->cons.cdr) {
        if (param->cons.car->type != THING_SYMBOL) {
            fatalf("lambda: Parameter must be a symbol");
        }

        if (!is_list(ctx, param->cons.cdr)) {
            fatalf("lambda: Parameter must be a flat list");
        }
    }

    if (param != ctx->nil && param->type != THING_SYMBOL) {
        fatalf("lambda: Parameter must be a symbol");
    }

    ROOT_VARS2(params, code);
    params = args->cons.car;
    code = args->cons.cdr;
    return thing_function(ctx, root, params, code, env, type);
}

Thing *builtin_lambda(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_function(ctx, root, env, args, THING_FUNCTION);
}

Thing *handle_deffun(Context *ctx, Root *root, Thing *env, Thing *args, Thing_Type type) {
    ROOT_VARS3(fn_sym, fn_args, fn);
    fn_sym  = args->cons.car;
    fn_args = args->cons.cdr;
    fn      = handle_function(ctx, root, env, fn_args, type);
    env_add_variable(ctx, env, fn_sym, fn);
    return fn;
}

Thing *builtin_deffun(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_deffun(ctx, root, env, args, THING_FUNCTION);
}

Thing *builtin_defmacro(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_deffun(ctx, root, env, args, THING_MACRO);
}

Thing *builtin_define(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) != 2 || args->cons.car->type != THING_SYMBOL) {
        fatalf("define: First parameter should be symbol");
    }

    ROOT_VARS2(sym, value);
    sym = args->cons.car;
    value = args->cons.cdr->cons.car;
    value = eval(ctx, root, env, value);
    env_add_variable(ctx, env, sym, value);
    return value;
}

Thing *builtin_macroexpand(Context *ctx, Root *root, Thing *env, Thing *args) {
    ROOT_VARS2(evaluated_args, code);

    evaluated_args = eval_list(ctx, root, env, args);
    if (list_length(ctx, evaluated_args) != 1) {
        fatalf("Malformed macroexpand");
    }

    code = evaluated_args->cons.car;
    return macro_expand(ctx, root, env, code);
}

Thing *builtin_quote(Context *ctx, Root *root, Thing *env, Thing *args) {
    cast(void)env;
    cast(void)root;
    if (list_length(ctx, args) != 1) {
        fatalf("quote: Only accept one argument");
    }

    return args->cons.car;
}

Thing *builtin_gc(Context *ctx, Root *root, Thing *env, Thing *args) {
    cast(void)env;
    cast(void)args;
    gc(ctx, root);
    return ctx->nil;
}

void ctx_init(Context *ctx, Root *root) {
    ctx->gc_things_threshold = 32;
    ctx->nil                 = thing_new(ctx, root, THING_NIL);
    ctx->env                 = thing_env(ctx, root, ctx->nil, NULL);

    env_add_builtin(ctx, root, ctx->env, STR("+"), builtin_add);
    env_add_builtin(ctx, root, ctx->env, STR("-"), builtin_sub);
    env_add_builtin(ctx, root, ctx->env, STR("*"), builtin_mul);
    env_add_builtin(ctx, root, ctx->env, STR("/"), builtin_div);
    env_add_builtin(ctx, root, ctx->env, STR("lambda"), builtin_lambda);
    env_add_builtin(ctx, root, ctx->env, STR("deffun"), builtin_deffun);
    env_add_builtin(ctx, root, ctx->env, STR("defmacro"), builtin_defmacro);
    env_add_builtin(ctx, root, ctx->env, STR("define"), builtin_define);
    env_add_builtin(ctx, root, ctx->env, STR("macroexpand"), builtin_macroexpand);
    env_add_builtin(ctx, root, ctx->env, STR("quote"), builtin_quote);
    env_add_builtin(ctx, root, ctx->env, STR("gc"), builtin_gc);
}

void ctx_destroy(Context *ctx) {
    arena_destroy(&ctx->things);
    arena_destroy(&ctx->symbols);
    zero(ctx);
}

int main(void) {
    {
        Context ctx = { 0 };

        Root *root = NULL;
        ROOT_VARS1(result);

        ctx_init(&ctx, root);

        Parser parser = { 0 };
        parser_init(&parser, &ctx, STR("(define x 3) x ((lambda (deez) deez) 3) (gc) (gc)"));

        while (parser.current_token->type != TOKEN_EOF) {
            result = parser_read(&parser, root);
            print(&ctx, eval(&ctx, root, ctx.env, result));
            printf("\n");
        }

        printf("Alive/Total things: %zd/%zd\n", ctx.alive_things, ctx.total_things);

        parser_destroy(&parser);
        ctx_destroy(&ctx);
    }

    temp_arenas_destroy();

    // print(thing_cons(&ctx, thing_num(&ctx, 23), thing_cons(&ctx, thing_symbol(&ctx, STR("test")), ctx.nil)));
    //
    // print(thing_function(&ctx, thing_cons(&ctx, thing_symbol(&ctx, STR("test")), ctx.nil), thing_cons(&ctx, thing_symbol(&ctx, STR("test")), ctx.nil), ctx.nil));
}
