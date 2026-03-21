// Small lisp implementation to learn lisp
// Example (+ 1 2)

#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdnoreturn.h>
#include <string.h>

#define cast(T) (T)
#define zero(v) memset((v), 0, sizeof(*(v)))

typedef uint8_t   u8;
typedef int32_t   i32;
typedef i32       b32;
typedef size_t    isize;
typedef ptrdiff_t usize;
typedef uintptr_t uintptr;

#define false 0
#define true 1

typedef struct String {
    u8 const *data;
    isize     len;
} String;

#define STR(...) (String){ .data = cast(u8 const*)(__VA_ARGS__), .len = sizeof(__VA_ARGS__)-1 }

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

typedef struct Arena_Block {
    struct Arena_Block *next;
    void               *memory;
    usize              cap;
    usize              len;
} Arena_Block;

noreturn void fatalf(char const *format, ...) {
    va_list list;
    va_start(list, format);

    vfprintf(stderr, format, list);

    va_end(list);
    exit(1);
}

#define ALIGNMENT_PADDING(value, alignment) ((alignment) - ((value) & ((alignment) - 1))) & ((alignment) - 1)

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

typedef struct Arena {
    Arena_Block *first;
    Arena_Block *current;
    usize       default_mem_block_size;
    usize       len;
} Arena;

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

void arena_reset_to(Arena *arena, usize pos) {
    Arena_Block *block = arena->current;

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

    Arena_Block *current_block = block->next;
    block->next                = NULL;
    Arena_Block *next_block    = current_block ? current_block->next : NULL;
    while (current_block) {
        free(current_block->memory);
        if (!next_block) {
            break;
        }

        current_block = next_block;
        next_block    = next_block->next;
    }
}

typedef struct Arena_Temp {
    Arena *arena;
    usize pos;
} Arena_Temp;

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

void free_wrapper(void *data) {
    free(*(cast(void**)data));
}

#define ARENA_TEMP_GUARD(temp, arena) __attribute__((cleanup(arena_temp_cleanup))) Arena_Temp temp = arena_get_temp(arena);
#define TEMP_ARENA_COUNT 2
__thread Arena temp_arenas[TEMP_ARENA_COUNT];

Arena *temp_arena_get(Arena **collisions, isize collision_count) {
    for (isize i = 0; i < TEMP_ARENA_COUNT; i++) {
        for (isize j = 0; j < collision_count; j++) {
            if (collisions[j] != &temp_arenas[i]) {
                return &temp_arenas[i];
            }
        }
    }

    fatalf("Could not find temp arena.\n");
    return NULL;
}
#define TEMP_ARENA_VAR(temp, ...) ARENA_TEMP_GUARD(temp, temp_arena_get((Arena*[]){ __VA_ARGS__ }, sizeof(((Arena*[]){ __VA_ARGS__ })) / sizeof(((Arena*[]){ __VA_ARGS__ })[0])))
#define TEMP_ARENA(...) TEMP_ARENA_VAR(temp, __VA_ARGS__)

typedef struct Context {
    Arena        symbol_strings;
    Arena        things;
    struct Thing *symbols; // list of symbols, should probably be turned into a hash map at some point
    struct Thing *env;
    struct Thing *dead_things;

    struct Thing *nil;
} Context;

typedef struct Thing *(*Builtin)(Context *ctx, struct Thing *env, struct Thing *args);

typedef enum Thing_Type {
    THING_NUM,
    THING_CONS,
    THING_SYMBOL,
    THING_FUNCTION,
    THING_BUILTIN,
    THING_ENV,

    THING_NIL,

    // Unused and free to use
    THING_DEAD,
} Thing_Type;

typedef struct Thing {
    Thing_Type type;
    union {
        i32 num;
        struct {
            struct Thing *car;
            struct Thing *cdr;
        } cons;
        String symbol;
        struct {
            struct Thing *params;
            struct Thing *code;
            struct Thing *env;
        } function;
        Builtin builtin;
        struct {
            struct Thing *parent;
            struct Thing *vars;
        } env;
        struct Thing *next_dead;
    };
} Thing;

