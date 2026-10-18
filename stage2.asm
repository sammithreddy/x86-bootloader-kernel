; =============================================================================
; stage2.asm - second stage loader (16-bit real mode -> 32-bit protected mode)
;
; Loaded by Stage 1 at 0x0000:0x8000, entered with DL = boot drive.
;   1. Loads the C kernel (KERNEL_SECTORS sectors from CHS 0/0/6) to 0x10000
;   2. Enables the A20 line (BIOS INT 15h/2401h -> Fast A20 port 0x92 -> 8042)
;   3. Loads a flat GDT and sets CR0.PE
;   4. Far-jumps to 32-bit code, reloads segments, sets ESP = 0x90000
;   5. Writes "Protected Mode Active" to VGA memory and jumps to the kernel
;
; KERNEL_SECTORS is passed in by the build (-DKERNEL_SECTORS=n).
; This file is padded to exactly 2048 bytes (4 sectors).
; =============================================================================

[BITS 16]
[ORG 0x8000]

%ifndef KERNEL_SECTORS
  %error "KERNEL_SECTORS must be defined (nasm -DKERNEL_SECTORS=n)"
%endif
%if KERNEL_SECTORS < 1 || KERNEL_SECTORS > 58
  ; Sectors 6..63 of head 0 are the only ones reachable without crossing a
  ; track boundary (63 sectors per track); a larger kernel needs LBA reads.
  %error "KERNEL_SECTORS must be between 1 and 58"
%endif

KERNEL_LOAD_SEG  equ 0x1000         ; 0x1000:0x0000 = linear 0x10000
KERNEL_LOAD_OFF  equ 0x0000
KERNEL_ADDR      equ 0x10000        ; must match linker.ld
KERNEL_START_CL  equ 0x06           ; 1 (MBR) + 4 (stage2) + 1
MAX_RETRIES      equ 3

CODE_SEG         equ gdt_code - gdt_start   ; 0x08
DATA_SEG         equ gdt_data - gdt_start   ; 0x10

STACK_TOP_32     equ 0x90000
VGA_TEXT         equ 0xB8000
VGA_ATTR_WHITE   equ 0x0F               ; white on black
VGA_ROW_PM       equ 1                  ; row used for the PM message

stage2_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00                  ; reuse Stage 1's stack (below 0x7C00)
    sti
    cld

    mov [BOOT_DRIVE], dl

    mov si, msg_stage2
    call print_string

    call load_kernel
    call enable_a20

    mov si, msg_pm_switch
    call print_string

    ; ---------------- Protected mode switch ----------------
    cli                             ; 1. no interrupts (no IDT in PM yet)
    lgdt [gdt_descriptor]           ; 2. load GDTR
    mov eax, cr0
    or eax, 0x1                     ; 3. CR0.PE = 1
    mov cr0, eax
    jmp CODE_SEG:init_32bit         ; 4. far jump: flush prefetch, CS = 0x08

; -----------------------------------------------------------------------------
; load_kernel - INT 13h/02h read of KERNEL_SECTORS sectors to 0x1000:0x0000
; -----------------------------------------------------------------------------
load_kernel:
    mov byte [retries_left], MAX_RETRIES
.read:
    mov ax, KERNEL_LOAD_SEG
    mov es, ax
    mov bx, KERNEL_LOAD_OFF
    mov ah, 0x02
    mov al, KERNEL_SECTORS
    mov ch, 0x00
    mov cl, KERNEL_START_CL
    mov dh, 0x00
    mov dl, [BOOT_DRIVE]
    int 0x13
    jc .failed
    cmp al, KERNEL_SECTORS
    jne .short_read
    xor ax, ax
    mov es, ax                      ; restore ES = 0
    mov si, msg_kernel_ok
    call print_string
    ret
.short_read:
    mov ah, 0xFF
.failed:
    mov [disk_status], ah
    cmp byte [retries_left], 0
    je .fatal
    dec byte [retries_left]
    xor ah, ah                      ; reset disk system
    mov dl, [BOOT_DRIVE]
    int 0x13
    jmp .read
.fatal:
    xor ax, ax
    mov es, ax
    mov si, msg_kernel_err
    call print_string
    mov al, [disk_status]
    call print_hex8
    jmp halt16

; -----------------------------------------------------------------------------
; enable_a20 - try each method in turn, verifying after each one
; -----------------------------------------------------------------------------
enable_a20:
    call check_a20
    test ax, ax
    jnz .already_on

    ; Method 1: BIOS INT 15h, AX=2401h (enable A20 gate)
    mov ax, 0x2401
    int 0x15
    call check_a20
    test ax, ax
    jnz .bios_ok

    ; Method 2: Fast A20 via System Control Port A (0x92), bit 1.
    ; Bit 0 is "fast reset" - never write it as 1.
    in al, 0x92
    test al, 0x02
    jnz .after_fast
    or al, 0x02
    and al, 0xFE
    out 0x92, al
.after_fast:
    call check_a20
    test ax, ax
    jnz .fast_ok

    ; Method 3: 8042 keyboard controller output port, bit 1
    call a20_kbc
    mov cx, 0xFFFF                  ; the 8042 can be slow to take effect
.kbc_wait:
    call check_a20
    test ax, ax
    jnz .kbc_ok
    loop .kbc_wait

    mov si, msg_a20_fail
    call print_string
    jmp halt16

.already_on:
    mov si, msg_a20_already
    jmp .report
.bios_ok:
    mov si, msg_a20_bios
    jmp .report
.fast_ok:
    mov si, msg_a20_fast
    jmp .report
.kbc_ok:
    mov si, msg_a20_kbc
.report:
    call print_string
    ret

