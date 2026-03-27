package lispi

import "core:os"
import "core:strings"
import "core:log"
import "base:runtime"
import "core:mem/virtual"

GC_DEBUG :: #config(LISPI_GC_DEBUG, ODIN_DEBUG)

fatalf :: proc(fmt: string, args: ..any) -> ! {
    log.fatalf(fmt, ..args)
    os.exit(1)
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

    ctx_init_builtins(ctx, root)
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
