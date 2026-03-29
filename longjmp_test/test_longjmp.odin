package test

import "core:fmt"
import "core:c/libc"

j: libc.jmp_buf

test :: proc() {
    fmt.println("Yoooo")
    defer fmt.println("Noooo")
    test2()
}

test2 :: proc() {
    libc.longjmp(&j, 69)
}

main :: proc() {
    ret := i32(libc.setjmp(&j))
    fmt.println(ret)
    if ret == 0 {
        test()
    }
}
