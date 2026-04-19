# NostOS Testing Apps Makefile

Z88DK   = /home/smbaker/projects/pi/z88dk
ASM     = $(Z88DK)/bin/z80asm
RM      = rm -f
MKRELOC = python3 ../../tools/mkreloc.py

ASM_FLAGS = -b -reloc-info -m -l

APPS = randdata multifile sizetest ttstest dbgtest
APP_BINS = $(foreach app,$(APPS),build/$(app).app)

.PHONY: all clean

all: build $(APP_BINS)

build:
	mkdir -p build

# Relocatable app: assemble with -reloc-info, then pack with mkreloc
build/%.app: %.asm
	$(ASM) $(ASM_FLAGS) -o=build/$*.bin $<
	$(MKRELOC) build/$*.bin build/$*.reloc $@
	$(RM) build/$*.bin build/$*.reloc

clean:
	$(RM) -r build
	$(RM) *.lis *.map *.o
