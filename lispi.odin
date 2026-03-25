package lispi

import "base:runtime"
import "core:hash"
import "core:mem/virtual"

// Symbol Map

Symbol :: struct {
    thing: ^Thing,
}

Symbol_Map :: struct {
    child: [4]^Symbol_Map,
    key:   string,
    value: Symbol,
}

symbol_map_find :: proc(m: ^^Symbol_Map, key: string) -> ^Symbol {
    m := m
    for h := hash.fnv32a(transmute([]byte)key); m^ != nil; h <<= 2 {
        if key == m^.key {
            return &m^.value
        }
        m = &m^.child[h>>30]
    }

    return nil
}

symbol_map_upsert :: proc(m: ^^Symbol_Map, key: string, free_list: ^^Symbol_Map, arena: ^virtual.Arena) -> ^Symbol {
    m := m
    for h := hash.fnv32a(transmute([]byte)key); m^ != nil; h <<= 2 {
        if key == m^.key {
            return &m^.value
        }
        m = &m^.child[h>>30]
    }

    if arena == nil {
        return nil
    }

    if free_list^ != nil {
        m^         = free_list^
        free_list^ = free_list^.child[0]
    } else {
        m^, _ = virtual.new(arena, Symbol_Map)
    }

    m^.key = key
    return &m^.value
}

// String Blocks

String_Block_Size :: enum {
    Small,
    Medium,
    Large,
    Huge,
}

string_block_sizes := [String_Block_Size]int{
    .Small  = 64,
    .Medium = 512,
    .Large  = 1024 * 4,  // 4KB
    .Huge   = 1024 * 32, // 32KB
}

string_block_sizes_thresholds := [String_Block_Size]int{
    .Small  = 0,
    .Medium = 385,
    .Large  = runtime.Kilobyte * 3, // 3KB
    .Huge   = runtime.Kilobyte * 24 // 24KB
}

String_Block_Info :: bit_field u8 {
    size:   String_Block_Size | 2,
    marked: bool | 1
}

String_Block :: struct {
    next: ^String_Block,
    cap:  int,
    len:  int,
    info: String_Block_Info,
    data: [0]u8,
}

String_Block_Free_List :: [String_Block_Size]^String_Block

string_block_new :: proc(arena: ^virtual.Arena, size: String_Block_Size, free_list: ^String_Block_Free_List) -> (block: ^String_Block) {

    if free_list[size] != nil {
        block           = free_list[size]
        free_list[size] = block.next
    } else {
        data, _ := virtual.make_aligned(arena, []u8, size_of(String_Block) + string_block_sizes[size], align_of(String_Block))

        block = cast(^String_Block)raw_data(data)
    }

    block.len = 0
    block.cap = string_block_sizes[size]
    block.info = { size = size }
    return block
}

// Basics

Context :: struct {
    things:       virtual.Arena,
    alive_things: int,
    total_things: int,
    dead_things:  ^Thing,

    strings:            virtual.Arena,
    dead_string_blocks: ^String_Block,

    symbols:            virtual.Arena,
    symbol_map:         ^Symbol_Map,
    dead_envs:          ^Symbol_Map,
    env:                ^Thing,
    gen_symbol_counter: u64,

    gc_things_threshold: int,

    nil_: ^Thing,
    t:    ^Thing,
}

Thing_Type :: enum {
    Num,
    String,
    Cons,
    Symbol,
    Function,
    Macro,
    Builtin,
    Env,

    // evaluates to itself
    Nil,
    T,

    // Unused and free to use
    Dead,
}

Thing_Info :: bit_field u8 {
    type:   Thing_Type | 7,
    marked: bool | 1,
}

Thing_Cons :: struct {
    car, cdr: ^Thing_Cons,
}

Thing_Function :: struct {
    params: ^Thing,
    code:   ^Thing,
    env:    ^Thing,
}

Thing_Builtin :: #type proc(ctx: ^Context, root: ^Root, env: ^Thing, args: ^Thing) -> ^Thing

Thing_Env :: struct {
    parent: ^Thing,
    vars:   ^Symbol_Map,
}

Thing_Data :: struct #raw_union {
    num:       i32,
    str:       ^String_Block,
    cons:      Thing_Cons,
    symbol:    string,
    function:  Thing_Function,
    builtin:   Thing_Builtin,
    env:       Thing_Env,
    next_dead: ^Thing,
}

Thing :: struct {
    info:    Thing_Info,
    using data: Thing_Data,
}

#assert(size_of(Thing) <= 32)

Root :: struct {
    parent: ^Root,
    things: []^^Thing,
}