Thing *thing_new(Context *ctx, Thing_Type type) {
    if (ctx->dead_things) {
        Thing *new_thing = ctx->dead_things;
        ctx->dead_things = ctx->dead_things->next_dead;
        zero(new_thing);
        new_thing->type = type;
        return new_thing;
    }

    Thing *thing = arena_alloc_align(&ctx->things, sizeof(Thing), sizeof(struct Thing *));
    thing->type = type;
    return thing;
}

Thing *thing_num(Context *ctx, i32 num) {
    Thing *thing = thing_new(ctx, THING_NUM);
    thing->num = num;
    return thing;
}

Thing *thing_cons(Context *ctx, Thing *car, Thing *cdr) {
    Thing *thing = thing_new(ctx, THING_CONS);
    thing->cons.car = car;
    thing->cons.cdr = cdr;
    return thing;
}

Thing *thing_symbol(Context *ctx, String name) {
    Thing *thing       = thing_new(ctx, THING_SYMBOL);
    thing->symbol.data = arena_alloc_align(&ctx->symbol_strings, name.len, 1);
    thing->symbol.len  = name.len;
    memcpy((u8*)thing->symbol.data, name.data, name.len);
    return thing;
}

Thing *thing_symbol_intern(Context *ctx, String name) {
    for (Thing *sym_cons = ctx->symbols; sym_cons != ctx->nil; sym_cons = sym_cons->cons.cdr) {
        Thing *sym = sym_cons->cons.car;
        if (string_eq(name, sym->symbol)) {
            return sym;
        }
    }

    Thing *sym = thing_symbol(ctx, name);
    ctx->symbols = thing_cons(ctx, sym, ctx->symbols);
    return sym;
}

Thing *thing_function(Context *ctx, Thing *params, Thing *code, Thing *env) {
    Thing *thing           = thing_new(ctx, THING_FUNCTION);
    thing->function.params = params;
    thing->function.code   = code;
    thing->function.env    = env;
    return thing;
}

Thing *thing_builtin(Context *ctx, Builtin builtin) {
    Thing *thing   = thing_new(ctx, THING_BUILTIN);
    thing->builtin = builtin;
    return thing;
}

Thing *thing_env(Context *ctx, Thing *parent, Thing *vars) {
    Thing *thing      = thing_new(ctx, THING_ENV);
    thing->env.parent = parent;
    thing->env.vars   = vars;
    return thing;
}

void thing_kill(Context *ctx, Thing *thing) {
    thing->type      = THING_DEAD;
    thing->next_dead = ctx->dead_things;
    ctx->dead_things = thing;
}

void print(Thing *t) {
    switch (t->type) {
    case THING_NUM:
        printf("%d", t->num);
        break;
    case THING_CONS:
        printf("(");
        print(t->cons.car);
        printf(" . ");
        print(t->cons.cdr);
        printf(")");
        break;
    case THING_SYMBOL:
        printf(":%.*s", (int)t->symbol.len, t->symbol.data);
        break;
    case THING_NIL:
        printf("nil");
        break;
    case THING_DEAD:
        printf("<dead>");
        break;
    case THING_FUNCTION:
        printf("fn <");
        print(t->function.env);
        printf("> (");
        print(t->function.params);
        printf(")");
        print(t->function.code);
        break;
    case THING_BUILTIN:
        printf("<builtin>");
        break;
    case THING_ENV:
        printf("env ^ ");
        print(t->env.parent);
        printf(" -> ");
        print(t->env.vars);
        break;
    }
}

// Parser

typedef enum Token_Type {
    TOKEN_INVALID,
    TOKEN_EOF,
    TOKEN_POPEN,
    TOKEN_PCLOSE,
    TOKEN_IDENTIFIER,
    TOKEN_SYMBOL,
    TOKEN_NUM,
} Token_Type;

typedef struct Token {
    Token_Type type;
    isize      pos;
    isize      len;
} Token;

typedef struct Parser {
    Context *ctx;
    String  input;

    isize ch_pos;
    u8    ch;

    Arena tokens;
    Token *current_token;
    Token *peek_token;
} Parser;

Token *parser_clone_token(Parser *parser, Token token) {
    Token *cloned = arena_alloc_align(&parser->tokens, sizeof(Token), sizeof(usize));
    *cloned = token;
    return cloned;
}

void parser_read_ch(Parser *parser) {
    if (parser->ch_pos < parser->input.len) {
        parser->ch     =  parser->input.data[parser->ch_pos];
        parser->ch_pos += 1;
    } else {
        parser->ch = 0;
    }
}

