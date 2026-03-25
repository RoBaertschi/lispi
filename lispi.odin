package lispi

import "core:os"
import "core:fmt"
import "core:strings"
import "core:log"
import "core:slice"
import "base:runtime"
import "core:hash"
import "core:mem/virtual"

GC_DEBUG :: #config(LISPI_GC_DEBUG, ODIN_DEBUG)

fatalf :: proc(fmt: string, args: ..any) {
    log.fatalf(fmt, ..args)
    os.exit(1)
}

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

symbol_map_upsert_free_list :: proc(m: ^^Symbol_Map, key: string, free_list: ^^Symbol_Map, arena: ^virtual.Arena) -> ^Symbol {
    m := m
    for h := hash.fnv32a(transmute([]byte)key); m^ != nil; h <<= 2 {
        if key == m^.key {
            return &m^.value
        }
        m = &m^.child[h>>30]
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

symbol_map_upsert :: proc(m: ^^Symbol_Map, key: string, arena: ^virtual.Arena) -> ^Symbol {
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

    m^, _  = virtual.new(arena, Symbol_Map)
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

    block.len  = 0
    block.cap  = string_block_sizes[size]
    block.info = { size = size }
    return block
}

string_block_clone :: proc(arena: ^virtual.Arena, s: ^String_Block, free_list: ^String_Block_Free_List) -> (head, tail: ^String_Block) {
    for element := s; element != nil; element = element.next {
        if head == nil {
            head = string_block_new(arena, element.info.size, free_list)
            tail = head
        } else {
            tail.next = string_block_new(arena, element.info.size, free_list)
            tail = tail.next
        }

        tail.len       = element.len
        tail.cap       = element.cap
        tail.info.size = element.info.size

        #no_bounds_check {
            copy(tail.data[:tail.cap], element.data[:element.cap])
        }
    }

    return
}

string_block_append :: proc(arena: ^virtual.Arena, a, b: ^String_Block, free_list: ^String_Block_Free_List) -> ^String_Block {
    head, tail := string_block_clone(arena, a, free_list)
    tail.next   = b
    return head
}

// Basics

Context :: struct {
    things:       virtual.Arena,
    alive_things: int,
    total_things: int,
    dead_things:  ^Thing,

    strings:            virtual.Arena,
    dead_string_blocks: String_Block_Free_List,

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
    car, cdr: ^Thing,
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

// GC - Mark and sweep garbage collector

// Roots
// Roots are a linked list of arrays of things, they are needed for the gc to track which are the actual roots of the program so
// that we can traverse the roots and mark still used things

Root :: struct {
    parent: ^Root,
    things: []^^Thing,
}

root_new :: proc(temp: runtime.Allocator, root: ^Root, vars: ..^^Thing) -> (new_root: ^Root) {
    new_root, _ = new_clone(Root { parent = root, things = slice.clone(vars, allocator = temp) }, allocator = temp)
    return
}

root_new_guard_end :: proc(_: ^Root, temp: Temp_Allocator) {
    temp_allocator_end(temp.tmp, temp.loc)
}

@(deferred_out=root_new_guard_end)
root_new_guard :: proc(root: ^Root, vars: ..^^Thing, collisions := []runtime.Allocator{}, loc := #caller_location) -> (new_root: ^Root, temp: Temp_Allocator) {
    temp = temp_allocator_get(collisions, loc = loc)
    new_root = root_new(temp, root, ..vars)
    return
}

gc_mark :: proc(ctx: ^Context, thing: ^Thing) {
    if thing == nil || thing.info.marked {
        return
    }

    thing.info.marked = true
    switch thing.info.type {
    case .Num,
         .Symbol,
         .Nil,
         .T,
         .Builtin,
         .Dead:
        break

    case .String:
        // TODO(robin): gc mark string
    case .Cons:
        gc_mark(ctx, thing.cons.car)
        gc_mark(ctx, thing.cons.cdr)
    case .Function, .Macro:
        gc_mark(ctx, thing.function.code)
        gc_mark(ctx, thing.function.env)
        gc_mark(ctx, thing.function.params)
    case .Env:
        gc_mark(ctx, thing.env.parent)
        gc_mark_symbol_map(ctx, thing.env.vars)
    }
}

gc_mark_symbol_map :: proc(ctx: ^Context, m: ^Symbol_Map) {
    if m.value.thing != nil {
        gc_mark(ctx, m.value.thing)
    }

    for i in 0..<len(m.child) {
        if m.child[i] != nil {
            gc_mark_symbol_map(ctx, m.child[i])
        }
    }
}

gc_mark_string :: proc(ctx: ^Context, block: ^String_Block) {
    for element := block; element != nil; element = element.next {
        element.info.marked = true
    }
}

gc :: proc(ctx: ^Context, root: ^Root) {
    when GC_DEBUG {
        log.debugf("Running gc on threshold %v", ctx.gc_things_threshold)
    }
    gc_mark(ctx, ctx.env)
    gc_mark(ctx, ctx.nil_)
    gc_mark(ctx, ctx.t)
    gc_mark_symbol_map(ctx, ctx.symbol_map)


    for current_root := root; current_root != nil; current_root = current_root.parent {
        for &thing in current_root.things {
            if thing == nil || thing^ == nil {
                // TODO(robin): maybe warn?
                continue
            }
            gc_mark(ctx, thing^)
        }
    }

    killed := 0
    symbols_maps_killed := 0

    for block := ctx.things.curr_block; block != nil; block = block.prev {
        things := slice.reinterpret([]Thing, block.base[:block.used])

        for &thing in things {
            if thing.info.marked {
                continue
            }

            if thing.info.type == .Dead {
                thing.info.marked = false
                continue
            }

            #partial switch thing.info.type {
            case .Env:
                symbols_maps_killed += gc_sweep_symbol_map(ctx, thing.env.vars)
            case .String:
                gc_sweep_string(ctx, &thing.str)
            }
            killed += 1
            thing_kill(ctx, &thing)

            thing.info.marked = false
        }
    }

    when GC_DEBUG {
        log.debugf("GC done, killed %d things and %d symbol maps", killed, symbols_maps_killed)
    }
}

gc_sweep_symbol_map :: proc(ctx: ^Context, m: ^Symbol_Map) -> (count: int) {
    if m == nil {
        return
    }

    for child in m.child {
        if child != nil {
            count += gc_sweep_symbol_map(ctx, child)
        }
    }

    m^= {
        child = {
            0 = ctx.dead_envs,
        }
    }

    ctx.dead_envs = m
    count += 1

    return
}

gc_sweep_string :: proc(ctx: ^Context, block_ptr: ^^String_Block) {
    element, previous: ^String_Block = block_ptr^, nil
    for element != nil {
        next := element.next
        if !element.info.marked {
            if previous != nil {
                previous.next = next
            } else {
                block_ptr^ = next
            }

            #no_bounds_check {
                slice.zero(element.data[:element.len])
            }

            element.next                              = ctx.dead_string_blocks[element.info.size]
            element.len                               = 0
            element.info                              = { size = element.info.size }
            ctx.dead_string_blocks[element.info.size] = element
        } else {
            element.info.marked = false
            previous = element
        }
        element = next
    }
}

