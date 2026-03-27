package lispi


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
    eval_self :: proc (ctx: ^Context, root: ^Root, env, code: ^Thing) -> ^Thing {
        return code
    }

    eval_error :: proc (ctx: ^Context, root: ^Root, env, code: ^Thing) -> ^Thing {
        fatalf("eval: Invalid thing type: %v", code.info.type)
    }

    eval_cons :: proc (ctx: ^Context, root: ^Root, env, code: ^Thing) -> ^Thing {
        root := root
        temp := temp_allocator_get({})
        expanded, fn, args: ^Thing
        evaluated_args, new_env: ^Thing
        root = root_new(temp, root, &expanded, &fn, &args, &evaluated_args, &new_env)

        expanded = macro_expand(ctx, root, env, code)
        if expanded != code {
            temp_allocator_end(temp.tmp, temp.loc)
            return #must_tail eval(ctx, root, env, expanded)
        }

        fn   = eval(ctx, root, env, expanded.cons.car)
        args = expanded.cons.cdr
        if fn.info.type != .Builtin && fn.info.type != .Function {
            fatalf("eval: Expected function to call, got %v", fn.info.type)
        }

        if fn.info.type == .Builtin {
            return fn.builtin(ctx, root, env, args)
        }

        evaluated_args = eval_list(ctx, root, env, args)
        new_env        = env_from_lists(ctx, root, fn.function.env, fn.function.params, evaluated_args)

        temp_allocator_end(temp.tmp, temp.loc)
        return progn(ctx, root, new_env, fn.function.code)
    }

    eval_symbol :: proc(ctx: ^Context, root: ^Root, env, code: ^Thing) -> ^Thing {
        t := env_find(ctx, env, code)
        if t == nil {
            fatalf("eval: Could not find symbol: %s", code.symbol)
        }
        return t
    }

    @(static, rodata) LUT := [Thing_Type](#type proc(ctx: ^Context, root: ^Root, env, code: ^Thing) -> ^Thing){
        .Num = eval_self,
        .String = eval_self,
        .Nil = eval_self,
        .T = eval_self,
        .Function = eval_self,
        .Builtin = eval_self,
        .Cons = eval_cons,
        .Symbol = eval_symbol,
        .Dead = eval_error,
        .Env = eval_error,
        .Macro = eval_error,
    }

    return #must_tail LUT[code.info.type](ctx, root, env, code)
}