u8 parser_peek_ch(Parser *parser) {
    if (parser->ch_pos < parser->input.len) {
        return parser->input.data[parser->ch_pos];
    }
    return 0;
}

b32 is_whitespace_ch(u8 ch) {
    return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
}

b32 is_reserved_ch(u8 ch) {
    return ch == '(' || ch == ')' || ch == ':';
}

b32 is_digit(u8 ch) {
    return '0' <= ch && ch <= '9';
}

void parser_skip_whitespace(Parser *parser) {
    while (is_whitespace_ch(parser->ch)) {
        parser_read_ch(parser);
    }
}

Token *parser_read_symbol(Parser *parser) {
    Token t = { .type = TOKEN_SYMBOL, .pos = parser->ch_pos - 1 };

    parser_read_ch(parser); // skip ':'

    if(is_digit(parser->ch)) {
        fatalf("Symbols starting with digits are invalid.");
    }

    while (!is_reserved_ch(parser->ch) && !is_whitespace_ch(parser->ch)) {
        parser_read_ch(parser);
    }

    t.len = parser->ch_pos - 1 - t.pos;

    return parser_clone_token(parser, t);
}

Token *parser_read_identifier(Parser *parser) {
    Token t = { .type = TOKEN_IDENTIFIER, .pos = parser->ch_pos - 1 };

    while (!is_reserved_ch(parser->ch) && !is_whitespace_ch(parser->ch)) {
        parser_read_ch(parser);
    }

    t.len = parser->ch_pos - 1 - t.pos;

    return parser_clone_token(parser, t);
}

Token *parser_read_num(Parser *parser) {
    Token t = { .type = TOKEN_NUM, .pos = parser->ch_pos - 1 };

    while (is_digit(parser->ch)) {
        parser_read_ch(parser);
    }

    t.len = parser->ch_pos - 1 - t.pos;

    return parser_clone_token(parser, t);
}

Token *parser_read_token(Parser *parser) {
    parser_skip_whitespace(parser);
    Token t = { .pos = parser->ch_pos - 1, .len = 1 };

    switch (parser->ch) {
    case 0:   t.type = TOKEN_EOF; break;
    case '(': t.type = TOKEN_POPEN; break;
    case ')': t.type = TOKEN_PCLOSE; break;
    case ':': {
        return parser_read_symbol(parser);
    }
    default: {
        if (is_digit(parser->ch)) {
            return parser_read_num(parser);
        }
        return parser_read_identifier(parser);
    }
    }

    parser_read_ch(parser);
    return parser_clone_token(parser, t);
}

void parser_next_token(Parser *parser) {
    parser->current_token = parser->peek_token;
    parser->peek_token = parser_read_token(parser);
}

void parser_init(Parser *parser, Context *ctx, String input) {
    parser->ctx   = ctx;
    parser->input = input;
    parser_read_ch(parser);
    parser_next_token(parser);
    parser_next_token(parser);
}

Thing *parser_read(Parser *parser) {
    Thing *simple = NULL;

    switch (parser->current_token->type) {
    case TOKEN_INVALID:
        fatalf("Invalid token");
    case TOKEN_EOF:
        fatalf("Unexpected EOF");
    case TOKEN_POPEN: {
        // start list
        Thing *head = NULL;
        Thing *current = NULL;
        parser_next_token(parser);
        while (parser->current_token->type != TOKEN_PCLOSE) {
            Thing *t = parser_read(parser);
            if (!head) {
                head = current = thing_cons(parser->ctx, t, parser->ctx->nil);
            } else {
                current = current->cons.cdr = thing_cons(parser->ctx, t, parser->ctx->nil);
            }
        }
        parser_next_token(parser);
        return head;
    }
    case TOKEN_PCLOSE:
        fatalf("Unexpected ')'");
    case TOKEN_IDENTIFIER:
        simple = thing_symbol_intern(parser->ctx,
                (String){ .data = parser->input.data + parser->current_token->pos,
                .len = parser->current_token->len });
        break;
    case TOKEN_SYMBOL:
        simple = thing_symbol_intern(parser->ctx,
                (String){ .data = parser->input.data + parser->current_token->pos + 1,
                .len = parser->current_token->len - 1 });
        break;
    case TOKEN_NUM: {
        i32 value = 0;
        for (isize i = 0; i < parser->current_token->len; i++) {
            u8 digit = parser->input.data[parser->current_token->pos+i];
            value += cast(i32)(digit - '0');
        }

        simple = thing_num(parser->ctx, value);
        break;
    default:
        fatalf("BUG: Unhandled token %d", parser->current_token->type);
    }
    }

    parser_next_token(parser);

    return simple;
}