// Alloc functions

thing_new :: proc(ctx: ^Context, root: ^Root, type: Thing_Type) -> ^Thing {
    if ctx.gc_things_threshold < ctx.alive_things {
        // run gc
        gc(ctx, root)
        ctx.gc_things_threshold = ctx.alive_things * 2
    }

    if ctx.dead_things != nil {
        new_thing        := ctx.dead_things
        ctx.dead_things   = new_thing.next_dead
        new_thing^        = { info = { type = type } }
        ctx.alive_things += 1
        return new_thing
    }

    thing, _         := virtual.new(&ctx.things, Thing)
    thing.info.type   = type
    ctx.alive_things += 1
    ctx.total_things += 1
    return thing
}

thing_num :: proc(ctx: ^Context, root: ^Root, num: i32) -> (thing: ^Thing) {
    thing     = thing_new(ctx, root, .Num)
    thing.num = num
    return thing
}

thing_string :: proc(ctx: ^Context, root: ^Root, block: ^String_Block) -> (thing: ^Thing) {
    thing     = thing_new(ctx, root, .String)
    thing.str = block
    return thing
}

thing_cons :: proc(ctx: ^Context, root: ^Root, car, cdr: ^Thing) -> (thing: ^Thing) {
    thing          = thing_new(ctx, root, .Cons)
    thing.cons.car = car
    thing.cons.cdr = cdr
    return thing
}

