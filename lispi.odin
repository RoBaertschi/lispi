package lispi

import "core:math/bits"
import "core:strconv"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:log"
import "core:slice"
import "base:runtime"
import "core:hash"
import "core:mem/virtual"

GC_DEBUG :: #config(LISPI_GC_DEBUG, ODIN_DEBUG)

fatalf :: proc(fmt: string, args: ..any) -> ! {
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
root_new_guard :: #force_inline proc(root: ^Root, vars: ..^^Thing, collisions := []runtime.Allocator{}, loc := #caller_location) -> (new_root: ^Root, temp: Temp_Allocator) {
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
        gc_mark_string(ctx, thing.str)
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
                thing.info.marked = false
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
                fmt.print(string(block.data[:block.len]))
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
        if parser.ch == '\\' && parser_peek_ch(parser) == '"' {
            parser_read_ch(parser)
        }
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
    t.type = .Num
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
    case 0:    t.type = .EOF
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

parser_produce_internal :: proc(parser: ^Parser, root: ^Root, symbol: string) -> ^Thing {
    root := root
    list, sym: ^Thing
    root, _ = root_new_guard(root, &list, &sym)
    parser_next_token(parser)
    sym     = thing_symbol_intern(parser.ctx, root, symbol)
    list    = parser_read(parser, root)
    list    = thing_cons(parser.ctx, root, list, parser.ctx.nil_)
    list    = thing_cons(parser.ctx, root, sym, list)
    return list
}

parser_unqoute_string :: proc(parser: ^Parser, root: ^Root, token: Token) -> ^Thing {
    head, tail: ^String_Block

    largest := String_Block_Size.Small
    for ;string_block_sizes_thresholds[largest] < token.len && largest <= .Huge; largest += String_Block_Size(1) {}

    token_data := parser.input[token.pos:token.pos+token.len]

    for i := 1; i < token.len - 1; i += 1 {
        if head == nil {
            head = string_block_new(&parser.ctx.strings, largest, &parser.ctx.dead_string_blocks)
            tail = head
        }
        if tail.len >= tail.cap {
            tail.next = string_block_new(&parser.ctx.strings, largest, &parser.ctx.dead_string_blocks)
            tail      = tail.next
        }

        if token_data[i] == '\\' {
            i += 1

            if i >= token.len-1 {
                // TODO(robin): Can this even happen?
                fatalf("Invalid escape at end of string")
            }

            escaped: u8
            switch token_data[i] {
            case 'n':  escaped = '\n'
            case 'r':  escaped = '\r'
            case 't':  escaped = '\t'
            case 'v':  escaped = '\v'
            case 'f':  escaped = '\f'
            case 'b':  escaped = '\b'
            case '"':  escaped = '\"'
            case '\'': escaped = '\''
            case '\\': escaped = '\\'
            case:      fatalf("Invalid escape sequence: %r", rune(token_data[i]))
            }

            #no_bounds_check {
                tail.data[tail.len] = escaped
            }
            tail.len            += 1
        } else {
            #no_bounds_check {
                tail.data[tail.len] = token_data[i]
            }
            tail.len            += 1
        }
    }

    parser_next_token(parser)
    return thing_string(parser.ctx, root, head)
}

parser_read :: proc(parser: ^Parser, root: ^Root) -> ^Thing {
    root := root
    simple: ^Thing

    token_string := parser.input[parser.current_token.pos:parser.current_token.pos + parser.current_token.len]

    switch parser.current_token.type {
    case .Invalid:
        fatalf("Invalid token")
    case .EOF:
        fatalf("Invalid EOF")
    case .String:   return parser_unqoute_string(parser, root, parser.current_token)
    case .Quote:    return parser_produce_internal(parser, root, "quote")
    case .Backtick: return parser_produce_internal(parser, root, "quasiquote")
    case .Comma:    return parser_produce_internal(parser, root, "unquote")
    case .Comma_At: return parser_produce_internal(parser, root, "unquote-splicing")
    case .POpen:
        parser_next_token(parser)
        if parser.current_token.type == .PClose {
            parser_next_token(parser)
            return parser.ctx.nil_
        }

        start, head, current, t: ^Thing
        root, _ = root_new_guard(root, &start, &head, &current, &t)

        start = parser_read(parser, root)
        if parser.current_token.type == .Dot {
            parser_next_token(parser)
            head = parser_read(parser, root)
            if parser.current_token.type != .PClose {
                fatalf("Expected a ')' after a cons")
            }
            parser_next_token(parser)
            start = thing_cons(parser.ctx, root, start, head)
            return start
        }

        head    = thing_cons(parser.ctx, root, start, parser.ctx.nil_)
        current = head

        for parser.current_token.type != .PClose {
            t                = parser_read(parser, root)
            current.cons.cdr = thing_cons(parser.ctx, root, t, parser.ctx.nil_)
            current          = current.cons.cdr
        }
        parser_next_token(parser)
        return head
    case .PClose, .Dot:
        fatalf("Unexpected '%r'", rune(parser.ch))
    case .Symbol:
        simple = thing_symbol_intern(parser.ctx, root, token_string)
    case .Num:
        val, ok := strconv.parse_int(token_string)
        if !ok {
            fatalf("Invalid number %q", token_string)
        }

        if  bits.I32_MAX < val || val < bits.I32_MIN {
            fatalf("Number (%d) does not fit into 32-bit number", val)
        }
        simple = thing_num(parser.ctx, root, i32(val))
    }

    parser_next_token(parser)
    return simple
}

