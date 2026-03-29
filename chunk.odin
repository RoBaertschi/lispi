package lispi

import "core:container/xar"
Opcode :: enum u8 {
    Load_Constant, // register(r), constant(c): register = LOAD_CONSTANT constant
    Load_Global,   // register(r), global(r):   register = LOAD_GLOBAL global
    Load_Upvalue,  // register(r), upvalue(u):  register = LOAD_UPVALUE upvalue
    Load_Nil,      // register(r):              register = LOAD_NIL
    Load_T,        // register(r):              register = LOAD_T

    Move,          // to(r), from(r): to = MOVE from
    Store_Upvalue, // upvalue(u), register(r): upvalue = STORE_UPVALUE register

    Cons,    // result(r), x(r), y(r): result = CONS x, y
    Set_Car, // cons(r), car(r):       cons.car = SET_CAR car
    Set_Cdr, // cons(r), cdr(r):       cons.cdr = SET_CDR cdr

    // Tail_Call, TODO: tail call optimization

    Call, // output(r), fn(r), list(r): output = CALL fn list
    Ret,  // value(r): RET value
}

Instruction :: struct {
    opcode:   Opcode,
    operands: [3]u8,
}

// If is_stack is true, take the actuall value directly from the parents stack
// Else, recurse into the parents upvalue at index
// TODO(robin): find a better way to store is_stack
Upvalue :: struct {
    next:     ^Upvalue,
    index:    int,
    is_stack: bool,
}

Chunk :: struct {
    stack_size:   u8,
    upvalues:     ^Upvalue,
    instructions: []Instruction,
    constants:    []Thing,
}
