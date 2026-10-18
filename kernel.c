/*
 * kernel.c - freestanding 32-bit C kernel
 *
 * Entered from kernel_entry.asm in ring 0, flat segments, ESP = 0x90000.
 * No libc, no builtins: writes straight to the VGA text buffer.
 */

/* volatile: every store to MMIO must actually happen, in order. */
#define VGA_MEMORY   ((volatile char *)0xB8000)
#define VGA_COLUMNS  80
#define VGA_ATTR     0x1F           /* bright white on blue */

void main(void)
{
    const char *message = "Sammith Reddy Vanja has created a small custom OS that boots";
    volatile char *vga = VGA_MEMORY;
    int col = 0;

    for (; message[col] != '\0'; col++) {
        vga[col * 2]     = message[col];
        vga[col * 2 + 1] = VGA_ATTR;
    }

    /* Fill the rest of row 0 so the banner spans the whole line. */
    for (; col < VGA_COLUMNS; col++) {
        vga[col * 2]     = ' ';
        vga[col * 2 + 1] = VGA_ATTR;
    }
}
