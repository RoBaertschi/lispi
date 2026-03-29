package lispi

import "core:math/bits"
import "core:container/xar"
import "core:log"
import "core:path/filepath"
import "core:fmt"
import "core:os"
import "core:hash"
import "core:strings"
import "core:mem/virtual"

// Compile-time Things
// These are different from the runtime ones, because we don't want to gc any of them. We only allocate things we actually need
// with the exception of a few objects that won't make the difference

Compile_Context :: struct {
    arena:      virtual.Arena, // We share the arena, because we don't actually need to iterate over all objects or symbols or strings
    symbol_map: ^Symbol_Map,
    env:        ^Thing,
    nil_:       ^Thing,
    t:          ^Thing,
}

compile_thing_new :: proc(ctx: ^Compile_Context, type: Thing_Type) -> ^Thing {
    thing, _         := virtual.new(&ctx.arena, Thing)
    thing.info.type   = type
    return thing
}

compile_thing_num :: proc(ctx: ^Compile_Context, num: i32) -> (thing: ^Thing) {
    thing     = compile_thing_new(ctx, .Num)
    thing.num = num
    return thing
}

compile_thing_string :: proc(ctx: ^Compile_Context, block: ^String_Block) -> (thing: ^Thing) {
    thing     = compile_thing_new(ctx, .String)
    thing.str = block
    return thing
}

compile_thing_cons :: proc(ctx: ^Compile_Context, car, cdr: ^Thing) -> (thing: ^Thing) {
    thing          = compile_thing_new(ctx, .Cons)
    thing.cons.car = car
    thing.cons.cdr = cdr
    return thing
}

compile_thing_symbol :: proc(ctx: ^Compile_Context, name: string) -> (thing: ^Thing) {
    thing        = compile_thing_new(ctx, .Symbol)
    thing.symbol = strings.clone(name, virtual.arena_allocator(&ctx.arena))
    return
}

compile_thing_symbol_intern :: proc(ctx: ^Compile_Context, name: string) -> ^Thing {
    symbol := symbol_map_upsert(&ctx.symbol_map, name, &ctx.arena)
    if symbol.thing != nil {
        return symbol.thing
    }

    symbol.thing = compile_thing_symbol(ctx, name)
    return symbol.thing
}

compile_thing_function :: proc(ctx: ^Compile_Context, params, code, env: ^Thing, type: Thing_Type) -> (thing: ^Thing) {
    assert(type == .Function || type == .Macro)

    thing                 = compile_thing_new(ctx, type)
    thing.function.params = params
    thing.function.code   = code
    thing.function.env    = env
    return
}

compile_thing_builtin :: proc(ctx: ^Compile_Context, builtin: Thing_Builtin) -> (thing: ^Thing) {
    thing         = compile_thing_new(ctx, .Builtin)
    thing.builtin = builtin
    return
}

compile_thing_env :: proc(ctx: ^Compile_Context, parent: ^Thing, vars: ^Symbol_Map) -> (thing: ^Thing) {
    thing     = compile_thing_new(ctx, .Env)
    thing.env = { parent = parent, vars = vars }
    return
}

compile_thing_acons :: proc(ctx: ^Compile_Context, x, y, a: ^Thing) -> ^Thing {
    cell := compile_thing_cons(ctx, x, y)
    return compile_thing_cons(ctx, cell, a)
}

// String Set

String_Map :: struct {
    key:   string,
    child: [4]^String_Map,
    value: int, // index into the strings table
}

string_map_upsert :: proc(s: ^^String_Map, key: string, arena: ^virtual.Arena) -> ^int {
    s := s
    for h := hash.fnv32a(transmute([]byte)key); s^ != nil; h <<= 2 {
        if key == s^.key {
            return &s^.value
        }
        s = &s^.child[h>>30]
    }

    if arena == nil {
        return nil
    }

    s^, _  = virtual.new(arena, String_Map)
    s^.key = key
    return &s^.value
}

// Objects

Object_Type :: enum {
    Invalid,
    Package,
    Function,
    Macro,
    Define,
}

Object_Map :: struct {
    key:   string,
    child: [4]^Object_Map,
    value: Object,
}