is_list :: proc(ctx: ^Context, t: ^Thing) -> bool {
    return t == ctx.nil_ || t.info.type == .Cons
}

list_length :: proc(ctx: ^Context, t: ^Thing) -> (len: int) {
    t := t

    for {
        if t == ctx.nil_ {
            return
        }

        if t.info.type != .Cons {
            fatalf("length: Invalid, non-cons, list item")
        }

        t    = t.cons.cdr
        len += 1
    }
}

env_find :: proc(ctx: ^Context, env, sym: ^Thing) -> ^Thing {
    env := env
    for ; env != ctx.nil_; env = env.env.parent {
        symbol := symbol_map_find(&env.env.vars, sym.symbol)
        if symbol != nil {
            return symbol.thing
        }
    }

    return nil
}

env_find_symbol :: proc(ctx: ^Context, env, sym: ^Thing) -> ^Symbol {
    env := env
    for ; env != ctx.nil_; env = env.env.parent {
        symbol := symbol_map_find(&env.env.vars, sym.symbol)
        if symbol != nil {
            return symbol
        }
    }

    return nil
}

env_find_or_create_symbol :: proc(ctx: ^Context, env, sym: ^Thing) -> ^Symbol {
    for iter_env := env ; iter_env != ctx.nil_; iter_env = iter_env.env.parent {
        symbol := symbol_map_find(&iter_env.env.vars, sym.symbol)
        if symbol != nil {
            return symbol
        }
    }

    // create missing variable
    symbol := symbol_map_upsert_free_list(&env.env.vars, sym.symbol, &ctx.dead_envs, &ctx.symbols)
    return symbol
}

env_from_lists :: proc(ctx: ^Context, root: ^Root, env, keys, values: ^Thing) -> ^Thing {
    root := root
    vars: ^Symbol_Map
    k, v := keys, values
    root, _ = root_new_guard(root, &k, &v)

    for {
        if k == ctx.nil_ || v == ctx.nil_ {
            break
        }

        symbol       := symbol_map_upsert_free_list(&vars, k.cons.car.symbol, &ctx.dead_envs, &ctx.symbols)
        symbol.thing  = v.cons.car

        k = k.cons.cdr
        v = v.cons.cdr
    }

    if k != ctx.nil_ || v != ctx.nil_ {
        fatalf("apply: Mismatch in length for keys and values")
    }

    return thing_env(ctx, root, env, vars)
}

env_add_builtin :: proc(ctx: ^Context, root: ^Root, env : ^Thing, name: string, builtin: Thing_Builtin) {
    root := root
    builtin_thing: ^Thing
    root, _        = root_new_guard(root, &builtin_thing)
    builtin_thing  = thing_builtin(ctx, root, builtin)
    symbol        := symbol_map_upsert_free_list(&env.env.vars, name, &ctx.dead_envs, &ctx.symbols)
    symbol.thing   = builtin_thing
}

env_add_variable :: proc(ctx: ^Context, env, key, value: ^Thing) {
    symbol       := symbol_map_upsert_free_list(&env.env.vars, key.symbol, &ctx.dead_envs, &ctx.symbols)
    symbol.thing  = value
}

