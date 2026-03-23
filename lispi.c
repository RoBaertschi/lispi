// Small lisp implementation to learn lisp
// Example (+ 1 2)

#include "core.c"
#include "core.h"
#include "os_linux.c"

// Symbol Map

u32 hash(String s) {
    u32 hash = 2166136261u;
    for (isize i = 0; i < s.len; i++) {
        hash ^= s.data[i];
        hash *= 16777619u;
    }
    return hash;
}

typedef struct Symbol {
    struct Thing *thing;
} Symbol;

typedef struct Symbol_Map {
    struct Symbol_Map *child[4];
    String            key;
    Symbol            value;
} Symbol_Map;

Symbol *symbol_map_upsert(Symbol_Map **m, String key, Arena *arena) {
    for (u32 h = hash(key); *m; h <<= 2) {
        if (string_eq(key, (*m)->key)) {
            return &(*m)->value;
        }
        m = &(*m)->child[h>>30];
    }
    if (!arena) {
        return NULL;
    }

    *m          = arena_alloc_align(arena, sizeof(Symbol_Map), sizeof(void *));
    (*m)->key   = key;
    return &(*m)->value;
}

Symbol *symbol_map_upsert_free_list(Symbol_Map **m, String key, Symbol_Map **free_list, Arena *arena) {
    for (u32 h = hash(key); *m; h <<= 2) {
        if (string_eq(key, (*m)->key)) {
            return &(*m)->value;
        }
        m = &(*m)->child[h>>30];
    }
    if (!arena) {
        return NULL;
    }

    if (*free_list) {
        *m         = *free_list;
        *free_list = (*free_list)->child[0];
    } else {
        *m = arena_alloc_align(arena, sizeof(Symbol_Map), sizeof(void *));
    }

    (*m)->key = key;
    return &(*m)->value;
}

// Basics

typedef struct Context {
    Arena        things; // NOTE: It is assumed that this arena only contains Thing's and nothing else, do not use it for anything else
    isize        alive_things;
    isize        total_things;
    struct Thing *dead_things;

    Arena        symbols; // NOTE: Contains both the symbol interning table and the environment table
    Symbol_Map   *symbol_map;
    Symbol_Map   *dead_envs;
    struct Thing *env;
    i32          gen_symbol_counter;

    isize gc_things_threshold; // when reached, the gc will be run on the next thing_new

    struct Thing *nil;
    struct Thing *t;
} Context;

struct Root;

typedef struct Thing *(*Builtin)(Context *ctx, struct Root *root, struct Thing *env, struct Thing *args);

typedef enum Thing_Type {
    THING_NUM,
    THING_CONS,
    THING_SYMBOL,
    THING_FUNCTION,
    THING_MACRO,
    THING_BUILTIN,
    THING_ENV,

    THING_NIL,
    THING_T, // evaluates to itself

    // Unused and free to use
    THING_DEAD,
} Thing_Type;

typedef struct Thing {
    Thing_Type type;
    b32        marked; // TODO(robin): merge into bit set, this fills up the padding so no memory actually wasted yet
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
            Symbol_Map   *vars;
        } env;
        struct Thing *next_dead;
    };
} Thing;

// GC - Mark and sweep garbage collector

// Roots
// Roots are a linked list of arrays of things, they are needed for the gc to track which are the actual roots of the program so
// that we can traverse the roots and mark still used things

typedef struct Root {
    struct Root  *parent;
    isize        thing_count;
    struct Thing ***things; // Array of pointers to stack variables, man c syntax is fucking ass
} Root;

#define ROOT_NEW(size) TEMP_ARENA_EMPTY;                                                                            \
    root = &(Root) { .parent = root, .thing_count = (size) };                                                       \
    root->things = arena_alloc_align(temp.arena, sizeof(struct Thing **) * root->thing_count, sizeof(struct Root *))

#define ROOT_VARS1(var1) ROOT_NEW(1);\
    Thing *(var1) = NULL;            \
    root->things[0] = &(var1)

#define ROOT_VARS2(var1, var2) ROOT_NEW(2);\
    Thing *(var1) = NULL;                  \
    root->things[0] = &(var1);             \
    Thing *(var2) = NULL;                  \
    root->things[1] = &(var2)

#define ROOT_VARS3(var1, var2, var3) ROOT_NEW(3);\
    Thing *(var1) = NULL;                        \
    root->things[0] = &(var1);                   \
    Thing *(var2) = NULL;                        \
    root->things[1] = &(var2);                   \
    Thing *(var3) = NULL;                        \
    root->things[2] = &(var3)

#define ROOT_VARS4(var1, var2, var3, var4) ROOT_NEW(4);\
    Thing *(var1) = NULL;                              \
    root->things[0] = &(var1);                         \
    Thing *(var2) = NULL;                              \
    root->things[1] = &(var2);                         \
    Thing *(var3) = NULL;                              \
    root->things[2] = &(var3);                         \
    Thing *(var4) = NULL;                              \
    root->things[3] = &(var4)


