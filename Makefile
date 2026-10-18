# =============================================================================
# Makefile - x86 BIOS bootloader + C kernel, built on Apple Silicon macOS
#
#   make          build os_image.bin (and verify it)
#   make run      build and boot in QEMU
#   make debug    boot paused with a GDB stub on :1234
#   make clean    remove build outputs
#
# Toolchain: x86_64-elf-gcc / x86_64-elf-ld from Homebrew when present,
# otherwise Apple clang (-target i386-pc-none-elf) + ld.lld (brew install lld).
# =============================================================================

NASM  := nasm
QEMU  := qemu-system-x86_64

ifneq ($(shell command -v x86_64-elf-gcc 2>/dev/null),)
  CC      := x86_64-elf-gcc
  LD      := x86_64-elf-ld
  CCARCH  := -m32 -march=i386
  LDARCH  := -m elf_i386
else
  CC      := clang
  LD      := ld.lld
  CCARCH  := -target i386-pc-none-elf -m32 -march=i386
  LDARCH  := -m elf_i386 --oformat binary
endif

CFLAGS  := $(CCARCH) -std=c11 -O2 -Wall -Wextra \
           -ffreestanding -fno-builtin -nostdlib -nostdinc \
           -fno-pie -fno-pic -fno-stack-protector \
           -fno-asynchronous-unwind-tables -fno-unwind-tables
LDFLAGS := $(LDARCH) -T linker.ld -nostdlib -Map kernel.map

IMAGE_SIZE := 1048576   # pad the disk to 1 MiB so QEMU picks sane CHS geometry

.PHONY: all run debug verify clean

all: os_image.bin verify

# --- Stage 1: exactly 512 bytes ---------------------------------------------
stage1.bin: stage1.asm
	$(NASM) -f bin $< -o $@

# --- Kernel -----------------------------------------------------------------
kernel_entry.o: kernel_entry.asm
	$(NASM) -f elf32 $< -o $@

kernel.o: kernel.c
	$(CC) $(CFLAGS) -c $< -o $@

# kernel_entry.o MUST be first so _start lands at 0x10000
kernel.bin: kernel_entry.o kernel.o linker.ld
	$(LD) $(LDFLAGS) -o $@ kernel_entry.o kernel.o

# --- Stage 2: needs the kernel's sector count -------------------------------
stage2.bin: stage2.asm kernel.bin
	$(NASM) -f bin -DKERNEL_SECTORS=$$(( ($$(wc -c < kernel.bin) + 511) / 512 )) $< -o $@

# --- Disk image -------------------------------------------------------------
#   LBA 0     stage1.bin  (512 B)
#   LBA 1-4   stage2.bin  (2048 B)
#   LBA 5..   kernel.bin  (padded to whole sectors)
os_image.bin: stage1.bin stage2.bin kernel.bin
	dd if=kernel.bin of=kernel.pad bs=512 conv=sync 2>/dev/null
	cat stage1.bin stage2.bin kernel.pad > $@
	dd if=/dev/zero of=$@ bs=1 count=0 seek=$(IMAGE_SIZE) 2>/dev/null
	rm -f kernel.pad

# --- Sanity checks ----------------------------------------------------------
verify: os_image.bin
	@s1=$$(wc -c < stage1.bin | tr -d ' '); \
	 [ "$$s1" -eq 512 ] || { echo "FAIL: stage1.bin is $$s1 bytes (want 512)"; exit 1; }
	@sig=$$(xxd -s 510 -l 2 -p os_image.bin); \
	 [ "$$sig" = "55aa" ] || { echo "FAIL: boot signature is $$sig (want 55aa)"; exit 1; }
	@s2=$$(wc -c < stage2.bin | tr -d ' '); \
	 [ "$$s2" -eq 2048 ] || { echo "FAIL: stage2.bin is $$s2 bytes (want 2048)"; exit 1; }
	@k=$$(wc -c < kernel.bin | tr -d ' '); \
	 echo "OK: stage1=512 B, signature=0x55AA, stage2=2048 B, kernel=$$k B ($$(( (k + 511) / 512 )) sectors)"

run: all
	$(QEMU) -drive format=raw,file=os_image.bin,index=0,media=disk

debug: all
	$(QEMU) -drive format=raw,file=os_image.bin,index=0,media=disk -s -S

clean:
	rm -f *.bin *.o *.pad kernel.map