eval_list :: proc(ctx: ^Context, root: ^Root, env, list: ^Thing) -> ^Thing {
    root := root
    head, current, t, element: ^Thing
    root, _ = root_new_guard(root, &head, &current, &t, &element)

    for element = list; element != ctx.nil_; element = element.cons.cdr {
        t = eval(ctx, root, env, element.cons.car)
        if head == nil {
            head    = thing_cons(ctx, root, t, ctx.nil_)
            current = head
        } else {
            current.cons.cdr = thing_cons(ctx, root, t, ctx.nil_)
            current          = current.cons.cdr
        }
    }

    if head == nil {
        head = ctx.nil_
    }

    return head
}

apply :: proc(ctx: ^Context, root: ^Root, env, fn, args: ^Thing) -> ^Thing {
    root := root
    if !is_list(ctx, args) {
        fatalf("apply: args must be a list")
    }

    if fn.info.type == .Builtin {
        return fn.builtin(ctx, root, env, args)
    }

    evaluated_args, new_env: ^Thing
    root, _ = root_new_guard(root, &evaluated_args, &new_env)

    evaluated_args = eval_list(ctx, root, env, args)
    new_env        = env_from_lists(ctx, root, fn.function.env, fn.function.params, evaluated_args)

    return progn(ctx, root, new_env, fn.function.code)
}

progn :: proc(ctx: ^Context, root: ^Root, env, list: ^Thing) -> (result: ^Thing) {
    root := root
    element: ^Thing
    root, _ = root_new_guard(root, &result, &element)
    for element = list; element != ctx.nil_; element = element.cons.cdr {
        result = eval(ctx, root, env, element.cons.car)
    }
    return result
}

macro_expand :: proc(ctx: ^Context, root: ^Root, env, t: ^Thing) -> ^Thing {
    root := root

    if t.info.type != .Cons || t.cons.car.info.type != .Symbol {
        return t
    }

    macro := env_find(ctx, env, t.cons.car)
    if macro == nil || macro.info.type != .Macro {
        return t
    }

    args, params, new_env: ^Thing
    root, _ = root_new_guard(root, &args, &params, &new_env)

    args    = t.cons.cdr
    params  = macro.function.params
    new_env = env_from_lists(ctx, root, env, params, args)
    return progn(ctx, root, new_env, macro.function.code)
}

eval :: proc(ctx: ^Context, root: ^Root, env, code: ^Thing) -> ^Thing {
    root := root

    switch code.info.type {
    case .Num, .String, .Nil, .T, .Function, .Builtin:
        return code
    case .Cons:
        expanded, fn, args: ^Thing
        root, _ = root_new_guard(root, &expanded, &fn, &args)
        expanded = macro_expand(ctx, root, env, code)
        if expanded != code {
            return eval(ctx, root, env, expanded)
        }

        fn   = eval(ctx, root, env, expanded.cons.car)
        args = expanded.cons.cdr
        if fn.info.type != .Builtin && fn.info.type != .Function {
            fatalf("eval: Expected function to call, got %v", fn.info.type)
        }
        return apply(ctx, root, env, fn, args)
    case .Symbol:
        t := env_find(ctx, env, code)
        if t == nil {
            fatalf("eval: Could not find symbol: %s", code.symbol)
        }
        return t
    case .Dead, .Env, .Macro:
        fatalf("eval: Invalid thing type: %v", code.info.type)
    }

    unreachable()
}

// Builtins

Math_Operator :: enum {
    Add,
    Sub,
    Mul,
    Div,
}

handle_math :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing, $op: Math_Operator) -> ^Thing {
    root := root

    evaluated_args, num: ^Thing
    root, _ = root_new_guard(root, &evaluated_args, &num)

    evaluated_args = eval_list(ctx, root, env, args)
    if evaluated_args.info.type != .Cons {
        fatalf("op: one argument is required at least")
    }

    num = evaluated_args.cons.car
    if num.info.type != .Num {
        fatalf("op: Invalid argument of type %v", num.info.type)
    }

    result := num.num
    evaluated_args = evaluated_args.cons.cdr

    for num_cons := evaluated_args; num_cons != ctx.nil_; num_cons = num_cons.cons.cdr {
        num = num_cons.cons.car
        if num.info.type != .Num {
            fatalf("op: Invalid argument of type %v", num.info.type)
        }

        when op == .Add {
            result += num.num
        } else when op == .Sub {
            result -= num.num
        } else when op == .Mul {
            result *= num.num
        } else when op == .Div {
            result /= num.num
        } else {
            #panic("Unsupported Math_Operator")
        }
    }

    return thing_num(ctx, root, result)
}