void gc_mark_symbol_map(Context *ctx, Symbol_Map *map);

void gc_mark(Context *ctx, Thing *thing) {
    if (!thing || thing->marked /* avoid marking things more than once (avoids circular dependencies to) */) {
        return;
    }

    thing->marked = true;
    switch (thing->type) {
    case THING_NUM:
    case THING_NIL:
    case THING_DEAD:
    case THING_SYMBOL:
    case THING_BUILTIN:
    case THING_T:
        break;
    case THING_CONS:
        gc_mark(ctx, thing->cons.car);
        gc_mark(ctx, thing->cons.cdr);
        break;
    case THING_FUNCTION:
    case THING_MACRO:
        gc_mark(ctx, thing->function.code);
        gc_mark(ctx, thing->function.env);
        gc_mark(ctx, thing->function.params);
        break;
    case THING_ENV:
        gc_mark(ctx, thing->env.parent);
        gc_mark_symbol_map(ctx, thing->env.vars);
        break;
    }
}

void thing_kill(Context *ctx, Thing *thing);

void gc_mark_symbol_map(Context *ctx, Symbol_Map *map) {
    if (map->value.thing) {
        gc_mark(ctx, map->value.thing);
    }

    for (isize i = 0; i < 4; i++) {
        if (map->child[i]) {
            gc_mark_symbol_map(ctx, map->child[i]);
        }
    }
}

isize gc_sweep_symbol_map(Context *ctx, Symbol_Map *map) {
    if (!map) {
        return 0;
    }
    isize count = 0;

    for (isize i = 0; i < 4; i++) {
        if (map->child[i]) {
            count += gc_sweep_symbol_map(ctx, map->child[i]);
        }
    }

    zero(map);
    map->child[0]  = ctx->dead_envs;
    ctx->dead_envs = map;
    return count + 1;
}

void gc(Context *ctx, Root *root) {
    #if GC_DEBUG
    printf("Running gc %zd\n", ctx->gc_things_threshold);
    #endif
    gc_mark(ctx, ctx->env);
    gc_mark(ctx, ctx->nil);
    gc_mark_symbol_map(ctx, ctx->symbol_map);

    for(Root *current_root = root; current_root; current_root = current_root->parent) {
        for (isize i = 0; i < current_root->thing_count; i++) {
            Thing **local_thing = current_root->things[i];
            if (!local_thing || !*local_thing) {
                // TODO(robin): maybe warn?
                continue;
            }
            gc_mark(ctx, *local_thing);
        }
    }

    isize killed = 0;
    isize symbols_maps_killed = 0;

    // sweep
    for (Arena_Block *block = ctx->things.first; block; block = block->next) {
        Thing *things = block->memory;
        isize thing_count = block->len / sizeof(Thing);

        for (isize i = 0; i < thing_count; i++) {
            Thing *thing = &things[i];
            if (thing->marked) {
                goto done;
            }

            switch (thing->type) {
            case THING_DEAD:
                break;
            case THING_ENV:
                // free all symbols
                symbols_maps_killed += gc_sweep_symbol_map(ctx, thing->env.vars);

                goto kill;
            default:
kill:
                killed += 1;
                thing_kill(ctx, thing);
            }

done:
            thing->marked = false;
        }
    }

    #if GC_DEBUG
    printf("GC done, killed %zd things and %zd symbol maps\n", killed, symbols_maps_killed);
    #endif
}

// Alloc functions

Thing *thing_new(Context *ctx, Root *root, Thing_Type type) {
    if (ctx->gc_things_threshold < ctx->alive_things) {
        // run gc
        gc(ctx, root);
        ctx->gc_things_threshold = ctx->alive_things * 2;
    }

    if (ctx->dead_things) {
        Thing *new_thing = ctx->dead_things;
        ctx->dead_things = ctx->dead_things->next_dead;
        zero(new_thing);
        new_thing->type = type;

        ctx->alive_things += 1;
        return new_thing;
    }

    Thing *thing = arena_alloc_align(&ctx->things, sizeof(Thing), sizeof(struct Thing *));
    thing->type = type;

    ctx->alive_things += 1;
    ctx->total_things += 1;
    return thing;
}

Thing *thing_num(Context *ctx, Root *root, i32 num) {
    Thing *thing = thing_new(ctx, root, THING_NUM);
    thing->num = num;
    return thing;
}

Thing *thing_cons(Context *ctx, Root *root, Thing *car, Thing *cdr) {
    Thing *thing = thing_new(ctx, root, THING_CONS);
    thing->cons.car = car;
    thing->cons.cdr = cdr;
    return thing;
}

Thing *thing_symbol(Context *ctx, Root *root, String name) {
    Thing *thing       = thing_new(ctx, root, THING_SYMBOL);
    thing->symbol.data = arena_alloc_align(&ctx->symbols, name.len, 1);
    thing->symbol.len  = name.len;
    memcpy(cast(u8*)thing->symbol.data, name.data, name.len);
    return thing;
}

