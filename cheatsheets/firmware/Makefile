# Makefile — build the reflexrv firmware (boot.S + main.c)
#
# Usage:
#   make            # build boot.elf
#   make disasm     # build + show disassembly
#   make hex        # build + emit boot.hex (Intel HEX, for sim memory init)
#   make bin        # build + emit boot.bin (raw binary)
#   make size       # build + print section sizes
#   make clean      # remove build artifacts
#
# Override toolchain/arch at the command line if needed, e.g.:
#   make MARCH=rv64imac MABI=lp64

CROSS   ?= riscv-none-elf-
CC      = $(CROSS)gcc
OBJDUMP = $(CROSS)objdump
OBJCOPY = $(CROSS)objcopy
SIZE    = $(CROSS)size

MARCH   ?= rv32imc
MABI    ?= ilp32

TARGET   = boot
SRCS     = boot.S main.c
LDSCRIPT = linker.ld

CFLAGS  = -march=$(MARCH) -mabi=$(MABI) -nostartfiles -ffreestanding -O2 -g -Wall
LDFLAGS = -T $(LDSCRIPT) -nostartfiles -Wl,-Map=$(TARGET).map

.PHONY: all disasm hex bin size clean

all: $(TARGET).elf

$(TARGET).elf: $(SRCS) $(LDSCRIPT)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)

disasm: $(TARGET).elf
	$(OBJDUMP) -dS $(TARGET).elf

hex: $(TARGET).elf
	$(OBJCOPY) -O ihex $(TARGET).elf $(TARGET).hex

bin: $(TARGET).elf
	$(OBJCOPY) -O binary $(TARGET).elf $(TARGET).bin

size: $(TARGET).elf
	$(SIZE) $(TARGET).elf

clean:
	rm -f $(TARGET).elf $(TARGET).map $(TARGET).hex $(TARGET).bin