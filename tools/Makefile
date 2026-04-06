BIN     = bin/fstool
TESTIMG = /tmp/fstool_test.img
TESTHELLO = /tmp/fstool_hello.txt

.PHONY: all test clean

all: $(BIN)

bin:
	mkdir -p bin

$(BIN): bin fstool/main.go fstool/go.mod
	cd fstool && go build -o ../$(BIN) .

test: $(BIN)
	@echo "--- fstool smoke test ---"
	# Create a blank 256-block (128KB) image
	dd if=/dev/zero bs=512 count=256 of=$(TESTIMG) 2>/dev/null
	echo "hello nostos" > $(TESTHELLO)
	# Format
	$(BIN) $(TESTIMG) format 256
	# Info (fresh)
	$(BIN) $(TESTIMG) info
	# Make a directory
	$(BIN) $(TESTIMG) mkdir MYDIR
	# Add files
	$(BIN) $(TESTIMG) add $(TESTHELLO) hello.txt
	$(BIN) $(TESTIMG) add $(TESTHELLO) MYDIR/sub.txt
	# List root and subdir
	$(BIN) $(TESTIMG) dir
	$(BIN) $(TESTIMG) dir MYDIR
	# Get a file back and verify contents
	$(BIN) $(TESTIMG) get MYDIR/sub.txt /tmp/fstool_got.txt
	grep -q "hello nostos" /tmp/fstool_got.txt
	# Rename
	$(BIN) $(TESTIMG) rename HELLO.TXT greet.txt
	# Remove file and directory
	$(BIN) $(TESTIMG) rm greet.txt
	$(BIN) $(TESTIMG) rm MYDIR/sub.txt
	$(BIN) $(TESTIMG) rmdir MYDIR
	# Info (should be back to baseline usage)
	$(BIN) $(TESTIMG) info
	# Cleanup temp files
	rm -f $(TESTIMG) $(TESTHELLO) /tmp/fstool_got.txt
	@echo "--- smoke test passed ---"

clean:
	rm -f $(BIN)