// Eval

b32 is_list(Context *ctx, Thing *t) {
    return t == ctx->nil || t->type == THING_CONS;
}

Thing *eval(Context *ctx, Thing *env, Thing *code);

Thing *env_find(Context *ctx, Thing *env, Thing *sym) {
    for (Thing *key_value = env->env.vars; key_value != ctx->nil; key_value = key_value->cons.cdr) {
        Thing *key_value_cons = key_value->cons.car;
        Thing *key            = key_value_cons->cons.car;
        Thing *value          = key_value_cons->cons.cdr;

        if (key == sym) {
            return value;
        }
    }

    if (env->env.parent == ctx->nil) {
        fatalf("Could not find sym %.*s in environment", sym->symbol.len, sym->symbol.data);
    } else {
        return env_find(ctx, env->env.parent, sym);
    }
}

Thing *env_from_lists(Context *ctx, Thing *env, Thing *keys, Thing *values) {
    Thing *vars = ctx->nil;

    Thing *k = keys, *v = values;
    for (; k != ctx->nil && v != ctx->nil; k = k->cons.cdr, v = v->cons.cdr) {
        vars = thing_cons(ctx, thing_cons(ctx, k->cons.car, v->cons.car), vars);
    }

    if (k != ctx->nil || v != ctx->nil) {
        fatalf("apply: Mismatch in length for keys and values");
    }

    return thing_env(ctx, env, vars);
}

void env_add_builtin(Context *ctx, Thing *env, String name, Builtin builtin) {
    env->env.vars = thing_cons(ctx, thing_cons(ctx, thing_symbol_intern(ctx, name), thing_builtin(ctx, builtin)), env->env.vars);
}

void env_add_variable(Context *ctx, Thing *env, Thing *key, Thing *value) {
    env->env.vars = thing_cons(ctx, thing_cons(ctx, key, value), env->env.vars);
}

Thing *eval_list(Context *ctx, Thing *env, Thing *list) {
    Thing *head    = NULL;
    Thing *current = NULL;

    for (Thing *element = list; element != ctx->nil; element = element->cons.cdr) {
        Thing *t = eval(ctx, env, element->cons.car);
        if (head == NULL) {
            current = head = thing_cons(ctx, t, ctx->nil);
        } else {
            current = current->cons.cdr = thing_cons(ctx, t, ctx->nil);
        }
    }

    return head;
}

Thing *apply(Context *ctx, Thing *env, Thing *fn, Thing *args) {
    if (!is_list(ctx, args)) {
        fatalf("apply: args must be a list");
    }
    if (fn->type == THING_BUILTIN) {
        return fn->builtin(ctx, env, args);
    }

    Thing *evaluated_args = eval_list(ctx, env, args);
    Thing *new_env = env_from_lists(ctx, fn->function.env, fn->function.params, evaluated_args);
    return eval(ctx, new_env, fn->function.code);
}

Thing *eval(Context *ctx, Thing *env, Thing *code) {
    switch (code->type) {
    case THING_NUM:
    case THING_NIL:
    case THING_FUNCTION:
    case THING_BUILTIN:
        return code;

    case THING_CONS: {
        Thing *fn = eval(ctx, env, code->cons.car);
        Thing *args = code->cons.cdr;
        if (fn->type != THING_BUILTIN && fn->type != THING_FUNCTION) {
            fatalf("Expected function to call, got %d", fn->type);
        }
        return apply(ctx, env, fn, args);
    }
    case THING_SYMBOL:
        return env_find(ctx, env, code);
    default:
        fatalf("Invalid thing type in eval: %d", code->type);
        break;
    }
}

// Builtins

typedef enum Math_Operator {
    MATH_OP_ADD,
    MATH_OP_SUB,
    MATH_OP_MUL,
    MATH_OP_DIV,
} Math_Operator;