builtin_add :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_math(ctx, root, env, args, .Add)
}
builtin_sub :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_math(ctx, root, env, args, .Sub)
}

builtin_mul :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_math(ctx, root, env, args, .Mul)
}
builtin_div :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_math(ctx, root, env, args, .Div)
}


Cmp_Operator :: enum {
    LT,
    GT,
    EQ,
}

handle_cmp :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing, $op: Cmp_Operator) -> (result: ^Thing) {
    root := root

    evaluated_args := eval_list(ctx, root, env, args)
    root, _         = root_new_guard(root, &result, &evaluated_args)


    if list_length(ctx, evaluated_args) != 2 {
        fatalf("cmp: Exactly 2 arguments are required")
    }

    if evaluated_args.cons.car.info.type != .Num || evaluated_args.cons.cdr.cons.car.info.type != .Num {
        fatalf("cmp: Arguments have to be nums")
    }

    first  := evaluated_args.cons.car.num
    second := evaluated_args.cons.cdr.cons.car.num

    when op == .LT {
        result = first <  second ? ctx.t : ctx.nil_
    } else when op == .GT {
        result = first >  second ? ctx.t : ctx.nil_
    } else when op == .EQ {
        result = first == second ? ctx.t : ctx.nil_
    }

    return result
}

builtin_lt :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing { return handle_cmp(ctx, root, env, args, .LT) }
builtin_gt :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing { return handle_cmp(ctx, root, env, args, .GT) }
builtin_eq :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing { return handle_cmp(ctx, root, env, args, .EQ) }

handle_function :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing, type: Thing_Type, $builtin_name: string) -> ^Thing {
    root := root

    if args.info.type != .Cons || !is_list(ctx, args.cons.car) {
        fatalf(builtin_name + ": Parameter list must be a list")
    }

    if args.cons.cdr.info.type != .Cons {
        fatalf(builtin_name + ": Body must be a list")
    }

    param := args.cons.car

    for ; param.info.type == .Cons; param = param.cons.cdr {
        if (param.cons.car.info.type != .Symbol) {
            fatalf(builtin_name + ": Parameter must be a symbol")
        }

        if (!is_list(ctx, param.cons.cdr)) {
            fatalf(builtin_name + ": Parameter must be a flat list")
        }
    }

    if (param != ctx.nil_ && param.info.type != .Symbol) {
        fatalf(builtin_name + ": Parameter must be a symbol")
    }

    params, code: ^Thing
    root, _ = root_new_guard(root, &params, &code)
    params  = args.cons.car
    code    = args.cons.cdr
    return thing_function(ctx, root, params, code, env, type)
}

builtin_lambda :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_function(ctx, root, env, args, .Function, "lambda")
}

handle_deffun :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing, type: Thing_Type, $builtin_name: string) -> ^Thing {
    root := root
    fn_sym, fn_args, fn: ^Thing

    root, _ = root_new_guard(root, &fn_sym, &fn_args, &fn)
    fn_sym  = args.cons.car
    fn_args = args.cons.cdr

    if fn_sym.info.type != .Symbol {
        fatalf(builtin_name + ": Expected symbol as first argument")
    }

    fn = handle_function(ctx, root, env, fn_args, type, builtin_name)

    env_add_variable(ctx, env, fn_sym, fn)
    return fn
}

builtin_deffun :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_deffun(ctx, root, env, args, .Function, "deffun")
}

builtin_defmacro :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return handle_deffun(ctx, root, env, args, .Macro, "defmacro")
}


builtin_define :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    root := root

    if list_length(ctx, args) != 2 || args.cons.car.info.type != .Symbol {
        fatalf("define: First parameter should be symbol")
    }

    sym, value: ^Thing
    root, _ = root_new_guard(root, &sym, &value)
    sym     = args.cons.car
    value   = args.cons.cdr.cons.car
    value   = eval(ctx, root, env, value)
    env_add_variable(ctx, env, sym, value)
    return value
}

builtin_progn :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return progn(ctx, root, env, args)
}

builtin_macroexpand :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    if list_length(ctx, args) != 1 {
        fatalf("macroexpand: Only accept one argument")
    }

    return macro_expand(ctx, root, env, args.cons.car)
}