Thing *thing_symbol_intern(Context *ctx, Root *root, String name) {
    ROOT_VARS1(sym);

    Symbol *symbol = symbol_map_upsert(&ctx->symbol_map, name, &ctx->symbols);
    if (symbol->thing) {
        return symbol->thing;
    }

    symbol->thing = thing_symbol(ctx, root, name);
    return symbol->thing;
}

Thing *thing_function(Context *ctx, Root *root, Thing *params, Thing *code, Thing *env, Thing_Type type) {
    assert(type == THING_FUNCTION || type == THING_MACRO);

    Thing *thing           = thing_new(ctx, root, type);
    thing->function.params = params;
    thing->function.code   = code;
    thing->function.env    = env;
    return thing;
}

Thing *thing_builtin(Context *ctx, Root *root, Builtin builtin) {
    Thing *thing   = thing_new(ctx, root, THING_BUILTIN);
    thing->builtin = builtin;
    return thing;
}

Thing *thing_env(Context *ctx, Root *root, Thing *parent, Symbol_Map *vars) {
    Thing *thing      = thing_new(ctx, root, THING_ENV);
    thing->env.parent = parent;
    thing->env.vars   = vars;
    return thing;
}

void thing_kill(Context *ctx, Thing *thing) {
    thing->type        =  THING_DEAD;
    thing->next_dead   =  ctx->dead_things;
    ctx->dead_things   =  thing;
    ctx->alive_things -= 1;
}

Thing *thing_acons(Context *ctx, Root *root, Thing *x, Thing *y, Thing *a) {
    ROOT_VARS1(cell);
    cell = thing_cons(ctx, root, x, y);
    return thing_cons(ctx, root, cell, a);
}

Thing *thing_append(Context *ctx, Root *root, Thing *a, Thing *b) {
    if (a == ctx->nil) {
        return b;
    }

    if (a->type != THING_CONS) {
        return thing_cons(ctx, root, a, b);
    }

    ROOT_VARS2(new_car, new_cdr);
    new_car = a->cons.car;
    new_cdr = thing_append(ctx, root, a->cons.cdr, b);

    return thing_cons(ctx, root, new_car, new_cdr);
}

// Printer

void print(Context *ctx, Thing *t) {
    switch (t->type) {
    case THING_NUM:
        printf("%d", t->num);
        break;
    case THING_CONS:
        printf("(");
        Thing *current = t;
        for (; current->type == THING_CONS; current = current->cons.cdr) {
            if (current != t) {
                printf(" ");
            }
            print(ctx, current->cons.car);
        }

        if (current != ctx->nil) {
            printf(" . ");
            print(ctx, t->cons.cdr);
        }

        printf(")");
        break;
    case THING_SYMBOL:
        printf(":%.*s", (int)t->symbol.len, t->symbol.data);
        break;
    case THING_NIL:
        printf("nil");
        break;
    case THING_T:
        printf("t");
        break;
    case THING_DEAD:
        printf("<dead>");
        break;
    case THING_FUNCTION:
        printf("<function>");
        break;
    case THING_MACRO:
        printf("<macro>");
        break;
    case THING_BUILTIN:
        printf("<builtin>");
        break;
    case THING_ENV:
        printf("<env>");
        break;
    }
}

// Parser

typedef enum Token_Type {
    TOKEN_INVALID,
    TOKEN_EOF,
    TOKEN_POPEN,
    TOKEN_PCLOSE,
    TOKEN_DOT,
    TOKEN_QUOTE,
    TOKEN_BACKTICK,
    TOKEN_COMMA,
    TOKEN_COMMA_AT,

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
    } else {
        parser->ch = 0;
    }
    parser->ch_pos += 1;
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
    return ch == '(' || ch == ')' || ch == ':' || ch == '.' || ch == '\'' || ch == '`' || ch == ',' || ch == '@';
}

b32 is_digit(u8 ch) {
    return '0' <= ch && ch <= '9';
}

void parser_skip_whitespace(Parser *parser) {
    while (is_whitespace_ch(parser->ch)) {
        parser_read_ch(parser);
    }
}

Token *parser_read_identifier(Parser *parser) {
    Token t = { .type = TOKEN_SYMBOL, .pos = parser->ch_pos - 1 };

    while (!is_reserved_ch(parser->ch) && !is_whitespace_ch(parser->ch) && parser->ch != 0) {
        parser_read_ch(parser);
    }

    t.len = parser->ch_pos - 1 - t.pos;

    return parser_clone_token(parser, t);
}

