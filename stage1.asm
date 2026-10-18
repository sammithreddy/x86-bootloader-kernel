; =============================================================================
; stage1.asm - 512-byte MBR boot sector (16-bit real mode)
;
; Loaded by the BIOS at 0x0000:0x7C00 with DL = boot drive number.
; Prints a banner, reads Stage 2 (4 sectors, CHS 0/0/2) to 0x0000:0x8000
; with up to 3 retries, then far-jumps to it.
;
; Disk layout (LBA = CHS sector - 1):
;   LBA 0      : this sector (stage1.bin, 512 bytes, ends in 0x55 0xAA)
;   LBA 1..4   : stage2.bin (exactly 2048 bytes)
;   LBA 5..    : kernel.bin (loaded by Stage 2)
; =============================================================================

[BITS 16]
[ORG 0x7C00]

STAGE2_SEGMENT  equ 0x0000
STAGE2_OFFSET   equ 0x8000
STAGE2_SECTORS  equ 0x04            ; 4 * 512 = 2048 bytes
STAGE2_START_CL equ 0x02            ; CHS sector numbers are 1-based
MAX_RETRIES     equ 3

start:
    ; Some BIOSes enter at 0x07C0:0x0000 instead of 0x0000:0x7C00.
    ; Normalise CS:IP so ORG 0x7C00 addressing is valid.
    jmp 0x0000:init

init:
    cli                             ; no interrupts while SS:SP is inconsistent
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00                  ; stack grows down from just below us
    sti
    cld                             ; string ops increment SI/DI

    mov [BOOT_DRIVE], dl            ; BIOS passes boot drive in DL

    mov si, msg_stage1
    call print_string

    mov byte [retries_left], MAX_RETRIES

.read_stage2:
    mov ax, STAGE2_SEGMENT
    mov es, ax
    mov bx, STAGE2_OFFSET           ; ES:BX = 0x0000:0x8000
    mov ah, 0x02                    ; INT 13h AH=02h: read sectors (CHS)
    mov al, STAGE2_SECTORS          ; AL = sector count
    mov ch, 0x00                    ; CH = cylinder 0
    mov cl, STAGE2_START_CL         ; CL = sector 2
    mov dh, 0x00                    ; DH = head 0
    mov dl, [BOOT_DRIVE]            ; DL = drive
    int 0x13
    jc .read_failed                 ; CF=1 -> error, AH = status
    cmp al, STAGE2_SECTORS          ; AL = sectors actually read
    jne .short_read
    jmp stage2_loaded

.short_read:
    mov ah, 0xFF                    ; synthetic status: wrong sector count
.read_failed:
    mov [disk_status], ah
    cmp byte [retries_left], 0
    je disk_error
    dec byte [retries_left]
    xor ah, ah                      ; INT 13h AH=00h: reset disk system
    mov dl, [BOOT_DRIVE]
    int 0x13
    jmp .read_stage2

stage2_loaded:
    mov si, msg_jump
    call print_string
    mov dl, [BOOT_DRIVE]            ; hand the drive number to Stage 2
    jmp STAGE2_SEGMENT:STAGE2_OFFSET

; -----------------------------------------------------------------------------
; disk_error - print status code in hex and halt forever
; -----------------------------------------------------------------------------
disk_error:
    mov si, msg_disk_err
    call print_string
    mov al, [disk_status]
    call print_hex8
    mov si, msg_crlf
    call print_string
.halt:
    cli
    hlt
    jmp .halt

; -----------------------------------------------------------------------------
; print_string - DS:SI -> NUL-terminated string, BIOS teletype (INT 10h/0Eh)
; Clobbers: AX, BX, SI
; -----------------------------------------------------------------------------
print_string:
    mov ah, 0x0E                    ; teletype output
    mov bh, 0x00                    ; page 0
    mov bl, 0x07                    ; light grey (graphics modes only)
.next:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .next
.done:
    ret

; -----------------------------------------------------------------------------
; print_hex8 - print AL as two hex digits
; Clobbers: AX, BX, CX
; -----------------------------------------------------------------------------
print_hex8:
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

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------
msg_stage1   db "Stage 1 Loaded (Real Mode)", 0x0D, 0x0A, 0
msg_jump     db "Stage 2 read OK, jumping to 0x0000:0x8000", 0x0D, 0x0A, 0
msg_disk_err db "Disk read error, status=0x", 0
msg_crlf     db 0x0D, 0x0A, 0

BOOT_DRIVE   db 0
retries_left db 0
disk_status  db 0

; -----------------------------------------------------------------------------
; Pad to 510 bytes and append the boot signature (0x55 at 510, 0xAA at 511)
; -----------------------------------------------------------------------------
times 510 - ($ - $$) db 0
dw 0xAA55