builtin_quote :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    if list_length(ctx, args) != 1 {
        fatalf("quote: Only accept one argument")
    }

    return args.cons.car
}

quasiquote_expand :: proc(ctx: ^Context, root: ^Root, env, list: ^Thing) -> ^Thing {
    root := root
    if (list.info.type != .Cons) {
        return list
    }

    sym, rest, element, result: ^Thing
    root, _ = root_new_guard(root, &sym, &rest, &element, &result)
    element = list
    sym     = list.cons.car
    rest    = list.cons.cdr

    if sym.info.type == .Symbol && sym.symbol == "unquote" {
        return eval(ctx, root, env, rest.cons.car)
    }
    if sym.info.type == .Cons && sym.cons.car.info.type == .Symbol && sym.cons.car.symbol == "unquote-splicing" {
        result = eval(ctx, root, env, sym.cons.cdr.cons.car)
        rest   = quasiquote_expand(ctx, root, env, rest)

        return thing_append(ctx, root, result, rest)
    }

    sym  = quasiquote_expand(ctx, root, env, sym)
    rest = quasiquote_expand(ctx, root, env, rest)
    return thing_cons(ctx, root, sym, rest)
}

builtin_quasiquote :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    if args == ctx.nil_ {
        return ctx.nil_
    }

    return quasiquote_expand(ctx, root, env, args.cons.car)
}

builtin_cons :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    if list_length(ctx, args) != 2 {
        fatalf("cons: Exactly 2 arguments required")
    }
    cell := eval_list(ctx, root, env, args)
    cell.cons.cdr = cell.cons.cdr.cons.car
    return cell
}

builtin_car :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    evaluated_args := eval_list(ctx, root, env, args)
    if evaluated_args.cons.car.info.type != .Cons || evaluated_args.cons.cdr != ctx.nil_ {
        fatalf("car: Expected a single cons argument")
    }
    return evaluated_args.cons.car.cons.car
}

builtin_cdr :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    evaluated_args := eval_list(ctx, root, env, args)
    if evaluated_args.cons.car.info.type != .Cons || evaluated_args.cons.cdr != ctx.nil_ {
        fatalf("cdr: Expected a single cons argument")
    }
    return evaluated_args.cons.car.cons.cdr
}

builtin_list :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    return eval_list(ctx, root, env, args)
}

builtin_setq :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    root := root

    if list_length(ctx, args) != 2 || args.cons.car.info.type != .Symbol {
        fatalf("setq: Malformed setq")
    }

    value: ^Thing
    root, _ = root_new_guard(root, &value)
    bind_symbol := env_find_or_create_symbol(ctx, env, args.cons.car)
    value = eval(ctx, root, env, args.cons.cdr.cons.car)
    bind_symbol.thing = value
    return value
}

builtin_setcar :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    root := root
    evaluated_args: ^Thing
    root, _ = root_new_guard(root, &evaluated_args)
    evaluated_args = eval_list(ctx, root, env, args)
    if list_length(ctx, evaluated_args) != 2 || evaluated_args.cons.car.info.type != .Cons {
        fatalf("setcar: Expected a cons and a value")
    }
    evaluated_args.cons.car.cons.car = evaluated_args.cons.cdr.cons.car
    return evaluated_args.cons.car
}

builtin_while :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    root := root

    if list_length(ctx, args) < 2 {
        fatalf("while: Malformed while")
    }

    cond: ^Thing
    root, _ = root_new_guard(root, &cond)
    cond = args.cons.car
    for eval(ctx, root, env, cond) != ctx.nil_ {
        progn(ctx, root, env, args.cons.cdr)
    }

    return ctx.nil_
}

builtin_gensym :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    name := fmt.tprintf("G__%d", ctx.gen_symbol_counter)
    ctx.gen_symbol_counter += 1
    return thing_symbol(ctx, root, name)
}

builtin_print :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    root := root
    evaluated_args: ^Thing
    root, _ = root_new_guard(root, &evaluated_args)
    evaluated_args = eval_list(ctx, root, env, args)
    for tmp := evaluated_args; tmp.info.type == .Cons; tmp = tmp.cons.cdr {
        print(ctx, tmp.cons.car)
        fmt.println()
    }
    return ctx.nil_
}