Token *parser_read_num(Parser *parser) {
    Token t = { .type = TOKEN_NUM, .pos = parser->ch_pos - 1 };

    if (parser->ch == '-') {
        parser_read_ch(parser);
    }

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
    case 0:    t.type = TOKEN_EOF;      break;
    case '(':  t.type = TOKEN_POPEN;    break;
    case ')':  t.type = TOKEN_PCLOSE;   break;
    case '.':  t.type = TOKEN_DOT;      break;
    case '\'': t.type = TOKEN_QUOTE;    break;
    case '`':  t.type = TOKEN_BACKTICK; break;
    case ',':
        if (parser_peek_ch(parser) == '@') {
            t.type = TOKEN_COMMA_AT;
            t.len  = 2;
            parser_read_ch(parser);
            parser_read_ch(parser);
            return parser_clone_token(parser, t);
        }
        t.type = TOKEN_COMMA;
        break;
    case '-':
        if (is_digit(parser_peek_ch(parser))) {
            return parser_read_num(parser);
        }
        goto skip_num;
    default: {
        if (is_digit(parser->ch)) {
            return parser_read_num(parser);
        }

skip_num:
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

void parser_destroy(Parser *parser) {
    arena_destroy(&parser->tokens);
    zero(parser);
}

Thing *parser_read(Parser *parser, Root *root);

Thing *parser_produce_internal(Parser *parser, Root *root, String symbol) {
    ROOT_VARS2(list, sym);
    parser_next_token(parser);
    sym  = thing_symbol_intern(parser->ctx, root, symbol);
    list = parser_read(parser, root);
    list = thing_cons(parser->ctx, root, list, parser->ctx->nil);
    list = thing_cons(parser->ctx, root, sym, list);
    return list;
}

// Current token is new, ends on next new token
Thing *parser_read(Parser *parser, Root *root) {
    Thing *simple = NULL;

    switch (parser->current_token->type) {
    case TOKEN_INVALID:
        fatalf("Invalid token");
    case TOKEN_EOF:
        fatalf("Unexpected EOF");
    case TOKEN_QUOTE:    return parser_produce_internal(parser, root, STR("quote"));
    case TOKEN_BACKTICK: return parser_produce_internal(parser, root, STR("quasiquote"));
    case TOKEN_COMMA:    return parser_produce_internal(parser, root, STR("unquote"));
    case TOKEN_COMMA_AT: return parser_produce_internal(parser, root, STR("unquote-splicing"));
    case TOKEN_POPEN: {
        // start list
        parser_next_token(parser);

        if (parser->current_token->type == TOKEN_PCLOSE) {
            parser_next_token(parser);
            return parser->ctx->nil;
        }

        ROOT_VARS4(start, head, current, t);

        start = parser_read(parser, root);

        if (parser->current_token->type == TOKEN_DOT) {
            parser_next_token(parser);
            head = parser_read(parser, root);
            if (parser->current_token->type != TOKEN_PCLOSE) {
                fatalf("Expected a ')' after a cons");
            }
            parser_next_token(parser);
            start = thing_cons(parser->ctx, root, start, head);
            return start;
        }

        head = thing_cons(parser->ctx, root, start, parser->ctx->nil);
        current = head;

        while (parser->current_token->type != TOKEN_PCLOSE) {
            t = parser_read(parser, root);
            current = current->cons.cdr = thing_cons(parser->ctx, root, t, parser->ctx->nil);
        }
        parser_next_token(parser);
        return head;
    }
    case TOKEN_PCLOSE:
        fatalf("Unexpected ')'");
    case TOKEN_DOT:
        fatalf("Unexpected '.'");
    case TOKEN_SYMBOL:
        simple = thing_symbol_intern(parser->ctx, root,
                (String){ .data = parser->input.data + parser->current_token->pos,
                .len = parser->current_token->len });
        break;
    case TOKEN_NUM: {
        i32 value = 0;
        b32 neg   = false;

        if (parser->current_token->len > 0 && parser->input.data[parser->current_token->pos] == '-') {
            neg = true;
        }

        for (isize i = neg ? 1 : 0; i < parser->current_token->len; i++) {
            u8 digit = parser->input.data[parser->current_token->pos+i];
            value *= 10;
            value += cast(i32)(digit - '0');
        }

        if (neg) {
            value = -value;
        }

        simple = thing_num(parser->ctx, root, value);
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

isize list_length(Context *ctx, Thing *t) {
    isize len = 0;

    for (;;) {
        if (t == ctx->nil) {
            return len;
        }

        if (t->type != THING_CONS) {
            fatalf("length: Invalid, non-cons, list item");
        }

        t    = t->cons.cdr;
        len += 1;
    }
}

Thing *eval(Context *ctx, Root *root, Thing *env, Thing *code);
Thing *progn(Context *ctx, Root *root, Thing *env, Thing *list);

Thing *env_find(Context *ctx, Thing *env, Thing *sym) {
    for (; env != ctx->nil; env = env->env.parent) {
        Symbol *symbol = symbol_map_upsert(&env->env.vars, sym->symbol, NULL);
        if (symbol) {
            return symbol->thing;
        }
    }

    return NULL;
}

Symbol *env_find_symbol(Context *ctx, Thing *env, Thing *sym) {
    for (; env != ctx->nil; env = env->env.parent) {
        Symbol *symbol = symbol_map_upsert(&env->env.vars, sym->symbol, NULL);
        if (symbol) {
            return symbol;
        }
    }

    return NULL;
}

Symbol *env_find_or_create_symbol(Context *ctx, Thing *env, Thing *sym) {
    for (; env != ctx->nil; env = env->env.parent) {
        Symbol *symbol = symbol_map_upsert_free_list(&env->env.vars, sym->symbol, &ctx->dead_envs, &ctx->symbols);
        if (symbol) {
            return symbol;
        }
    }

    return NULL;
}

Thing *env_from_lists(Context *ctx, Root *root, Thing *env, Thing *keys, Thing *values) {
    ROOT_VARS2(k, v);

    Symbol_Map *vars = NULL;
    k = keys, v = values;

    for (; k != ctx->nil && v != ctx->nil; k = k->cons.cdr, v = v->cons.cdr) {
        Symbol *symbol = symbol_map_upsert_free_list(&vars, k->cons.car->symbol, &ctx->dead_envs, &ctx->symbols);
        symbol->thing = v->cons.car;
    }

    if (k != ctx->nil || v != ctx->nil) {
        printf("k: %d, v: %d", k->type, v->type);
        fatalf("apply: Mismatch in length for keys and values");
    }

    return thing_env(ctx, root, env, vars);
}

void env_add_builtin(Context *ctx, Root *root, Thing *env, String name, Builtin builtin) {
    ROOT_VARS2(sym, builtin_thing);
    sym            = thing_symbol_intern(ctx, root, name);
    builtin_thing  = thing_builtin(ctx, root, builtin);
    Symbol *symbol = symbol_map_upsert_free_list(&env->env.vars, sym->symbol, &ctx->dead_envs, &ctx->symbols);
    symbol->thing  = builtin_thing;
}

void env_add_variable(Context *ctx, Thing *env, Thing *key, Thing *value) {
    Symbol *symbol = symbol_map_upsert_free_list(&env->env.vars, key->symbol, &ctx->dead_envs, &ctx->symbols);
    symbol->thing  = value;
}

Thing *eval_list(Context *ctx, Root *root, Thing *env, Thing *list) {
    ROOT_VARS4(head, current, t, element);

    for (element = list; element != ctx->nil; element = element->cons.cdr) {
        t = eval(ctx, root, env, element->cons.car);
        if (head == NULL) {
            current = head = thing_cons(ctx, root, t, ctx->nil);
        } else {
            current = current->cons.cdr = thing_cons(ctx, root, t, ctx->nil);
        }
    }

    if (!head) {
        head = ctx->nil;
    }

    return head;
}

Thing *apply(Context *ctx, Root *root, Thing *env, Thing *fn, Thing *args) {
    if (!is_list(ctx, args)) {
        fatalf("apply: args must be a list");
    }
    if (fn->type == THING_BUILTIN) {
        return fn->builtin(ctx, root, env, args);
    }

    ROOT_VARS2(evaluated_args, new_env);

    evaluated_args = eval_list(ctx, root, env, args);
    new_env        = env_from_lists(ctx, root, fn->function.env, fn->function.params, evaluated_args);
    return progn(ctx, root, new_env, fn->function.code);
}

Thing *progn(Context *ctx, Root *root, Thing *env, Thing *list) {
    ROOT_VARS1(result);
    for (Thing *element = list; element != ctx->nil; element = element->cons.cdr) {
        result = eval(ctx, root, env, element->cons.car);
    }
    return result;
}

// Tries to apply a macro application
Thing *macro_expand(Context *ctx, Root *root, Thing *env, Thing *t) {
    if (t->type != THING_CONS || t->cons.car->type != THING_SYMBOL) {
        return t;
    }

    Thing *macro = env_find(ctx, env, t->cons.car);
    if (!macro || macro->type != THING_MACRO) {
        return t;
    }

    ROOT_VARS3(args, params, new_env);

    args = t->cons.cdr;
    params = macro->function.params;
    new_env = env_from_lists(ctx, root, env, params, args);
    return progn(ctx, root, new_env, macro->function.code);
}

Thing *eval(Context *ctx, Root *root, Thing *env, Thing *code) {
    switch (code->type) {
    case THING_NUM:
    case THING_NIL:
    case THING_FUNCTION:
    case THING_BUILTIN:
        return code;

    case THING_CONS: {
        ROOT_VARS3(expaneded, fn, args);

        expaneded = macro_expand(ctx, root, env, code);
        if (expaneded != code) {
            return eval(ctx, root, env, expaneded);
        }

        fn   = eval(ctx, root, env, expaneded->cons.car);
        args = expaneded->cons.cdr;
        if (fn->type != THING_BUILTIN && fn->type != THING_FUNCTION) {
            fatalf("Expected function to call, got %d", fn->type);
        }
        return apply(ctx, root, env, fn, args);
    }
    case THING_SYMBOL: {
        Thing *t = env_find(ctx, env, code);
        if (!t) {
            fatalf("Could not find symbol: %.*s", cast(int)code->symbol.len, code->symbol.data);
        }
        return t;
    }
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

Thing *handle_math(Context *ctx, Root *root, Thing *env, Thing *args, Math_Operator op) {
    cast(void)env;

    ROOT_VARS2(evaluated_args, num);

    evaluated_args = eval_list(ctx, root, env, args);
    if (evaluated_args->type != THING_CONS) {
        fatalf("op: one argument is required at least");
    }

    num = evaluated_args->cons.car;
    if (num->type != THING_NUM) {
        fatalf("Invalid argument type to '+' of type %d", num->type);
    }
    i32 result = num->num;
    evaluated_args = evaluated_args->cons.cdr;

#define HANDLE_MATH_FOR_EACH(op)                                                                  \
    for (Thing *num_cons = evaluated_args; num_cons != ctx->nil; num_cons = num_cons->cons.cdr) { \
        Thing *num = num_cons->cons.car;                                                          \
        if (num->type != THING_NUM) {                                                             \
            fatalf("Invalid argument to '+' of type %d", num->type);                              \
        }                                                                                         \
        result op##= num->num;                                                                    \
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

    return thing_num(ctx, root, result);
}

Thing *builtin_add(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_ADD);
}

Thing *builtin_sub(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_SUB);
}

Thing *builtin_mul(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_MUL);
}

Thing *builtin_div(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_math(ctx, root, env, args, MATH_OP_DIV);
}


typedef enum Cmp_Operator {
    CMP_OP_LT,
    CMP_OP_GT,
    CMP_OP_EQ,
} Cmp_Operator;

Thing *handle_cmp(Context *ctx, Root *root, Thing *env, Thing *args, Cmp_Operator op) {
    cast(void)env;

    ROOT_VARS2(evaluated_args, result);

    evaluated_args = eval_list(ctx, root, env, args);
    if (list_length(ctx, evaluated_args) != 2) {
        fatalf("cmp-op: exactly 2 arguments are required");
    }

    if (evaluated_args->cons.car->type != THING_NUM || evaluated_args->cons.cdr->cons.car->type != THING_NUM) {
        fatalf("cmp-op: arguments have to be nums");
    }

    i32 first  = evaluated_args->cons.car->num;
    i32 second = evaluated_args->cons.cdr->cons.car->num;

    switch (op) {
    case CMP_OP_LT: result = first <  second ? ctx->t : ctx->nil; break;
    case CMP_OP_GT: result = first >  second ? ctx->t : ctx->nil; break;
    case CMP_OP_EQ: result = first == second ? ctx->t : ctx->nil; break;
        break;
    }

    return result;
}

Thing *builtin_lt(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_cmp(ctx, root, env, args, CMP_OP_LT);
}

Thing *builtin_gt(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_cmp(ctx, root, env, args, CMP_OP_GT);
}

Thing *builtin_eq(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_cmp(ctx, root, env, args, CMP_OP_EQ);
}

Thing *handle_function(Context *ctx, Root *root, Thing *env, Thing *args, Thing_Type type) {
    if (args->type != THING_CONS || !is_list(ctx, args->cons.car)) {
        fatalf("deffun: Parameter list must be a list");
    }

    if (args->cons.cdr->type != THING_CONS) {
        fatalf("deffun: Body must be a list");
    }

    // Validate params
    Thing *param = args->cons.car;
    for (; param->type == THING_CONS; param = param->cons.cdr) {
        if (param->cons.car->type != THING_SYMBOL) {
            fatalf("lambda: Parameter must be a symbol");
        }

        if (!is_list(ctx, param->cons.cdr)) {
            fatalf("lambda: Parameter must be a flat list");
        }
    }

    if (param != ctx->nil && param->type != THING_SYMBOL) {
        fatalf("lambda: Parameter must be a symbol");
    }

    ROOT_VARS2(params, code);
    params = args->cons.car;
    code = args->cons.cdr;
    return thing_function(ctx, root, params, code, env, type);
}

Thing *builtin_lambda(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_function(ctx, root, env, args, THING_FUNCTION);
}

Thing *handle_deffun(Context *ctx, Root *root, Thing *env, Thing *args, Thing_Type type) {
    ROOT_VARS3(fn_sym, fn_args, fn);
    fn_sym  = args->cons.car;
    fn_args = args->cons.cdr;
    fn      = handle_function(ctx, root, env, fn_args, type);
    env_add_variable(ctx, env, fn_sym, fn);
    return fn;
}

Thing *builtin_deffun(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_deffun(ctx, root, env, args, THING_FUNCTION);
}

Thing *builtin_defmacro(Context *ctx, Root *root, Thing *env, Thing *args) {
    return handle_deffun(ctx, root, env, args, THING_MACRO);
}

Thing *builtin_define(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) != 2 || args->cons.car->type != THING_SYMBOL) {
        fatalf("define: First parameter should be symbol");
    }

    ROOT_VARS2(sym, value);
    sym = args->cons.car;
    value = args->cons.cdr->cons.car;
    value = eval(ctx, root, env, value);
    env_add_variable(ctx, env, sym, value);
    return value;
}

Thing *builtin_progn(Context *ctx, Root *root, Thing *env, Thing *args) {
    return progn(ctx, root, env, args);
}

Thing *builtin_macroexpand(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) != 1) {
        fatalf("Malformed macroexpand");
    }

    return macro_expand(ctx, root, env, args->cons.car);
}

Thing *builtin_quote(Context *ctx, Root *root, Thing *env, Thing *args) {
    cast(void)env;
    cast(void)root;
    if (list_length(ctx, args) != 1) {
        fatalf("quote: Only accept one argument");
    }

    return args->cons.car;
}

Thing *quasiquote_expand(Context *ctx, Root *root, Thing *env, Thing *list) {
    if (list->type != THING_CONS) {
        return list;
    }

    ROOT_VARS4(sym, rest, element, result);
    element = list;
    sym = list->cons.car;
    rest = list->cons.cdr;

    if (sym->type == THING_SYMBOL && string_eq(sym->symbol, STR("unquote"))) {
        return eval(ctx, root, env, rest->cons.car);
    }
    if (sym->type == THING_CONS && sym->cons.car->type == THING_SYMBOL && string_eq(sym->cons.car->symbol, STR("unquote-splicing"))) {
        result = eval(ctx, root, env, sym->cons.cdr->cons.car);
        rest = quasiquote_expand(ctx, root, env, rest);

        return thing_append(ctx, root, result, rest);
    }

    sym = quasiquote_expand(ctx, root, env, sym);
    rest = quasiquote_expand(ctx, root, env, rest);
    return thing_cons(ctx, root, sym, rest);
}

Thing *builtin_quasiquote(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (args == ctx->nil) {
        return ctx->nil;
    }
    return quasiquote_expand(ctx, root, env, args->cons.car);
}

Thing *builtin_cons(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) != 2) {
        fatalf("Malformed cons");
    }
    Thing *cell = eval_list(ctx, root, env, args);
    cell->cons.cdr = cell->cons.cdr->cons.car;
    return cell;
}