object_map_upsert :: proc(m: ^^Object_Map, key: string, arena: ^virtual.Arena) -> ^Object {
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

    m^, _  = virtual.new(arena, Object_Map)
    m^.key = key
    return &m^.value
}

Object :: struct {
    type:   Object_Type,
    chunk:  Chunk,
    thing:  ^Thing,
    symbol: ^Thing,
    args:   ^Thing, // Args after symbol
}

Package :: struct {
    arena:    virtual.Arena,
    objects:  ^Object_Map,
    pkg:      ^Thing,
    pkg_name: string,

    // String table
    strings:    xar.Array(string, 8),
    string_map: ^String_Map, // NOTE: key's in here point to the keys in strings
}

Compiler :: struct {
    arena:        virtual.Arena,
    root_package: ^Package,
    ctx:          Compile_Context,

    deffun:   ^Thing,
    defmacro: ^Thing,
    define:   ^Thing,
    package_: ^Thing,

    errors: int,
}

package_new :: proc() -> ^Package {
    pkg, _ := virtual.arena_growing_bootstrap_new(Package, "arena")
    return pkg
}

compile_error :: proc(c: ^Compiler, format: string, args: ..any) {
    c.errors += 1
    fmt.println("COMPILE ERROR: ")
    fmt.printf(format, ..args)
    fmt.println()
}

// Compiles the package and all of its dependencies at root_package
compile :: proc(root_package: string) -> (c: Compiler, err: os.Error) {
    temp := TEMP_ALLOCATOR_GUARD({})

    c.ctx.nil_ = compile_thing_new(&c.ctx, .Nil)
    c.ctx.t    = compile_thing_new(&c.ctx, .T)
    c.deffun   = compile_thing_symbol_intern(&c.ctx, "deffun")
    c.defmacro = compile_thing_symbol_intern(&c.ctx, "defmacro")
    c.define   = compile_thing_symbol_intern(&c.ctx, "define")
    c.package_ = compile_thing_symbol_intern(&c.ctx, "package")

    c.root_package = compile_package(&c, root_package) or_return

    return
}

compile_package :: proc(c: ^Compiler, package_dir_path: string) -> (pkg: ^Package, err: os.Error) {
    temp := TEMP_ALLOCATOR_GUARD({})

    package_dir := os.open(package_dir_path) or_return
    package_dir_info := os.fstat(package_dir, temp) or_return

    if package_dir_info.type != .Directory {
        compile_error(c, "package %q is not a directory", package_dir_path)
        return
    }

    files := os.read_dir(package_dir, 0, temp) or_return

    pkg = package_new()

    // Collect objects
    for file in files {
        if file.type != .Regular && file.type != .Symlink {
            continue
        }

        if filepath.ext(file.fullpath) != ".lispi" {
            continue
        }

        f, os_err := os.open(file.fullpath)
        if os_err != nil {
            compile_error(c, "could not open package file %q", file.fullpath)
            continue
        }

        file_data_temp := TEMP_ALLOCATOR_GUARD({ temp })
        file_data: []byte
        file_data, os_err = os.read_entire_file(f, file_data_temp)
        if os_err != nil {
            compile_error(c, "could not read package file: %v", os_err)
            continue
        }

        parser: Parser
        parser_init(&parser, &c.ctx, string(file_data))

        for parser.current_token.type != .EOF {
            t := parser_read(&parser)

            if t.info.type != .Cons {
                compile_error(c, "expected top level to be a list but got %v", t.info.type)
            }

            current: ^Thing
            for current = t; current.info.type == .Cons; current = current.cons.cdr {}

            if current != c.ctx.nil_ {
                compile_error(c, "expected top level to be a list, but got invalid list that ends with %v", current.info.type)
                continue
            }

            if t == c.ctx.nil_ {
                compile_error(c, "invalid top level empty list")
                continue
            }

            if t.cons.car.info.type != .Symbol {
                compile_error(c, "expected top level list to be a call, but got %v as first list element", t.cons.car.info.type)
                continue
            }

            sym := t.cons.car
            if sym != c.deffun && sym != c.defmacro && sym != c.define && sym != c.package_ {
                compile_error(c, "expected top level call to be one of 'deffun', 'defmacro' or 'define' but got %q", t.cons.car.symbol)
                continue
            }

            args := t.cons.cdr
            if args.info.type != .Cons {
                compile_error(c, "expected an argument to top level call")
                continue
            }

            object_sym := args.cons.car
            if object_sym.info.type != .Symbol {
                compile_error(c, "expected first argument to top level call to be a symbol, but got %v", object_sym.info.type)
                continue
            }

            if sym == c.package_ {
                if pkg.pkg != nil {
                    compile_error(c, "duplicate package definition")
                    continue
                }

                pkg.pkg      = t
                pkg.pkg_name = object_sym.symbol
            } else {
                if pkg.pkg == nil {
                    compile_error(c, "package definition is required before any other definition")
                }

                object := object_map_upsert(&pkg.objects, object_sym.symbol, &pkg.arena)
                object.thing  = t
                object.symbol = object_sym
                object.args   = args.cons.cdr
                // NOTE: Type will be later evaluated
            }
        }
    }

    iter_object_map :: proc(c: ^Compiler, pkg: ^Package, obj_map: ^Object_Map) {
        compile_object(c, pkg, &obj_map.value)
        log.debug(obj_map.value)

        v := &obj_map.value

        for i in v.chunk.instructions {
            log.debug(i)
        }

        for const in v.chunk.constants {
            #partial switch const.info.type {
            case .Constant_String: log.debug(const, xar.get(&pkg.strings, const.constant_string.index))
            case .Constant_Symbol: log.debug(const, xar.get(&pkg.strings, const.constant_symbol.index))
            }
        }

        for child in obj_map.child {
            if child != nil {
                iter_object_map(c, pkg, child)
            }
        }
    }

    iter_object_map(c, pkg, pkg.objects)

    log.debugf("Objs: %#v", pkg.objects)

    return
}

