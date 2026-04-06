# NostOS 3rd-Party Apps Makefile

Z88DK   = /home/smbaker/projects/pi/z88dk
ASM     = $(Z88DK)/bin/z80asm
RM      = rm -f
MKRELOC = python3 ../../tools/mkreloc.py

ASM_FLAGS = -b -reloc-info -m -l

APPS = basic forth zork
APP_BINS = $(foreach app,$(APPS),build/$(app).app)

.PHONY: all clean

all: build $(APP_BINS) build/zealasm.app

build:
	mkdir -p build

# Relocatable app: assemble with -reloc-info, then pack with mkreloc
build/%.app: %.asm
	$(ASM) $(ASM_FLAGS) -o=build/$*.bin $<
	$(MKRELOC) build/$*.bin build/$*.reloc $@
	$(RM) build/$*.bin build/$*.reloc

# Zealasm: multi-file app in subdirectory (uses INCLUDE directives)
build/zealasm.app: build zealasm/zealasm.asm zealasm/strutils.asm zealasm/data.asm zealasm/file.asm zealasm/parser.asm
	cd zealasm && $(ASM) $(ASM_FLAGS) -o=../build/zealasm.bin zealasm.asm
	$(MKRELOC) build/zealasm.bin build/zealasm.reloc build/zealasm.app
	$(RM) build/zealasm.bin build/zealasm.reloc

clean:
	$(RM) -r build
	$(RM) *.lis *.map *.o