Thing *builtin_car(Context *ctx, Root *root, Thing *env, Thing *args) {
    Thing *evaluated_args = eval_list(ctx, root, env, args);
    if (evaluated_args->cons.car->type != THING_CONS || evaluated_args->cons.cdr != ctx->nil) {
        fatalf("Malformed car");
    }
    return args->cons.car->cons.car;
}

Thing *builtin_cdr(Context *ctx, Root *root, Thing *env, Thing *args) {
    Thing *evaluated_args = eval_list(ctx, root, env, args);
    if (evaluated_args->cons.car->type != THING_CONS || evaluated_args->cons.cdr != ctx->nil) {
        fatalf("Malformed cdr");
    }
    return args->cons.car->cons.cdr;
}

Thing *builtin_setq(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) != 2 || args->cons.car->type != THING_SYMBOL) {
        fatalf("Malformed setq");
    }

    ROOT_VARS2(bind, value);
    // TODO(robin): add some way to add symbols directly to the root
    Symbol *bind_symbol = env_find_or_create_symbol(ctx, env, args->cons.car);
    bind = bind_symbol->thing;
    value = args->cons.cdr->cons.car;
    value = eval(ctx, root, env, value);
    bind_symbol->thing = value;
    return value;
}

Thing *builtin_list(Context *ctx, Root *root, Thing *env, Thing *args) {
    ROOT_VARS1(evaluated_args);
    evaluated_args = eval_list(ctx, root, env, args);
    return evaluated_args;
}

