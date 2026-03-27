package lispi

Object_Type :: enum {
    Invalid,
    Package,
    Function,
    Macro,
    Define,
}

Object :: struct {
    type:   Object_Type,
    symbol: ^Thing,
    thing:  ^Thing,
}

Compiler :: struct {
    ctx:    ^Context,
    source: ^Thing,
}