compile_object :: proc(c: ^Compiler, pkg: ^Package, obj: ^Object) {
    temp := TEMP_ALLOCATOR_GUARD({})

    if obj.thing.cons.car == c.define || obj.thing.cons.car == c.defmacro {
        compile_error(c, "TODO, implement %q", obj.thing.cons.car.symbol)
        return
    }

    instructions: xar.Array(Instruction, 8)
    xar.array_init(&instructions, temp)
    constants: xar.Array(Thing, 4)
    xar.array_init(&constants, temp)

    temp_count: u8
    stack_size: u8

    Function_Compile_Context :: struct {
        c:            ^Compiler,
        pkg:          ^Package,
        obj:          ^Object,
        constants:    ^xar.Array(Thing, 4),
        instructions: ^xar.Array(Instruction, 8),
        temp_count:   ^u8,
        stack_size:   ^u8,
    }

    fcc := Function_Compile_Context{
        c,
        pkg,
        obj,
        &constants,
        &instructions,
        &temp_count,
        &stack_size,
    }

    fcc_new_constant :: proc(fcc: Function_Compile_Context, t: Thing) -> (i: u16) {
        i = u16(xar.len(fcc.constants^))
        xar.push_back(fcc.constants, t)
        return
    }

    fcc_new_temp :: proc(fcc: Function_Compile_Context) -> (t: u8) {
        ensure(fcc.temp_count^ < bits.U8_MAX)
        fcc.temp_count^ += 1
        t = fcc.temp_count^

        if t > fcc.stack_size^ {
            fcc.stack_size^ = t
        }
        return t
    }

    fcc_push_instruction_zero :: proc(fcc: Function_Compile_Context, opcode: Opcode) {
        xar.push_back(fcc.instructions, Instruction{ opcode = opcode })
    }

    fcc_push_instruction_one :: proc(fcc: Function_Compile_Context, opcode: Opcode, operand: u8) {
        xar.push_back(fcc.instructions, Instruction { opcode = opcode, operands = { 0 = operand } })
    }

    fcc_push_instruction_two :: proc(fcc: Function_Compile_Context, opcode: Opcode, first: u8, second: u16) {
        xar.push_back(fcc.instructions, Instruction{ opcode = opcode, operands = { first, u8(second & bits.U8_MAX), u8(second >> 8) } })
    }

    fcc_push_instruction_two_u8 :: proc(fcc: Function_Compile_Context, opcode: Opcode, first: u8, second: u8) {
        xar.push_back(fcc.instructions, Instruction{ opcode = opcode, operands = { first, second, 0 } })
    }

    fcc_push_instruction_three :: proc(fcc: Function_Compile_Context, opcode: Opcode, first, second, third: u8) {
        xar.push_back(fcc.instructions, Instruction{ opcode = opcode, operands = { first, second, third } })
    }

    fcc_push_instruction :: proc{
        fcc_push_instruction_zero,
        fcc_push_instruction_one,
        fcc_push_instruction_two,
        fcc_push_instruction_two_u8,
        fcc_push_instruction_three,
    }

    fcc_save_temps :: proc(fcc: Function_Compile_Context) -> u8 {
        return fcc.temp_count^
    }

    fcc_restore_temps :: proc(fcc: Function_Compile_Context, temp_count: u8) {
        fcc.temp_count^ = temp_count
    }

    @(deferred_in_out=fcc_restore_temps)
    FCC_SAVE_TEMPS_GUARD :: #force_inline proc(fcc: Function_Compile_Context) -> u8 { return fcc_save_temps(fcc) }

    compile_thing :: proc(fcc: Function_Compile_Context, t: ^Thing) -> u8 {
        compile_num :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            temp = fcc_new_temp(fcc)
            constant := fcc_new_constant(fcc, { info = { type = .Num }, num = t.num })
            fcc_push_instruction(fcc, .Load_Constant, temp, constant)
            return
        }

        compile_string :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            temp = fcc_new_temp(fcc)
            // TODO(robin): don't clone the string but instead use the String_Block to get the hash
            s := string_block_clone_to_string(&fcc.pkg.arena, t.str)
            stored_index := string_map_upsert(&fcc.pkg.string_map, s, nil)
            if stored_index != nil {
                // try to find already existing constant
                for iter := xar.iterator(fcc.constants); const, i in xar.iterate_by_val(&iter) {
                    if const.info.type == .Constant_String && const.constant_string.index == stored_index^ {
                        fcc_push_instruction(fcc, .Load_Constant, temp, u16(i))
                        return
                    }
                }

                constant := fcc_new_constant(fcc, { info = { type = .Constant_String }, constant_string = { index = stored_index^ } })
                fcc_push_instruction(fcc, .Load_Constant, temp, constant)
                return
            }
            s_idx := xar.len(fcc.pkg.strings)
            xar.push_back(&fcc.pkg.strings, s)
            stored_index = string_map_upsert(&fcc.pkg.string_map, s, &fcc.pkg.arena)
            stored_index^ = s_idx

            constant := fcc_new_constant(fcc, { info = { type = .Constant_String }, constant_string = { index = s_idx } })

            fcc_push_instruction(fcc, .Load_Constant, temp, constant)
            return
        }

        compile_cons :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            // TODO(robin): handle macros
            // TODO(robin): expand quote and backtick
            temp = fcc_new_temp(fcc)
            args := fcc_new_temp(fcc)
            fcc_push_instruction(fcc, .Load_Nil, args)

            saved_temps := fcc_save_temps(fcc)

            fn_thing   := t.cons.car
            args_thing := t.cons.cdr

            arg_temps: [dynamic; 256]u8

            element: ^Thing

            for element = args_thing; element != fcc.c.ctx.nil_ && element.info.type == .Cons; element = element.cons.cdr {
                // TODO(robin): this currently creates a bunch of temporaries, we should find a way to reduce them if needed and possible
                temp := compile_thing(fcc, element.cons.car)
                ensure(append(&arg_temps, temp) > 0, "Function arguments exeeded 256 arguments, which is currently not supported. Bro, wtf are you doing?")
            }

            #reverse for temp in arg_temps {
                fcc_push_instruction(fcc, .Cons, args, temp, args)
            }

            fcc_restore_temps(fcc, saved_temps)

            if element != fcc.c.ctx.nil_ {
                compile_error(fcc.c, "invalid function call, expected nil at end of list but got %v", element.info.type)
            }

            fn := compile_thing(fcc, fn_thing)
            fcc_push_instruction(fcc, .Call, temp, fn, args)
            fcc_restore_temps(fcc, saved_temps)
            return
        }

        compile_symbol :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            // TODO(robin): handle variables and upvalues

            temp = fcc_new_temp(fcc)
            // TODO(robin): don't clone the string but instead use the String_Block to get the hash
            stored_index := string_map_upsert(&fcc.pkg.string_map, t.symbol, nil)
            if stored_index != nil {
                // try to find already existing constant
                for iter := xar.iterator(fcc.constants); const, i in xar.iterate_by_val(&iter) {
                    if const.info.type == .Constant_Symbol && const.constant_string.index == stored_index^ {
                        fcc_push_instruction(fcc, .Load_Constant, temp, u16(i))
                        return
                    }
                }

                constant := fcc_new_constant(fcc, { info = { type = .Constant_Symbol }, constant_symbol = { index = stored_index^ } })
                fcc_push_instruction(fcc, .Load_Constant, temp, constant)
                return
            }
            s_idx := xar.len(fcc.pkg.strings)
            xar.push_back(&fcc.pkg.strings, t.symbol)
            stored_index = string_map_upsert(&fcc.pkg.string_map, t.symbol, &fcc.pkg.arena)
            stored_index^ = s_idx

            constant := fcc_new_constant(fcc, { info = { type = .Constant_Symbol }, constant_symbol = { index = s_idx } })
            fcc_push_instruction(fcc, .Load_Constant, temp, constant)
            return
        }

        compile_t :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            temp = fcc_new_temp(fcc)
            fcc_push_instruction(fcc, .Load_T, temp)
            return
        }

        compile_nil :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            temp = fcc_new_temp(fcc)
            fcc_push_instruction(fcc, .Load_Nil, temp)
            return
        }

        compile_invalid :: proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8) {
            temp = fcc_new_temp(fcc) // Create dummy temp
            compile_error(fcc.c, "invalid thing %v", t.info.type)
            return
        }

        @(static, rodata) LUT := [Thing_Type](#type proc(fcc: Function_Compile_Context, t: ^Thing) -> (temp: u8)){
            .Num    = compile_num,
            .String = compile_string,
            .Cons   = compile_cons,
            .Symbol = compile_symbol,

            .Function = compile_invalid,
            .Macro    = compile_invalid,
            .Builtin  = compile_invalid,
            .Env      = compile_invalid,

            .Nil = compile_nil,
            .T   = compile_t,

            .Constant_String = compile_invalid,
            .Constant_Symbol = compile_invalid,
            .Dead            = compile_invalid,
        }

        return #must_tail LUT[t.info.type](fcc, t)
    }

    if obj.args == c.ctx.nil_ || obj.args.info.type != .Cons {
        compile_error(c, "missing function params for %q", obj.symbol.symbol)
        return
    }

    params := obj.args.cons.car
    args   := obj.args.cons.cdr

    if args == c.ctx.nil_ || args.info.type != .Cons {
        compile_error(c, "missing function body for %q", obj.symbol.symbol)
        return
    }

    result := compile_thing(fcc, args.cons.car)
    fcc_push_instruction(fcc, .Ret, result)

    alloced_instructions := make([]Instruction, xar.len(instructions), virtual.arena_allocator(&pkg.arena))
    alloced_constants    := make([]Thing, xar.len(constants), virtual.arena_allocator(&pkg.arena))

    for iter := xar.iterator(&instructions); instruction, i in xar.iterate_by_val(&iter) {
        alloced_instructions[i] = instruction
    }

    for iter := xar.iterator(&constants); constant, i in xar.iterate_by_val(&iter) {
        alloced_constants[i] = constant
    }

    obj.type = .Function
    obj.chunk = {
        stack_size   = stack_size,
        instructions = alloced_instructions,
        constants    = alloced_constants,
    }
}