Thing *builtin_setcar(Context *ctx, Root *root, Thing *env, Thing *args) {
    ROOT_VARS1(evaluated_args);
    evaluated_args = eval_list(ctx, root, env, args);
    if (list_length(ctx, evaluated_args) != 2 || evaluated_args->cons.car->type != THING_CONS) {
        fatalf("Malformed setcar");
    }
    evaluated_args->cons.car->cons.car = evaluated_args->cons.cdr;
    return evaluated_args->cons.car;
}

Thing *builtin_while(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) < 2) {
        fatalf("Malformed while");
    }

    ROOT_VARS2(cond, exprs);
    cond = args->cons.car;
    while (eval(ctx, root, env, cond) != ctx->nil) {
        exprs = args->cons.cdr;
        eval_list(ctx, root, env, exprs);
    }

    return ctx->nil;
}

Thing *builtin_gensym(Context *ctx, Root *root, Thing *env, Thing *args) {
    cast(void)env;
    cast(void)args;
    char buf[10] = { 0 };
    snprintf(buf, sizeof(buf), "G__%d", ctx->gen_symbol_counter++);
    return thing_symbol(ctx, root, (String) { .data = cast(u8 const*)buf, .len = strlen(buf) });
}

Thing *builtin_print(Context *ctx, Root *root, Thing *env, Thing *args) {
    ROOT_VARS1(evaluated_args);
    evaluated_args = eval_list(ctx, root, env, args);

    for (Thing *tmp = evaluated_args; tmp->type == THING_CONS; tmp = tmp->cons.cdr) {
        print(ctx, tmp->cons.car);
        printf("\n");
    }

    return ctx->nil;
}

