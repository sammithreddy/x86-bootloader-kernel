/*
 * linker.ld - flat binary kernel loaded by Stage 2 at linear 0x10000
 * (Stage 2 occupies 0x8000-0x87FF; the kernel sits above it with room to grow.)
 */
OUTPUT_FORMAT("binary")
ENTRY(_start)

SECTIONS
{
    . = 0x10000;

    .text : {
        *(.text.entry)              /* kernel_entry.asm _start must be first */
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame .eh_frame_hdr)
        *(.note .note.*)
    }
}