Thing *handle_math(Context *ctx, Thing *env, Thing *args, Math_Operator op) {
    cast(void)env;
    i32 result = 0;

    Thing *evaluated_args = eval_list(ctx, env, args);

#define HANDLE_MATH_FOR_EACH(op) \
    for (Thing *num_cons = evaluated_args; num_cons != ctx->nil; num_cons = num_cons->cons.cdr) { \
        Thing *num = num_cons->cons.car; \
        if (num->type != THING_NUM) { \
            fatalf("Invalid argument to '+' of type %d", num->type); \
        } \
        result op##= num->num;\
    }

    switch (op) {
    case MATH_OP_ADD:
        HANDLE_MATH_FOR_EACH(+);
        break;
    case MATH_OP_SUB:
        HANDLE_MATH_FOR_EACH(-);
        break;
    case MATH_OP_MUL:
        HANDLE_MATH_FOR_EACH(*);
        break;
    case MATH_OP_DIV:
        HANDLE_MATH_FOR_EACH(/);
        break;
    }
#undef HANDLE_MATH_FOR_EACH

    return thing_num(ctx, result);
}

Thing *builtin_add(Context *ctx, Thing *env, Thing *args) {
    return handle_math(ctx, env, args, MATH_OP_ADD);
}

Thing *builtin_sub(Context *ctx, Thing *env, Thing *args) {
    return handle_math(ctx, env, args, MATH_OP_SUB);
}

Thing *builtin_mul(Context *ctx, Thing *env, Thing *args) {
    return handle_math(ctx, env, args, MATH_OP_MUL);
}

Thing *builtin_div(Context *ctx, Thing *env, Thing *args) {
    return handle_math(ctx, env, args, MATH_OP_DIV);
}

Thing *builtin_deffun(Context *ctx, Thing *env, Thing *args) {
    Thing *fn_sym  = args->cons.car;
    Thing *fn_args = args->cons.cdr;

    if (fn_sym->type != THING_SYMBOL) {
        fatalf("deffun: Required symbol as first argument");
    }

    if (fn_args->type != THING_CONS || !is_list(ctx, fn_args->cons.car)) {
        fatalf("deffun: Parameter list must be a list");
    }

    if (fn_args->cons.cdr->type != THING_CONS) {
        fatalf("deffun: Body must be a list");
    }

    // Validate params
    for (Thing *param = fn_args->cons.car; param != ctx->nil; param = param->cons.cdr) {
        if (param->cons.car->type != THING_SYMBOL) {
            fatalf("deffun: Parameter must be a symbol");
        }

        if (!is_list(ctx, param->cons.cdr)) {
            fatalf("deffun: Parameter must be a flat list");
        }
    }

    Thing *fn = thing_function(ctx, fn_args->cons.car, fn_args->cons.cdr, env);
    env_add_variable(ctx, env, fn_sym, fn);
    return fn;
}

void ctx_init(Context *ctx) {
    ctx->nil           = thing_new(ctx, THING_NIL);
    ctx->symbols       = ctx->nil;
    ctx->env           = thing_env(ctx, ctx->nil, ctx->nil);

    env_add_builtin(ctx, ctx->env, STR("+"), builtin_add);
    env_add_builtin(ctx, ctx->env, STR("-"), builtin_sub);
    env_add_builtin(ctx, ctx->env, STR("*"), builtin_mul);
    env_add_builtin(ctx, ctx->env, STR("/"), builtin_div);
    env_add_builtin(ctx, ctx->env, STR("deffun"), builtin_deffun);
}

int main(void) {
    Context ctx = { 0 };
    ctx_init(&ctx);

    Parser parser = { 0 };
    parser_init(&parser, &ctx, STR("(+ 3 (* 3 3 ) )"));
    print(eval(&ctx, ctx.env, parser_read(&parser)));

    // print(thing_cons(&ctx, thing_num(&ctx, 23), thing_cons(&ctx, thing_symbol(&ctx, STR("test")), ctx.nil)));
    //
    // print(thing_function(&ctx, thing_cons(&ctx, thing_symbol(&ctx, STR("test")), ctx.nil), thing_cons(&ctx, thing_symbol(&ctx, STR("test")), ctx.nil), ctx.nil));
}
