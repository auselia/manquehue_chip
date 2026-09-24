# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Paul Scheffler <paulsc@iis.ee.ethz.ch>
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Toolchain
RISCV_XLEN    ?= 32
RISCV_MARCH   ?= rv$(RISCV_XLEN)i_zicsr
RISCV_MABI    ?= ilp32
RISCV_PREFIX  ?= riscv64-unknown-elf-
RISCV_CC      ?= $(RISCV_PREFIX)gcc
RISCV_CXX     ?= $(RISCV_PREFIX)g++
RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_AS      ?= $(RISCV_PREFIX)as
RISCV_AR      ?= $(RISCV_PREFIX)ar
RISCV_LD      ?= $(RISCV_PREFIX)ld
RISCV_STRIP   ?= $(RISCV_PREFIX)strip

# Compiler and linker flags
RISCV_FLAGS ?= -march=$(RISCV_MARCH) -mabi=$(RISCV_MABI) -mcmodel=medany \
	-static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding
RISCV_CCFLAGS ?= $(RISCV_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR)
RISCV_LDFLAGS ?= -static -nostartfiles -lm -lgcc $(RISCV_FLAGS)


# Directory defaults
BINDIR   ?= bin
BUILDDIR ?= build
CRT0     ?= crt0.S
LINK     ?= link.ld
SRCDIR   ?= lib/src
INCDIR   ?= lib/inc

# Collecting source files
#
# trampoline.S is excluded here: it's a separate, standalone program with its
# own _start and its own linker script (trampoline.ld) -- it must NOT be
# linked against crt0.o/link.ld like every other top-level source, which is
# what the generic $(BINDIR)/%.elf rule below does. It gets its own explicit
# build rule further down instead.
LIB_SOURCES  := $(wildcard $(SRCDIR)/*.[cS])
TOP_SOURCES  := $(filter-out $(CRT0) trampoline.S, $(wildcard *.[cS]))
TEST_SOURCES := $(wildcard test/*.[cS])
PROG_SOURCES := $(TOP_SOURCES) $(TEST_SOURCES)

PROG_NAMES   := $(basename $(PROG_SOURCES))

# Creating object fiel list from source files
CRT0_OBJ  := $(BUILDDIR)/$(basename $(CRT0)).o
LIB_OBJS  := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(LIB_SOURCES))))
PROG_OBJS := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(PROG_SOURCES))))

# Everything to be built
#
# .bin (in addition to the upstream .elf/.dump/.hex): a flat binary image,
# the format a real SPI flash programmer wants -- unlike .hex (-O verilog),
# which is only a $readmemh image for the RTL flash *simulation* model, not
# something you can write to a physical chip. Program this starting at
# flash offset 0 (it starts at .text's load address, 0x2000_0000 = the QSPI
# window base). How to actually get it onto the real flash chip on the
# qspi_pmod board depends on whatever programmer/tool you're using -- not
# solved by this Makefile.
ALL_TARGETS := $(PROG_NAMES:%=$(BINDIR)/%.elf) \
	           $(PROG_NAMES:%=$(BINDIR)/%.dump) \
	           $(PROG_NAMES:%=$(BINDIR)/%.hex) \
	           $(PROG_NAMES:%=$(BINDIR)/%.bin) \
	           $(BINDIR)/trampoline.elf $(BINDIR)/trampoline.dump \
	           $(BINDIR)/trampoline.hex $(BINDIR)/trampoline.bin

# Dependency files for automatic rebuilds
DEPFILES := $(CRT0_OBJ:.o=.d) $(LIB_OBJS:.o=.d) $(PROG_OBJS:.o=.d)

# Ensure intermediate object files are not deleted after linking
.SECONDARY: $(CRT0_OBJ) $(LIB_OBJS) $(PROG_OBJS)

all: compile

$(BINDIR):
	mkdir -p $(BINDIR)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Assembly to object compilation
$(BUILDDIR)/%.o: %.S
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# C to object compilation
$(BUILDDIR)/%.o: %.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# Linking
$(BINDIR)/%.elf: $(BUILDDIR)/%.o $(CRT0_OBJ) $(LIB_OBJS) $(LINK)
	mkdir -p $(dir $@)
	$(RISCV_CC) -o $@ $(filter-out $(LINK), $^) $(RISCV_LDFLAGS) -T$(LINK)

# Dump ELF data and disassembly
$(BINDIR)/%.dump: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJDUMP) -D -s $< >$@

# Convert ELF to hex format for easy loading into simulators (RTL flash model)
$(BINDIR)/%.hex: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O verilog $< $@

# Convert ELF to a flat binary for programming a real SPI flash chip
$(BINDIR)/%.bin: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O binary $< $@

# trampoline.elf: standalone, no crt0.o, its own linker script -- see the
# comment on TOP_SOURCES above for why this can't go through the generic
# $(BINDIR)/%.elf rule.
$(BINDIR)/trampoline.elf: trampoline.S trampoline.ld
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) $(RISCV_LDFLAGS) trampoline.S -o $@ -Ttrampoline.ld

# Phonies
.PHONY: all clean compile

clean:
	rm -rf $(BINDIR) $(BUILDDIR)

compile: $(BINDIR) $(BUILDDIR) $(ALL_TARGETS)

-include $(DEPFILES)
