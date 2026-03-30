package lispi

import "core:math/bits"
// Calling convention:
//  proc(<todo>) -> (u8, bool)
//  A call will put all variables into the first stack registers of the frame, started at 1 ..= <params count>
//  The return value is a register (or 0 for nil) and a boolean indicating if we are in a panic or not. True means no panic, false means panic. TODO(robin): come up with a better way for panics?

import "core:strings"
import "core:mem/virtual"

vm_thing_new :: proc(vm: ^VM, type: Thing_Type) -> ^Thing {
    if vm.gc_things_threshold < vm.alive_things {
        // TODO(robin): call gc
        // run gc
        // gc(ctx, root)
        vm.gc_things_threshold = vm.alive_things * 2
    }

    if vm.dead_things != nil {
        new_thing        := vm.dead_things
        vm.dead_things   = new_thing.next_dead
        new_thing^        = { info = { type = type } }
        vm.alive_things += 1
        return new_thing
    }

    thing, _         := virtual.new(&vm.things, Thing)
    thing.info.type   = type
    vm.alive_things += 1
    vm.total_things += 1
    return thing
}

vm_thing_num :: proc(vm: ^VM, num: i32) -> (thing: ^Thing) {
    thing     = vm_thing_new(vm, .Num)
    thing.num = num
    return thing
}

vm_thing_string :: proc(vm: ^VM, block: ^String_Block) -> (thing: ^Thing) {
    thing     = vm_thing_new(vm, .String)
    thing.str = block
    return thing
}

vm_thing_cons :: proc(vm: ^VM, car, cdr: ^Thing) -> (thing: ^Thing) {
    thing          = vm_thing_new(vm, .Cons)
    thing.cons.car = car
    thing.cons.cdr = cdr
    return thing
}

vm_thing_symbol :: proc(vm: ^VM, name: string) -> (thing: ^Thing) {
    thing        = vm_thing_new(vm, .Symbol)
    thing.symbol = strings.clone(name, virtual.arena_allocator(&vm.strings))
    return
}

vm_thing_symbol_intern :: proc(vm: ^VM, name: string) -> ^Thing {
    sym: ^Thing
    // TODO(robin): find out gc roots handling
    // root, _ = root_new_guard(root, &sym)

    symbol := symbol_map_upsert(&vm.symbol_map, name, &vm.symbols)
    if symbol.thing != nil {
        return symbol.thing
    }

    symbol.thing = vm_thing_symbol(vm, name)
    return symbol.thing
}

vm_thing_function :: proc(vm: ^VM, params, code, env: ^Thing, type: Thing_Type) -> (thing: ^Thing) {
    assert(type == .Function || type == .Macro)

    thing                 = vm_thing_new(vm, type)
    thing.function.params = params
    thing.function.code   = code
    thing.function.env    = env
    return
}

vm_thing_builtin :: proc(vm: ^VM, builtin: Thing_Builtin) -> (thing: ^Thing) {
    thing         = vm_thing_new(vm, .Builtin)
    thing.builtin = builtin
    return
}

vm_thing_env :: proc(vm: ^VM, parent: ^Thing, vars: ^Symbol_Map) -> (thing: ^Thing) {
    thing     = vm_thing_new(vm, .Env)
    thing.env = { parent = parent, vars = vars }
    return
}

vm_thing_kill :: proc(ctx: ^Runtime_Context, thing: ^Thing) {
    thing.info.type   = .Dead
    thing.next_dead   = ctx.dead_things
    ctx.dead_things   = thing
    ctx.alive_things -= 1
}

Stack_Block :: struct {
    prev: ^Stack_Block,
    len:  int,
    data: [0]Thing,
}

Stack_Frame :: struct {
    prev:  ^Stack_Frame,
    block: ^Stack_Block,
    start: int,
    end:   int,
}

VM :: struct {
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

    stack_block_free_list: ^Stack_Block,

    stack_start: ^Stack_Frame,
    stack_end:   ^Stack_Frame,
}

vm_load :: proc(c: ^Compiler) -> (vm: VM) {
    // Disabel gc for now
    vm.gc_things_threshold = bits.INT_MAX
    defer vm.gc_things_threshold = vm.alive_things


    return
}
