; =============================================================================
; kernel_entry.asm - 32-bit bridge from Stage 2 into the C kernel
;
; Placed first in kernel.bin (section .text.entry, see linker.ld) so that
; Stage 2's jump to 0x10000 lands on _start.
; =============================================================================

[BITS 32]

[extern main]
[extern __bss_start]
[extern __bss_end]

global _start

section .text.entry progbits alloc exec nowrite align=16
_start:
    ; .bss is not stored in the flat binary - zero it before C runs
    cld
    mov edi, __bss_start
    mov ecx, __bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb

    call main

.hang:                              ; main must never "return into nothing"
    cli
    hlt
    jmp .hang
