package lispi

import "core:fmt"

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

ctx_init_builtins :: proc(ctx: ^Context, root: ^Root) {
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
