FSTOOL  = ../tools/bin/fstool
IMAGES  = testing.img testing-native.img testing-3rdparty.img testing-extensions.img fables.img production.img tiny.img

.PHONY: all clean

all: $(IMAGES)

testing.img: $(FSTOOL)
	# with header compatible with etchedpixels image
	dd if=/dev/zero bs=512 count=4112 of=testing.img
	dd if=cfheader.bin bs=1 of=testing.img conv=notrunc
	dd if=cfident.bin bs=1 of=testing.img seek=512 conv=notrunc
	$(FSTOOL) -H testing.img format 2000
	echo "scott was here" > /tmp/fstool_scott.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_scott.txt scott.txt
	$(FSTOOL) -H testing.img add ../tests/testdata/odyssey.txt odyssey.txt
	$(FSTOOL) -H testing.img add ../apps/native/build/helloworld.app helloworld.app
	$(FSTOOL) -H testing.img add ../apps/testing/build/randdata.app randdata.app
	$(FSTOOL) -H testing.img add ../apps/testing/build/multifile.app multifile.app
	$(FSTOOL) -H testing.img add ../apps/testing/build/sizetest.app sizetest.app
	$(FSTOOL) -H testing.img add ../apps/native/build/more.app more.app
	$(FSTOOL) -H testing.img add ../apps/native/build/wc.app wc.app
	$(FSTOOL) -H testing.img add ../apps/native/build/tail.app tail.app
	$(FSTOOL) -H testing.img add ../apps/native/build/head.app head.app
	$(FSTOOL) -H testing.img add ../apps/native/build/append.app append.app
	# cause some intentional fragmentation by adding and deleting files
	echo "one" > /tmp/fstool_one.txt
	echo "two" > /tmp/fstool_two.txt
	echo "three" > /tmp/fstool_three.txt
	echo "four" > /tmp/fstool_four.txt
	echo "five" > /tmp/fstool_five.txt
	echo "six" > /tmp/fstool_six.txt
	echo "seven" > /tmp/fstool_seven.txt
	echo "eight" > /tmp/fstool_eight.txt
	echo "nine" > /tmp/fstool_nine.txt
	echo "ten" > /tmp/fstool_ten.txt
	echo "eleven" > /tmp/fstool_eleven.txt
	echo "twelve" > /tmp/fstool_twelve.txt
	echo "thirteen" > /tmp/fstool_thirteen.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_one.txt one.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_two.txt two.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_three.txt three.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_four.txt four.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_five.txt five.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_six.txt six.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_seven.txt seven.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_eight.txt eight.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_nine.txt nine.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_ten.txt ten.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_eleven.txt eleven.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_twelve.txt twelve.txt
	$(FSTOOL) -H testing.img rm two.txt
	$(FSTOOL) -H testing.img rm four.txt
	$(FSTOOL) -H testing.img rm five.txt
	$(FSTOOL) -H testing.img rm nine.txt
	$(FSTOOL) -H testing.img rm ten.txt
	$(FSTOOL) -H testing.img rm eleven.txt
	$(FSTOOL) -H testing.img add ../tests/testdata/odyssey.txt odysseyf.txt
	$(FSTOOL) -H testing.img mkdir mydir
	echo "this is a test" > /tmp/fstool_myfile.txt
	$(FSTOOL) -H testing.img add /tmp/fstool_myfile.txt mydir/myfile.txt
	rm -f /tmp/fstool_*.txt
	@echo "Created testing.img"

testing-native.img: $(FSTOOL)
	# with header compatible with etchedpixels image
	dd if=/dev/zero bs=512 count=4112 of=testing-native.img
	dd if=cfheader.bin bs=1 of=testing-native.img conv=notrunc
	dd if=cfident.bin bs=1 of=testing-native.img seek=512 conv=notrunc
	$(FSTOOL) -H testing-native.img format 2000
	$(FSTOOL) -H testing-native.img add ../apps/native/build/maze.app MAZE.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/debug.app DEBUG.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/helloworld.app HELLO.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/xsend.app XSEND.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/xrecv.app XRECV.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/startrek.app STARTREK.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/chess.app CHESS.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/life.app LIFE.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/pacman.app PACMAN.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/tetris.app TETRIS.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/eliza.app ELIZA.APP
	$(FSTOOL) -H testing-native.img add ../apps/testing/build/dbgtest.app DBGTEST.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/more.app MORE.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/wc.app WC.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/tail.app TAIL.APP
	$(FSTOOL) -H testing-native.img add ../apps/native/build/head.app HEAD.APP
	echo "test" > /tmp/fstool_xtest.txt
	$(FSTOOL) -H testing-native.img add /tmp/fstool_xtest.txt XTEST.TXT
	rm -f /tmp/fstool_xtest.txt
	@echo "Created testing-native.img"

