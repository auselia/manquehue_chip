# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Paul Scheffler <paulsc@iis.ee.ethz.ch>
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Build rules of a croc_soc program, shared by all programs (Nicolás Villegas, Universidad de los Andes: one library
# for all programs). A program Makefile includes this file. Every *.c and *.S of the program folder and of TESTDIR
# gives bin/<name>.{elf,dump,hex}, linked with crt0.S and the library of this folder (and the program's own lib/).
# usage: make [RISCV_PREFIX=...]      in a program folder

# This folder: crt0.S, link.ld, config.h, inc/ and src/
LIB := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

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

# Compiler and linker flags. The program folder comes before the library, so a program can have its own config.h.
RISCV_FLAGS ?= -march=$(RISCV_MARCH) -mabi=$(RISCV_MABI) -mcmodel=medany \
	-static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding
RISCV_CCFLAGS ?= $(RISCV_FLAGS) -Iinclude -Ilib/inc -I$(LIB)/inc -I$(CURDIR) -I$(LIB)
RISCV_LDFLAGS ?= -static -nostartfiles -lm -lgcc $(RISCV_FLAGS)

# Directory defaults
BINDIR   ?= bin
BUILDDIR ?= build
CRT0     ?= $(LIB)/crt0.S
LINK     ?= $(LIB)/link.ld
TESTDIR  ?= test

# Collecting source files: the library, then the program's own lib/src
LIB_SOURCES  := $(wildcard $(LIB)/src/*.[cS]) $(wildcard lib/src/*.[cS])
TOP_SOURCES  := $(filter-out crt0.S, $(wildcard *.[cS]))
TEST_SOURCES := $(wildcard $(TESTDIR)/*.[cS])

PROG_NAMES   := $(basename $(TOP_SOURCES)) $(addprefix test/, $(basename $(notdir $(TEST_SOURCES))))

# Creating object file list from source files
CRT0_OBJ  := $(BUILDDIR)/crt0.o
LIB_OBJS  := $(addsuffix .o, $(addprefix $(BUILDDIR)/lib/, $(basename $(notdir $(LIB_SOURCES)))))
PROG_OBJS := $(PROG_NAMES:%=$(BUILDDIR)/%.o)

# Everything to be built
ALL_TARGETS := $(PROG_NAMES:%=$(BINDIR)/%.elf) \
	           $(PROG_NAMES:%=$(BINDIR)/%.dump) \
	           $(PROG_NAMES:%=$(BINDIR)/%.hex)

# Dependency files for automatic rebuilds
DEPFILES := $(CRT0_OBJ:.o=.d) $(LIB_OBJS:.o=.d) $(PROG_OBJS:.o=.d)

# Ensure intermediate object files are not deleted after linking
.SECONDARY: $(CRT0_OBJ) $(LIB_OBJS) $(PROG_OBJS)

all: compile

$(BINDIR):
	mkdir -p $(BINDIR)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# crt0, the library (shared, then the program's own) and the tests
$(CRT0_OBJ): $(CRT0)
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/lib/%.o: $(LIB)/src/%.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/lib/%.o: lib/src/%.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/test/%.o: $(TESTDIR)/%.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

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

# Convert ELF to hex format for easy loading into simulators or hardware
$(BINDIR)/%.hex: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O verilog $< $@

# Phonies
.PHONY: all clean compile

clean:
	rm -rf $(BINDIR) $(BUILDDIR)

compile: $(BINDIR) $(BUILDDIR) $(ALL_TARGETS)

-include $(DEPFILES)