thing_symbol :: proc(ctx: ^Context, root: ^Root, name: string) -> (thing: ^Thing) {
    thing        = thing_new(ctx, root, .Symbol)
    thing.symbol = strings.clone(name, virtual.arena_allocator(&ctx.strings))
    return
}

thing_symbol_intern :: proc(ctx: ^Context, root: ^Root, name: string) -> ^Thing {
    root := root

    sym: ^Thing
    root, _ = root_new_guard(root, &sym)

    symbol := symbol_map_upsert(&ctx.symbol_map, name, &ctx.symbols)
    if symbol.thing != nil {
        return symbol.thing
    }

    symbol.thing = thing_symbol(ctx, root, name)
    return symbol.thing
}

thing_function :: proc(ctx: ^Context, root: ^Root, params, code, env: ^Thing, type: Thing_Type) -> (thing: ^Thing) {
    assert(type == .Function || type == .Macro)

    thing                 = thing_new(ctx, root, type)
    thing.function.params = params
    thing.function.code   = code
    thing.function.env    = env
    return
}

thing_builtin :: proc(ctx: ^Context, root: ^Root, builtin: Thing_Builtin) -> (thing: ^Thing) {
    thing         = thing_new(ctx, root, .Builtin)
    thing.builtin = builtin
    return
}

thing_env :: proc(ctx: ^Context, root: ^Root, parent: ^Thing, vars: ^Symbol_Map) -> (thing: ^Thing) {
    thing     = thing_new(ctx, root, .Env)
    thing.env = { parent = parent, vars = vars }
    return
}

thing_kill :: proc(ctx: ^Context, thing: ^Thing) {
    thing.info.type   = .Dead
    thing.next_dead   = ctx.dead_things
    ctx.dead_things   = thing
    ctx.alive_things -= 1
}

thing_acons :: proc(ctx: ^Context, root: ^Root, x, y, a: ^Thing) -> ^Thing {
    root := root
    cell: ^Thing
    root, _ = root_new_guard(root, &cell)
    cell = thing_cons(ctx, root, x, y)
    return thing_cons(ctx, root, cell, a)
}

thing_append :: proc(ctx: ^Context, root: ^Root, a, b: ^Thing) -> ^Thing {
    root := root
    head, tail, current: ^Thing
    root, _ = root_new_guard(root, &head, &tail, &current)
    for current = a; current.info.type == .Cons; current = current.cons.cdr {
        if head == nil {
            head = thing_cons(ctx, root, current.cons.car, ctx.nil_)
            tail = head
        } else {
            tail.cons.cdr = thing_cons(ctx, root, current.cons.car, ctx.nil_)
            tail = tail.cons.cdr
        }
    }

    if head == nil {
        if current != ctx.nil_ {
            return thing_cons(ctx, root, current, b)
        }
        return b
    }

    if current != ctx.nil_ {
        tail.cons.cdr = thing_cons(ctx, root, current, b)
    } else {
        tail.cons.cdr = b
    }

    return head
}

// Printer

print :: proc(ctx: ^Context, t: ^Thing) {
    switch t.info.type {
    case .Num:
        fmt.print(t.num)
    case .String:
        fmt.print("\"")
        for block := t.str; block != nil; block = block.next {
            #no_bounds_check {
                fmt.print(block.data[:block.len])
            }
        }
        fmt.print("\"")
    case .Cons:
        fmt.print("(")
        current := t
        for ; current.info.type == .Cons; current = current.cons.cdr {
            if current != t {
                fmt.print(" ")
            }
            print(ctx, current.cons.car)
        }
        if current != ctx.nil_ {
            fmt.print(" . ")
            print(ctx, t.cons.cdr)
        }
        fmt.print(")")
    case .Symbol:
        fmt.printf(":%s", t.symbol)
    case .Function:
        fmt.print("<function>")
    case .Macro:
        fmt.print("<macro>")
    case .Builtin:
        fmt.print("<builtin>")
    case .Env:
        fmt.print("<env>")
    case .Nil:
        fmt.print("nil")
    case .T:
        fmt.print("t")
    case .Dead:
        fmt.print("<dead>")
    }
}