testing-3rdparty.img: $(FSTOOL)
	# with header compatible with etchedpixels image
	dd if=/dev/zero bs=512 count=4112 of=testing-3rdparty.img
	dd if=cfheader.bin bs=1 of=testing-3rdparty.img conv=notrunc
	dd if=cfident.bin bs=1 of=testing-3rdparty.img seek=512 conv=notrunc
	$(FSTOOL) -H testing-3rdparty.img format 2000
	$(FSTOOL) -H testing-3rdparty.img add ../apps/3rdparty/build/basic.app BASIC.APP
	$(FSTOOL) -H testing-3rdparty.img add ../apps/3rdparty/build/forth.app FORTH.APP
	$(FSTOOL) -H testing-3rdparty.img add ../apps/3rdparty/build/zork.app ZORK.APP
	$(FSTOOL) -H testing-3rdparty.img add ../apps/3rdparty/zork1.dat ZORK1.DAT
	$(FSTOOL) -H testing-3rdparty.img add ../apps/3rdparty/build/zealasm.app ZEALASM.APP
	$(FSTOOL) -H testing-3rdparty.img add ../apps/native/build/append.app APPEND.APP
	$(FSTOOL) -H testing-3rdparty.img add ../apps/native/build/ed.app ED.APP
	$(FSTOOL) -H testing-3rdparty.img add data/sample.asm SAMPLE.ASM
	@echo "Created testing-3rdparty.img"

testing-extensions.img: $(FSTOOL)
	# with header compatible with etchedpixels image
	dd if=/dev/zero bs=512 count=4112 of=testing-extensions.img
	dd if=cfheader.bin bs=1 of=testing-extensions.img conv=notrunc
	dd if=cfident.bin bs=1 of=testing-extensions.img seek=512 conv=notrunc
	$(FSTOOL) -H testing-extensions.img format 2000
	$(FSTOOL) -H testing-extensions.img add ../apps/extensions/build/helloext.ext helloext.ext
	$(FSTOOL) -H testing-extensions.img add ../apps/extensions/build/exttorture.ext exttorture.ext
	$(FSTOOL) -H testing-extensions.img add ../apps/extensions/build/speech.ext speech.ext
	$(FSTOOL) -H testing-extensions.img add ../apps/extensions/build/tts.ext tts.ext
	$(FSTOOL) -H testing-extensions.img add ../apps/extensions/build/vfd.ext vfd.ext
	$(FSTOOL) -H testing-extensions.img add ../apps/extensions/build/dup.ext dup.ext
	$(FSTOOL) -H testing-extensions.img add ../apps/testing/build/ttstest.app ttstest.app
	@echo "Created testing-extensions.img"