; -----------------------------------------------------------------------------
; check_a20 - returns AX = 1 if A20 is enabled, AX = 0 if memory wraps at 1MB
; Compares 0x0000:0x0500 (linear 0x000500) with 0xFFFF:0x0510 (0x100500).
; -----------------------------------------------------------------------------
check_a20:
    pushf
    push ds
    push es
    push di
    push si
    cli

    xor ax, ax
    mov es, ax
    mov di, 0x0500                  ; ES:DI = 0x000500
    not ax
    mov ds, ax
    mov si, 0x0510                  ; DS:SI = 0x100500

    mov al, [es:di]
    push ax
    mov al, [ds:si]
    push ax

    mov byte [es:di], 0x00
    mov byte [ds:si], 0xFF
    cmp byte [es:di], 0xFF          ; ZF=1 -> wrote through to low memory

    pop ax                          ; restore (mov/pop leave flags intact)
    mov [ds:si], al
    pop ax
    mov [es:di], al

    mov ax, 0
    je .done
    mov ax, 1
.done:
    pop si
    pop di
    pop es
    pop ds
    popf
    ret

; -----------------------------------------------------------------------------
; a20_kbc - enable A20 through the 8042 output port
; -----------------------------------------------------------------------------
a20_kbc:
    cli
    call .wait_in
    mov al, 0xAD                    ; disable keyboard
    out 0x64, al

    call .wait_in
    mov al, 0xD0                    ; read output port
    out 0x64, al

    call .wait_out
    in al, 0x60
    push ax

    call .wait_in
    mov al, 0xD1                    ; write output port
    out 0x64, al

    call .wait_in
    pop ax
    or al, 0x02                     ; A20 bit
    out 0x60, al

    call .wait_in
    mov al, 0xAE                    ; re-enable keyboard
    out 0x64, al

    call .wait_in
    sti
    ret
.wait_in:                           ; wait until input buffer empty
    in al, 0x64
    test al, 0x02
    jnz .wait_in
    ret
.wait_out:                          ; wait until output buffer full
    in al, 0x64
    test al, 0x01
    jz .wait_out
    ret

; -----------------------------------------------------------------------------
; 16-bit helpers
; -----------------------------------------------------------------------------
halt16:
    cli
    hlt
    jmp halt16

print_string:                       ; DS:SI -> NUL-terminated string
    mov ah, 0x0E
    xor bx, bx
.next:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .next
.done:
    ret

print_hex8:                         ; AL -> two hex digits
    mov cl, al
    shr al, 4
    call .nibble
    mov al, cl
    and al, 0x0F
.nibble:
    add al, '0'
    cmp al, '9'
    jbe .out
    add al, 'A' - '9' - 1
.out:
    mov ah, 0x0E
    xor bx, bx
    int 0x10
    ret

; =============================================================================
; 32-bit protected mode
; =============================================================================
[BITS 32]
init_32bit:
    mov ax, DATA_SEG                ; 0x10
    mov ds, ax
    mov ss, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov esp, STACK_TOP_32           ; 0x90000
    mov ebp, esp

    ; Direct VGA write: [char][attr] pairs, 80 columns * 2 bytes per row
    mov esi, msg_pm
    mov edi, VGA_TEXT + VGA_ROW_PM * 80 * 2
    mov ah, VGA_ATTR_WHITE
.print:
    lodsb
    test al, al
    jz .printed
    mov [edi], ax                   ; low byte = char, high byte = attribute
    add edi, 2
    jmp .print
.printed:

    jmp CODE_SEG:KERNEL_ADDR        ; enter kernel_entry.asm (_start)

; =============================================================================
; GDT - flat 4 GiB code and data segments
; =============================================================================
align 8
gdt_start:
gdt_null:                           ; 0x00: mandatory null descriptor
    dq 0x0

gdt_code:                           ; 0x08: base 0, limit 0xFFFFF, ring 0 code
    dw 0xFFFF                       ; limit 15:0
    dw 0x0000                       ; base 15:0
    db 0x00                         ; base 23:16
    db 0x9A                         ; access: P=1 DPL=00 S=1 type=1010 (X/R)
    db 0xCF                         ; flags G=1 D/B=1 L=0 AVL=0 (0xC) | limit 19:16 (0xF)
    db 0x00                         ; base 31:24

gdt_data:                           ; 0x10: base 0, limit 0xFFFFF, ring 0 data
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92                         ; access: P=1 DPL=00 S=1 type=0010 (R/W)
    db 0xCF
    db 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1      ; limit = 23
    dd gdt_start                    ; linear base (DS = 0, so offset = linear)

; =============================================================================
; Data
; =============================================================================
msg_stage2      db "Stage 2 Loaded (Real Mode)", 0x0D, 0x0A, 0
msg_kernel_ok   db "Kernel loaded to 0x10000", 0x0D, 0x0A, 0
msg_kernel_err  db "Kernel read error, status=0x", 0
msg_a20_already db "A20 already enabled", 0x0D, 0x0A, 0
msg_a20_bios    db "A20 enabled via INT 15h/2401h", 0x0D, 0x0A, 0
msg_a20_fast    db "A20 enabled via Fast A20 (port 0x92)", 0x0D, 0x0A, 0
msg_a20_kbc     db "A20 enabled via 8042 controller", 0x0D, 0x0A, 0
msg_a20_fail    db "FATAL: could not enable A20", 0x0D, 0x0A, 0
msg_pm_switch   db "Switching to 32-bit Protected Mode...", 0x0D, 0x0A, 0
msg_pm          db "Protected Mode Active", 0

BOOT_DRIVE      db 0
retries_left    db 0
disk_status     db 0

times 2048 - ($ - $$) db 0          ; exactly 4 sectors
