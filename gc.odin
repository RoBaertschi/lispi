package lispi

import "base:runtime"

import "core:slice"
import "core:mem/virtual"

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

