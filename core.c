#include "core.h"

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

noreturn void fatalf(char const *format, ...) {
    va_list list;
    va_start(list, format);

    vfprintf(stderr, format, list);

    va_end(list);
    exit(1);
}

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

char const *arena_clone_to_cstr(Arena *arena, String str) {
    char *cstr = arena_alloc_align(arena, str.len + 1, sizeof(char));
    memcpy(cstr, str.data, cast(usize)str.len);
    cstr[str.len] = 0;
    return cstr;
}

String arena_clone_from_cstr(Arena *arena, char const *cstr) {
    isize str_len = strlen(cstr);
    u8 *str_data = arena_alloc_align(arena, str_len, sizeof(u8));
    memcpy(str_data, cstr, str_len);
    return (String){
        .len  = str_len,
        .data = str_data,
    };
}

void arena_reset_to(Arena *arena, usize pos) {
    Arena_Block *block = arena->first;

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

    arena->current = block;

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