// Parser

Token_Type :: enum {
    Invalid,
    EOF,
    POpen,
    PClose,
    Dot,
    Quote,
    Backtick,
    Comma,
    Comma_At,

    Num,
    String,
    Symbol,
}

Token :: struct {
    type: Token_Type,
    pos:  int,
    len:  int,
}

Parser :: struct {
    ctx:   ^Context,
    input: string,

    ch_pos: int,
    ch:     u8,  // TODO(robin): utf-8 support

    current_token: Token,
    peek_token:    Token,
}

parser_read_ch :: proc(parser: ^Parser) {
    if parser.ch_pos < len(parser.input) {
        parser.ch = parser.input[parser.ch_pos]
    } else {
        parser.ch = 0
    }
    parser.ch_pos += 1
}

parser_peek_ch :: proc(parser: ^Parser) -> u8 {
    if parser.ch_pos < len(parser.input) {
        return parser.input[parser.ch_pos]
    }
    return 0
}

is_whitespace_ch :: proc(ch: u8) -> bool {
    return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t'
}

is_reserved_ch :: proc(ch: u8) -> bool {
    switch ch {
    case '(', ')', ':', '.', '\'', '`', ',', '@', '"': 
        return true
    case:
        return false
    }
}

is_digit :: proc(ch: u8) -> bool {
    return '0' <= ch && ch <= '9'
}

parser_skip_whitespace :: proc(parser: ^Parser) {
    for is_whitespace_ch(parser.ch) {
        parser_read_ch(parser)
    }
}

parser_read_symbol :: proc(parser: ^Parser) -> (t: Token) {
    t.type = .Symbol
    t.pos  = parser.ch_pos - 1

    for !is_reserved_ch(parser.ch) && !is_whitespace_ch(parser.ch) && parser.ch != 0 {
        parser_read_ch(parser)
    }

    t.len = parser.ch_pos - 1 - t.pos
    return t
}

parser_read_string :: proc(parser: ^Parser) -> (t: Token) {
    t.type = .String
    t.pos  = parser.ch_pos - 1

    parser_read_ch(parser) // skip '"'

    for parser.ch != 0 && parser.ch != '"' {
        parser_read_ch(parser)
    }

    if parser.ch != '"' {
        fatalf("Malformed string")
    }

    parser_read_ch(parser)

    t.len = parser.ch_pos - 1 - t.pos
    return t
}


parser_read_num :: proc(parser: ^Parser) -> (t: Token) {
    t.type = .Symbol
    t.pos  = parser.ch_pos - 1

    if parser.ch == '-' {
        parser_read_ch(parser)
    }

    for is_digit(parser.ch) {
        parser_read_ch(parser)
    }

    t.len = parser.ch_pos - 1 - t.pos
    return t
}

parser_read_token :: proc(parser: ^Parser) -> (t: Token) {
    parser_skip_whitespace(parser)
    t.pos = parser.ch_pos - 1
    t.len = 1

    switch parser.ch {
    case 0:    t.type = .EOF;
    case '(':  t.type = .POpen
    case ')':  t.type = .PClose
    case '.':  t.type = .Dot
    case '\'': t.type = .Quote
    case '`':  t.type = .Backtick
    case ',':
        if parser_peek_ch(parser) == '@' {
            parser_read_ch(parser)
            parser_read_ch(parser)

            t.len  = 2
            t.type = .Comma_At
            return
        }
        t.type = .Comma
    case '"': return parser_read_string(parser)
    case '-':
        if is_digit(parser_peek_ch(parser)) {
            return parser_read_num(parser)
        }
        return parser_read_symbol(parser)
    case:
        if is_digit(parser.ch) {
            return parser_read_num(parser)
        }

        return parser_read_symbol(parser)
    }

    parser_read_ch(parser)
    return t
}

parser_next_token :: proc(parser: ^Parser) {
    parser.current_token = parser.peek_token
    parser.peek_token    = parser_read_token(parser)
}

parser_init :: proc(parser: ^Parser, ctx: ^Context, input: string) {
    parser.ctx   = ctx
    parser.input = input
    parser_read_ch(parser)
    parser_next_token(parser)
    parser_next_token(parser)
}

parser_destroy :: proc(parser: ^Parser) {
    parser^ = {}
}