Thing *builtin_thing_eq(Context *ctx, Root *root, Thing *env, Thing *args) {
    if (list_length(ctx, args) != 2) {
        fatalf("Malformed eq\n");
    }
    Thing *values = eval_list(ctx, root, env, args);
    return values->cons.car == values->cons.cdr->cons.car ? ctx->t : ctx->nil;
}

Thing *builtin_gc(Context *ctx, Root *root, Thing *env, Thing *args) {
    cast(void)env;
    cast(void)args;
    gc(ctx, root);
    return ctx->nil;
}

void ctx_init(Context *ctx, Root *root) {
    ctx->gc_things_threshold = 32;
    ctx->nil                 = thing_new(ctx, root, THING_NIL);
    ctx->t                   = thing_new(ctx, root, THING_T);
    ctx->env                 = thing_env(ctx, root, ctx->nil, NULL);

    ROOT_VARS1(tmp);
    tmp = thing_symbol_intern(ctx, root, STR("t"));

    env_add_variable(ctx, ctx->env, tmp, ctx->t);

    env_add_builtin(ctx, root, ctx->env, STR("+"), builtin_add);
    env_add_builtin(ctx, root, ctx->env, STR("-"), builtin_sub);
    env_add_builtin(ctx, root, ctx->env, STR("*"), builtin_mul);
    env_add_builtin(ctx, root, ctx->env, STR("/"), builtin_div);
    env_add_builtin(ctx, root, ctx->env, STR("<"), builtin_lt);
    env_add_builtin(ctx, root, ctx->env, STR(">"), builtin_gt);
    env_add_builtin(ctx, root, ctx->env, STR("="), builtin_eq);
    env_add_builtin(ctx, root, ctx->env, STR("lambda"), builtin_lambda);
    env_add_builtin(ctx, root, ctx->env, STR("deffun"), builtin_deffun);
    env_add_builtin(ctx, root, ctx->env, STR("defmacro"), builtin_defmacro);
    env_add_builtin(ctx, root, ctx->env, STR("define"), builtin_define);
    env_add_builtin(ctx, root, ctx->env, STR("progn"), builtin_progn);
    env_add_builtin(ctx, root, ctx->env, STR("macroexpand"), builtin_macroexpand);
    env_add_builtin(ctx, root, ctx->env, STR("quote"), builtin_quote);
    env_add_builtin(ctx, root, ctx->env, STR("quasiquote"), builtin_quasiquote);
    env_add_builtin(ctx, root, ctx->env, STR("cons"), builtin_cons);
    env_add_builtin(ctx, root, ctx->env, STR("car"), builtin_car);
    env_add_builtin(ctx, root, ctx->env, STR("cdr"), builtin_cdr);
    env_add_builtin(ctx, root, ctx->env, STR("list"), builtin_list);
    env_add_builtin(ctx, root, ctx->env, STR("setq"), builtin_setq);
    env_add_builtin(ctx, root, ctx->env, STR("setcar"), builtin_setcar);
    env_add_builtin(ctx, root, ctx->env, STR("while"), builtin_while);
    env_add_builtin(ctx, root, ctx->env, STR("gensym"), builtin_gensym);
    env_add_builtin(ctx, root, ctx->env, STR("print"), builtin_print);
    env_add_builtin(ctx, root, ctx->env, STR("eq"), builtin_thing_eq);
    env_add_builtin(ctx, root, ctx->env, STR("gc"), builtin_gc);
}

