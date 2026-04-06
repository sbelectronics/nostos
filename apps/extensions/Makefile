# NostOS Extensions Makefile

Z88DK   = /home/smbaker/projects/pi/z88dk
ASM     = $(Z88DK)/bin/z80asm
RM      = rm -f
MKRELOC = python3 ../../tools/mkreloc.py

EXT_FLAGS = -b -reloc-info -m -l

EXTS = helloext exttorture speech tts vfd dup
EXT_BINS = $(foreach ext,$(EXTS),build/$(ext).ext)

.PHONY: all clean

all: build $(EXT_BINS)

build:
	mkdir -p build

# Relocatable extension: assemble with -reloc-info, then pack with mkreloc
build/%.ext: %.asm
	$(ASM) $(EXT_FLAGS) -o=build/$*.bin $<
	$(MKRELOC) build/$*.bin build/$*.reloc $@
	$(RM) build/$*.bin build/$*.reloc

clean:
	$(RM) -r build
	$(RM) *.lis *.map *.o