builtin_thing_eq :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    if list_length(ctx, args) != 2 {
        fatalf("eq: Exactly 2 arguments required")
    }
    values := eval_list(ctx, root, env, args)
    return values.cons.car == values.cons.cdr.cons.car ? ctx.t : ctx.nil_
}

builtin_gc :: proc(ctx: ^Context, root: ^Root, env, args: ^Thing) -> ^Thing {
    gc(ctx, root)
    return ctx.nil_
}

ctx_init :: proc(ctx: ^Context, root: ^Root) {
    root := root

    ctx.gc_things_threshold = 32
    ctx.nil_                = thing_new(ctx, root, .Nil)
    ctx.t                   = thing_new(ctx, root, .T)
    ctx.env                 = thing_env(ctx, root, ctx.nil_, nil)

    tmp: ^Thing
    root, _ = root_new_guard(root, &tmp)
    tmp     = thing_symbol_intern(ctx, root, "t")

    env_add_variable(ctx, ctx.env, tmp, ctx.t)

    env_add_builtin(ctx, root, ctx.env, "+",           builtin_add)
    env_add_builtin(ctx, root, ctx.env, "-",           builtin_sub)
    env_add_builtin(ctx, root, ctx.env, "*",           builtin_mul)
    env_add_builtin(ctx, root, ctx.env, "/",           builtin_div)
    env_add_builtin(ctx, root, ctx.env, "<",           builtin_lt)
    env_add_builtin(ctx, root, ctx.env, ">",           builtin_gt)
    env_add_builtin(ctx, root, ctx.env, "=",           builtin_eq)
    env_add_builtin(ctx, root, ctx.env, "lambda",      builtin_lambda)
    env_add_builtin(ctx, root, ctx.env, "deffun",      builtin_deffun)
    env_add_builtin(ctx, root, ctx.env, "defmacro",    builtin_defmacro)
    env_add_builtin(ctx, root, ctx.env, "define",      builtin_define)
    env_add_builtin(ctx, root, ctx.env, "progn",       builtin_progn)
    env_add_builtin(ctx, root, ctx.env, "macroexpand", builtin_macroexpand)
    env_add_builtin(ctx, root, ctx.env, "quote",       builtin_quote)
    env_add_builtin(ctx, root, ctx.env, "quasiquote",  builtin_quasiquote)
    env_add_builtin(ctx, root, ctx.env, "cons",        builtin_cons)
    env_add_builtin(ctx, root, ctx.env, "car",         builtin_car)
    env_add_builtin(ctx, root, ctx.env, "cdr",         builtin_cdr)
    env_add_builtin(ctx, root, ctx.env, "list",        builtin_list)
    env_add_builtin(ctx, root, ctx.env, "setq",        builtin_setq)
    env_add_builtin(ctx, root, ctx.env, "setcar",      builtin_setcar)
    env_add_builtin(ctx, root, ctx.env, "while",       builtin_while)
    env_add_builtin(ctx, root, ctx.env, "gensym",      builtin_gensym)
    env_add_builtin(ctx, root, ctx.env, "print",       builtin_print)
    env_add_builtin(ctx, root, ctx.env, "eq",          builtin_thing_eq)
    env_add_builtin(ctx, root, ctx.env, "gc",          builtin_gc)
}

ctx_destroy :: proc(ctx: ^Context) {
    virtual.arena_destroy(&ctx.things)
    virtual.arena_destroy(&ctx.symbols)
    virtual.arena_destroy(&ctx.strings)
    ctx^ = {}
}

main :: proc() {
    context.logger = log.create_console_logger()
    args := os.args

    if len(args) < 2 {
        fatalf("Missing arguments. Required at least one.\n")
    }

    data, err := os.read_entire_file(args[1], context.allocator)
    if err != nil {
        fatalf("Could not read file %q: %v", args[1], err)
    }
    defer delete(data)

    {
        ctx: Context
        root: ^Root
        result: ^Thing
        root, _ = root_new_guard(root, &result)

        ctx_init(&ctx, root)
        defer ctx_destroy(&ctx)

        parser: Parser
        parser_init(&parser, &ctx, string(data))
        defer parser_destroy(&parser)

        for parser.current_token.type != .EOF {
            result = parser_read(&parser, root)
            result = eval(&ctx, root, ctx.env, result)
        }

        when GC_DEBUG {
            log.debugf("Alive/Total things: %d/%d", ctx.alive_things, ctx.total_things)
        }
    }
}
