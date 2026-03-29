package lispi

// Parser

import "core:strconv"
import "core:math/bits"

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
    ctx:   ^Compile_Context,
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

parser_init :: proc(parser: ^Parser, ctx: ^Compile_Context, input: string) {
    parser.ctx   = ctx
    parser.input = input
    parser_read_ch(parser)
    parser_next_token(parser)
    parser_next_token(parser)
}

parser_destroy :: proc(parser: ^Parser) {
    parser^ = {}
}

parser_produce_internal :: proc(parser: ^Parser, symbol: string) -> ^Thing {
    parser_next_token(parser)
    sym    := compile_thing_symbol_intern(parser.ctx, symbol)
    list   := parser_read(parser)
    list    = compile_thing_cons(parser.ctx, list, parser.ctx.nil_)
    list    = compile_thing_cons(parser.ctx, sym, list)
    return list
}

parser_unqoute_string :: proc(parser: ^Parser, token: Token) -> ^Thing {
    head, tail: ^String_Block

    largest := String_Block_Size.Small
    for ;string_block_sizes_thresholds[largest] < token.len && largest <= .Huge; largest += String_Block_Size(1) {}

    token_data := parser.input[token.pos:token.pos+token.len]

    for i := 1; i < token.len - 1; i += 1 {
        if head == nil {
            head = string_block_new(&parser.ctx.arena, largest)
            tail = head
        }
        if tail.len >= tail.cap {
            tail.next = string_block_new(&parser.ctx.arena, largest)
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
    return compile_thing_string(parser.ctx, head)
}

parser_read :: proc(parser: ^Parser) -> ^Thing {
    simple: ^Thing

    token_string := parser.input[parser.current_token.pos:parser.current_token.pos + parser.current_token.len]

    switch parser.current_token.type {
    case .Invalid:
        fatalf("Invalid token")
    case .EOF:
        fatalf("Invalid EOF")
    case .String:   return parser_unqoute_string(parser, parser.current_token)
    case .Quote:    return parser_produce_internal(parser, "quote")
    case .Backtick: return parser_produce_internal(parser, "quasiquote")
    case .Comma:    return parser_produce_internal(parser, "unquote")
    case .Comma_At: return parser_produce_internal(parser, "unquote-splicing")
    case .POpen:
        parser_next_token(parser)
        if parser.current_token.type == .PClose {
            parser_next_token(parser)
            return parser.ctx.nil_
        }

        start, head, current, t: ^Thing

        start = parser_read(parser)
        if parser.current_token.type == .Dot {
            parser_next_token(parser)
            head = parser_read(parser)
            if parser.current_token.type != .PClose {
                fatalf("Expected a ')' after a cons")
            }
            parser_next_token(parser)
            start = compile_thing_cons(parser.ctx, start, head)
            return start
        }

        head    = compile_thing_cons(parser.ctx, start, parser.ctx.nil_)
        current = head

        for parser.current_token.type != .PClose {
            t                = parser_read(parser)
            current.cons.cdr = compile_thing_cons(parser.ctx, t, parser.ctx.nil_)
            current          = current.cons.cdr
        }
        parser_next_token(parser)
        return head
    case .PClose, .Dot:
        fatalf("Unexpected '%r'", rune(parser.ch))
    case .Symbol:
        simple = compile_thing_symbol_intern(parser.ctx, token_string)
    case .Num:
        val, ok := strconv.parse_int(token_string)
        if !ok {
            fatalf("Invalid number %q", token_string)
        }

        if  bits.I32_MAX < val || val < bits.I32_MIN {
            fatalf("Number (%d) does not fit into 32-bit number", val)
        }
        simple = compile_thing_num(parser.ctx, i32(val))
    }

    parser_next_token(parser)
    return simple
}