fables.img: $(FSTOOL)
	dd if=/dev/zero bs=512 count=900 of=fables.img 2>/dev/null
	$(FSTOOL) fables.img format 900
	$(FSTOOL) fables.img mkdir AESOP
	$(FSTOOL) fables.img mkdir JATAKA1
	$(FSTOOL) fables.img mkdir JATAKA2
	for f in ../tests/testdata/aesop_fables/*.txt; do $(FSTOOL) fables.img add $$f AESOP/$$(basename $$f); done
	for f in ../tests/testdata/jataka1/*.txt; do $(FSTOOL) fables.img add $$f JATAKA1/$$(basename $$f); done
	for f in ../tests/testdata/jataka2/*.txt; do $(FSTOOL) fables.img add $$f JATAKA2/$$(basename $$f); done
	$(FSTOOL) fables.img add ../apps/native/build/format.app FORMAT.APP
	$(FSTOOL) fables.img add ../apps/native/build/fdinit.app FDINIT.APP
	$(FSTOOL) fables.img add ../apps/native/build/ed.app ED.APP
	$(FSTOOL) fables.img add ../apps/native/build/append.app APPEND.APP
	$(FSTOOL) fables.img add ../apps/native/build/xrecv.app XRECV.APP
	$(FSTOOL) fables.img add ../apps/native/build/xsend.app XSEND.APP

production.img: $(FSTOOL)
	dd if=/dev/zero bs=512 count=900 of=production.img 2>/dev/null
	$(FSTOOL) production.img format 900
	$(FSTOOL) production.img add ../apps/native/build/format.app FORMAT.APP
	$(FSTOOL) production.img add ../apps/native/build/fdinit.app FDINIT.APP
	$(FSTOOL) production.img add ../apps/3rdparty/build/basic.app BASIC.APP
	$(FSTOOL) production.img add ../apps/3rdparty/build/forth.app FORTH.APP
	$(FSTOOL) production.img add ../apps/native/build/ed.app ED.APP
	$(FSTOOL) production.img add ../apps/native/build/append.app APPEND.APP
	$(FSTOOL) production.img add ../apps/native/build/more.app MORE.APP
	$(FSTOOL) production.img add ../apps/native/build/wc.app WC.APP
	$(FSTOOL) production.img add ../apps/native/build/tail.app TAIL.APP
	$(FSTOOL) production.img add ../apps/native/build/head.app HEAD.APP
	$(FSTOOL) production.img mkdir GAMES
	$(FSTOOL) production.img add ../apps/native/build/maze.app GAMES/MAZE.APP
	$(FSTOOL) production.img add ../apps/native/build/startrek.app GAMES/STARTREK.APP
	$(FSTOOL) production.img add ../apps/native/build/chess.app GAMES/CHESS.APP
	$(FSTOOL) production.img add ../apps/native/build/life.app GAMES/LIFE.APP
	$(FSTOOL) production.img add ../apps/native/build/pacman.app GAMES/PACMAN.APP
	$(FSTOOL) production.img add ../apps/native/build/tetris.app GAMES/TETRIS.APP
	$(FSTOOL) production.img add ../apps/native/build/eliza.app GAMES/ELIZA.APP
	$(FSTOOL) production.img add ../apps/native/build/debug.app DEBUG.APP
	$(FSTOOL) production.img add ../apps/native/build/xrecv.app XRECV.APP
	$(FSTOOL) production.img add ../apps/native/build/xsend.app XSEND.APP
	$(FSTOOL) production.img add data/production_auto.ply AUTO.PLY
	$(FSTOOL) production.img add ../apps/extensions/build/helloext.ext helloext.ext
	$(FSTOOL) production.img add ../apps/extensions/build/exttorture.ext exttorture.ext
	$(FSTOOL) production.img add ../apps/extensions/build/speech.ext speech.ext
	$(FSTOOL) production.img add ../apps/extensions/build/tts.ext tts.ext
	$(FSTOOL) production.img add ../apps/extensions/build/vfd.ext vfd.ext
	$(FSTOOL) production.img add ../apps/extensions/build/dup.ext dup.ext
	$(FSTOOL) production.img add ../apps/3rdparty/build/zork.app GAMES/ZORK.APP
	$(FSTOOL) production.img add ../apps/3rdparty/zork1.dat GAMES/ZORK1.DAT
	$(FSTOOL) production.img add ../apps/3rdparty/build/zealasm.app ZEALASM.APP
	$(FSTOOL) production.img add data/sample.asm SAMPLE.ASM
	$(FSTOOL) production.img add data/welcome.txt WELCOME.TXT
	@echo "Created production.img"

tiny.img: $(FSTOOL)
	# 16KB (32 blocks) tiny ROM disk image with BASIC and FORMAT
	dd if=/dev/zero bs=512 count=32 of=tiny.img 2>/dev/null
	$(FSTOOL) tiny.img format 32
	$(FSTOOL) tiny.img add ../apps/3rdparty/build/basic.app BASIC.APP
	$(FSTOOL) tiny.img add ../apps/native/build/format.app FORMAT.APP
	@echo "Created tiny.img"

clean:
	rm -f $(IMAGES)
