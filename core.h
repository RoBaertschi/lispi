#pragma once

#include <assert.h>
#include <errno.h>
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

#define MIN(a, b) (b) < (a) ? (b) : (a)

#define BIT(x) (1 << (x))

#define global static

#ifdef DEBUG_ALL
#   define GC_DEBUG 1
#   define EVAL_DEBUG 1
#endif

#ifndef EVAL_DEBUG
#   define EVAL_DEBUG 0
#endif

#ifndef GC_DEBUG
#   define GC_DEBUG 0
#endif

typedef struct String {
    u8 const *data;
    isize     len;
} String;

#define STR(...) (String){ .data = cast(u8 const*)(__VA_ARGS__), .len = sizeof(__VA_ARGS__)-1 }

b32 string_eq(String a, String b);

typedef struct Arena_Block {
    struct Arena_Block *next;
    void               *memory;
    usize              cap;
    usize              len;
} Arena_Block;

noreturn void fatalf(char const *format, ...);

#define ALIGNMENT_PADDING(value, alignment) ((alignment) - ((value) & ((alignment) - 1))) & ((alignment) - 1)

void        *arena_block_alloc_align(Arena_Block *block, isize size, usize align);
void        *arena_block_alloc(Arena_Block *block, isize size);
Arena_Block *arena_block_new(usize size);
Arena_Block *arena_block_new_min(usize default_size, usize size);

typedef struct Arena {
    Arena_Block *first;
    Arena_Block *current;
    usize       default_mem_block_size;
    usize       len;
} Arena;

void       *arena_alloc_align(Arena *arena, isize size, usize align);
void       *arena_alloc(Arena *arena, isize size);
char const *arena_clone_to_cstr(Arena *arena, String str);
String     arena_clone_from_cstr(Arena *arena, char const *cstr);
void       arena_reset_to(Arena *arena, usize pos);
void       arena_destroy(Arena *arena);

typedef struct Arena_Temp {
    Arena *arena;
    usize pos;
} Arena_Temp;

Arena_Temp arena_get_temp(Arena *arena);
void       arena_reset_temp(Arena_Temp temp);
void       arena_temp_cleanup(Arena_Temp *temp);

#define ARENA_TEMP_GUARD(temp, arena) __attribute__((cleanup(arena_temp_cleanup))) Arena_Temp temp = arena_get_temp(arena);
#define TEMP_ARENA_COUNT 2
Arena *temp_arena_get(Arena **collisions, isize collision_count);
void   temp_arenas_destroy(void);

#define TEMP_ARENA_VAR(temp, ...) ARENA_TEMP_GUARD(temp, temp_arena_get((Arena*[]){ __VA_ARGS__ }, sizeof(((Arena*[]){ __VA_ARGS__ })) / sizeof(((Arena*[]){ __VA_ARGS__ })[0])))
#define TEMP_ARENA(...) TEMP_ARENA_VAR(temp, __VA_ARGS__)
#define TEMP_ARENA_EMPTY ARENA_TEMP_GUARD(temp, temp_arena_get(NULL, 0))

// Bit array

void bits_clear(u32 *bits, isize from, isize to);
void bits_fill(u32 *bits, isize from, isize to);
void bits_set_bit(u32 *bits, isize i);
void bits_clear_bit(u32 *bits, isize i);

#define PAGE_SIZE 1024 * 4

typedef struct Bit_Array {
    struct Bit_Array *next;
    isize            len;
    u32              bits[];
} Bit_Array;


void bit_array_set(Arena *array_arena, Bit_Array *array, isize pos);
b32  bit_array_get(Bit_Array *array, isize pos);
void bit_array_clear_all(Bit_Array *head);