void ctx_destroy(Context *ctx) {
    arena_destroy(&ctx->things);
    arena_destroy(&ctx->symbols);
    zero(ctx);
}

String read_entire_file(Arena *arena, char const *file_name) {
    FILE *file = fopen(file_name, "rb");
    if (!file) {
        fatalf("Could not open file %s: %s\n", file_name, strerror(errno));
    }
    fseek(file, 0, SEEK_END);
    isize size = ftell(file);
    fseek(file, 0, SEEK_SET);
    String data = { 0 };
    data.data = arena_alloc_align(arena, size, sizeof(u8));
    data.len  = cast(isize)fread(cast(void*)data.data, sizeof(u8), size, file);
    return data;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fatalf("Missing arguments. Required at least one.\n");
    }
    Arena file_data = {0};
    String data = read_entire_file(&file_data, argv[1]);

    {
        Context ctx = { 0 };

        Root *root = NULL;
        ROOT_VARS1(result);

        ctx_init(&ctx, root);

        Parser parser = { 0 };
        parser_init(&parser, &ctx, data);

        while (parser.current_token->type != TOKEN_EOF) {
            result = parser_read(&parser, root);
            // discard, not needed
            result = eval(&ctx, root, ctx.env, result);
            #if EVAL_DEBUG
            print(&ctx, result);
            printf("\n");
            #endif
        }

        #if GC_DEBUG
        printf("Alive/Total things: %zd/%zd\n", ctx.alive_things, ctx.total_things);
        #endif

        parser_destroy(&parser);
        ctx_destroy(&ctx);
    }

    temp_arenas_destroy();
    arena_destroy(&file_data);
}
