// Apple arm64: place the destination in x8 without copying an opaque C++ object.
// fn, destination, arg0, arg1, arg2, arg3, arg4 -> native function call.
#if defined(__arm64__)
.text
.p2align 2
.globl _wechat_antirecall_native_sret5
_wechat_antirecall_native_sret5:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x16, x0
    mov x8, x1
    mov x0, x2
    mov x1, x3
    mov x2, x4
    mov x3, x5
    mov x4, x6
    blr x16
    ldp x29, x30, [sp], #16
    ret
#endif
