# NostOS Makefile

# Tools
Z88DK   = /home/smbaker/projects/pi/z88dk
ASM     = $(Z88DK)/bin/z80asm
EMULATOR_RC2014 = /home/smbaker/projects/pi/rc2014_emulatorkit/rc2014
EMULATOR_GOCPUSIM = /home/smbaker/projects/go-cpusim/build/_output/cpusim-z80-rc2014
TEST_EMULATOR ?= gocpusim
CAT     = cat
RM      = rm -f
DD      = dd

# CF disk image for emulator
CF_IMAGE = images/testing.img
# FDC floppy image for emulator
FDC_IMAGE = images/floppy.img

# Test lists — base image (core filesystem tests)
TESTS_QUICK   = basic dir dirlog type type_notfound type_subdir type_odyssey type_odysseyf cd mkdir_rmdir rf cf nf helloworld cf_rom ld_rom cf_overwrite cf_to_con cf_from_con cf_con_con free format ed sum fs_multispan fs_direxpand fs_rename_del fs_filldisk fs_copydir fs_overwrite_sub fs_empty fs_errors fs_eof multifile sizetest colon_syntax path_syntax append readonly play mount assign help info longnames longpath cwd cf_cwd errors
TESTS_TORTURE = ed_torture ed_torture2 ed_torture3 fs_torture fs_torture2 romdisk_torture ramdisk_torture randdata_torture append_torture play_torture create_stress nest_stress more_torture wc_torture tail_torture textutil_torture

# Test lists — native image (native apps)
TESTS_QUICK_NATIVE   = debug xmodem_errors startrek chess chess_errors life pacman tetris eliza more wc tail head
TESTS_TORTURE_NATIVE = startrek_torture startrek_torture2 startrek_lrs_nav startrek_combat startrek_destroy chess_torture chess_torture2 life_torture

# Test lists — 3rdparty image (third-party apps)
TESTS_QUICK_3RDPARTY   = basic_save basiclang forth zork zealasm
TESTS_TORTURE_3RDPARTY = basic_torture forth_torture zealasm_torture zealasm_torture2 zealasm_torture3 zealasm_tabspc zealasm_longmnem zealasm_wstrim zealasm_longjr

# Test lists — extensions image (extension modules)
TESTS_QUICK_EXT   = ttstest dup
TESTS_TORTURE_EXT = extend_torture

# Test lists — FDC (floppy disk controller, uses ACIA-FDC ROM + blank floppy)
TESTS_QUICK_FDC   = fdc
TESTS_TORTURE_FDC =

# Test lists — production
TESTS_CUSTOM =

# Test disk images
TEST_BASE_IMG     = tests/testdata/test_base.img
TEST_NATIVE_IMG   = tests/testdata/test_native.img
TEST_3RDPARTY_IMG = tests/testdata/test_3rdparty.img
TEST_EXT_IMG      = tests/testdata/test_extensions.img
TEST_WORK_IMG     = tests/testdata/test_work.img
TEST_FDC_WORK_IMG = tests/testdata/test_fdc_work.img
FABLES_IMG        = tests/testdata/fables_base.img
PROD_IMG          = tests/testdata/production_base.img
TINY_IMG          = tests/testdata/tiny_base.img

# Production tests (run against production ROM images)
PROD_TESTS = autoplay

# Directories
BUILD   = build
ROM_DIR = $(BUILD)/rom

# Per-variant output files
# Intermediate 16KB ROMs go in $(BUILD)/, final 512KB ROMs go in $(ROM_DIR)/
ROM_ACIA_IMAGE      = $(BUILD)/nostos-acia.bin
ROM_SIO_IMAGE       = $(BUILD)/nostos-sio.bin
ROM_SIO_SB_IMAGE    = $(BUILD)/nostos-sio-sb.bin
ROM_Z180_IMAGE      = $(BUILD)/nostos-z180.bin
ROM_SCC_IMAGE       = $(BUILD)/nostos-scc.bin
ROM_FDC_IMAGE       = $(BUILD)/nostos-acia-fdc.bin

ROM_SCC_BUB_32K_IMAGE = $(BUILD)/nostos-scc-bub-32k.bin
ROM_ACIA_32K_IMAGE  = $(BUILD)/nostos-acia-32k.bin

ROM_ACIA_512K_IMAGE = $(ROM_DIR)/nostos-testing-acia-512k.rom
ROM_FDC_512K_IMAGE  = $(ROM_DIR)/nostos-testing-acia-fdc-512k.rom

PROD_ACIA_512K_IMAGE   = $(ROM_DIR)/nostos-prod-acia-512k.rom
PROD_SIO_512K_IMAGE    = $(ROM_DIR)/nostos-prod-sio-512k.rom
PROD_SIO_SB_512K_IMAGE = $(ROM_DIR)/nostos-prod-sio-sb-512k.rom
PROD_Z180_512K_IMAGE   = $(ROM_DIR)/nostos-prod-z180-512k.rom
PROD_SCC_512K_IMAGE    = $(ROM_DIR)/nostos-prod-scc-512k.rom
PROD_FDC_512K_IMAGE    = $(ROM_DIR)/nostos-prod-acia-fdc-512k.rom
PROD_SCC_BUB_32K_IMAGE     = $(ROM_DIR)/nostos-prod-scc-bub-32k.rom
PROD_SCC_BUB_32K_BOTHBANK_IMAGE = $(ROM_DIR)/nostos-prod-scc-bub-32k-bothbank.rom
PROD_ACIA_32K_IMAGE        = $(ROM_DIR)/nostos-prod-acia-32k.rom
PROD_ACIA_32K_BOTHBANK_IMAGE = $(ROM_DIR)/nostos-prod-acia-32k-bothbank.rom

# Aggregate lists (add new variants here)
ALL_ROMS = $(ROM_ACIA_IMAGE) $(ROM_SIO_IMAGE) $(ROM_SIO_SB_IMAGE) $(ROM_Z180_IMAGE) $(ROM_SCC_IMAGE) $(ROM_FDC_IMAGE) $(ROM_SCC_BUB_32K_IMAGE) $(ROM_ACIA_32K_IMAGE)
ALL_512K = $(ROM_ACIA_512K_IMAGE)
ALL_PROD = $(PROD_ACIA_512K_IMAGE) $(PROD_SIO_512K_IMAGE) $(PROD_SIO_SB_512K_IMAGE) $(PROD_Z180_512K_IMAGE) $(PROD_SCC_512K_IMAGE) $(PROD_FDC_512K_IMAGE) $(PROD_SCC_BUB_32K_IMAGE) $(PROD_SCC_BUB_32K_BOTHBANK_IMAGE) $(PROD_ACIA_32K_IMAGE) $(PROD_ACIA_32K_BOTHBANK_IMAGE)

# Source files
KERNEL_SRC  = src/nostos.asm

# Assembler flags: -b = binary output, -m = generate map file, -l = generate listing
ASM_FLAGS   = -b -m -l

# Sizes (bytes)
ROM_SIZE    = 16384
ROM_512K    = 524288       # 512KB padded image required by emulator -b mode

# Auto-generated build info (version from VERSION file, date from system clock)
BUILD_INFO  = $(BUILD)/build_info.asm

# ============================================================
# Recipe macros (eliminate copy-paste across variants)
# ============================================================

# Build ROM: $(call build_rom_variant,ASM_EXTRA_FLAGS,LABEL)
# Assembles kernel+executive as a single binary.
define build_rom_variant
	$(ASM) $(ASM_FLAGS) $(1) -o=$@ $(KERNEL_SRC)
	@SIZE=$$(wc -c < $@); \
	 echo "ROM ($(2)): $$SIZE / $(ROM_SIZE) bytes"; \
	 if [ $$SIZE -gt $(ROM_SIZE) ]; then echo "ERROR: ROM exceeds 16KB!"; exit 1; fi
endef

# Build 32K ROM: $(call build_32k_rom,ROM_16K,DISK_IMAGE,LABEL)
# 16KB ROM at offset 0, tiny disk image at offset 16384, 0xFF fill.
define build_32k_rom
	$(DD) if=/dev/zero bs=1 count=32768 2>/dev/null | tr '\000' '\377' > $@
	$(DD) if=$(1) of=$@ bs=1 conv=notrunc 2>/dev/null
	$(DD) if=$(2) of=$@ bs=1 seek=16384 conv=notrunc 2>/dev/null
	@echo "32K ROM ($(3)): $@ ($$(wc -c < $@) bytes)"
endef

# Build 512K ROM: $(call build_512k,ROM_16K,DISK_IMAGE,LABEL)
# 16KB ROM at offset 0, disk image at offset 32768, 0xFF fill.
define build_512k
	$(DD) if=/dev/zero bs=1 count=$(ROM_512K) 2>/dev/null | tr '\000' '\377' > $@
	$(DD) if=$(1) of=$@ bs=1 conv=notrunc 2>/dev/null
	$(DD) if=$(2) of=$@ bs=1 seek=32768 conv=notrunc 2>/dev/null
	@echo "512K ROM ($(3)): $@ ($$(wc -c < $@) bytes)"
endef

# ============================================================
# Targets
# ============================================================

.PHONY: all build-roms build-512k build-prod release \
        run-testing run-native run-native-throttled run-3rdparty run-extensions \
        run-fables run-fdc \
        run-production run-production-sio run-production-sio-sb run-production-z180 run-production-scc run-production-scc-bub-32k run-production-acia-32k run-production-fdc \
        test test-one test-quick test-torture test-fdc test-prod \
        tools clean rebuild size FORCE \
		test-exec-standalone

all: build-roms build-512k build-prod

# ============================================================
# Release: copy all build/rom/*.rom files into release/<VERSION>/
# ============================================================
release: all
	@VER=$$(cat VERSION | tr -d '[:space:]'); \
	 DEST=release/$$VER; \
	 mkdir -p $$DEST; \
	 cp $(ROM_DIR)/*.rom $$DEST/; \
	 echo "Released $$(ls $$DEST | wc -l) ROM image(s) to $$DEST/"

build-roms: $(ALL_ROMS)
build-512k: $(ALL_512K)
build-prod: $(ALL_PROD)

$(BUILD):
	mkdir -p $(BUILD)

$(ROM_DIR):
	mkdir -p $(ROM_DIR)

# ============================================================
# Build info generation (version + build date)
# ============================================================

$(BUILD_INFO): VERSION $(BUILD) FORCE
	@VER=$$(cat VERSION | tr -d '[:space:]'); \
	 MAJOR=$$(echo $$VER | cut -d. -f1); \
	 MINOR=$$(echo $$VER | cut -d. -f2 -s); MINOR=$${MINOR:-0}; \
	 PATCH=$$(echo $$VER | cut -d. -f3 -s); PATCH=$${PATCH:-0}; \
	 YEAR=$$(date +%Y); \
	 MONTH=$$(date +%-m); \
	 DAY=$$(date +%-d); \
	 echo "; Auto-generated by Makefile — do not edit" > $@; \
	 echo "NOSTOS_VER_MAJOR    EQU $$MAJOR" >> $@; \
	 echo "NOSTOS_VER_MINOR    EQU $$MINOR" >> $@; \
	 echo "NOSTOS_VER_PATCH    EQU $$PATCH" >> $@; \
	 echo "NOSTOS_BUILD_YEAR   EQU $$YEAR" >> $@; \
	 echo "NOSTOS_BUILD_MONTH  EQU $$MONTH" >> $@; \
	 echo "NOSTOS_BUILD_DAY    EQU $$DAY" >> $@

# ============================================================
# ROM builds (one per variant, differ only in -D flag)
# Each produces a single combined kernel+executive binary.
# ============================================================

ROM_DEPS = $(BUILD) $(BUILD_INFO) $(KERNEL_SRC) FORCE \
           src/include/constants.asm \
           src/executive/executive.asm \
           src/drivers/acia.asm \
           src/drivers/sio.asm \
           src/drivers/z180.asm \
           src/drivers/cf.asm \
           src/drivers/ramdisk.asm \
           src/drivers/nulldev.asm \
           src/drivers/undev.asm \
           src/drivers/fs.asm \
           src/bootstrap/512k-acia.asm \
           src/bootstrap/512k-sio.asm \
           src/bootstrap/512k-sio-sb.asm \
           src/bootstrap/512k-z180.asm \
           src/drivers/scc.asm \
           src/bootstrap/512k-scc.asm \
           src/drivers/tinyramdisk.asm \
           src/drivers/bubble.asm \
           src/bootstrap/32k-scc-bub.asm \
           src/bootstrap/32k-acia.asm \
           src/drivers/fdc.asm \
           src/bootstrap/512k-acia-fdc.asm

$(ROM_ACIA_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,,ACIA)

$(ROM_SIO_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DUART_SIO,SIO)

$(ROM_SIO_SB_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DUART_SIO_SB,SIO-SB)

$(ROM_Z180_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DUART_Z180,Z180)

$(ROM_SCC_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DUART_SCC,SCC)

$(ROM_SCC_BUB_32K_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DUART_SCC -DROM_32K,SCC-BUB-32K)

$(ROM_ACIA_32K_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DROM_32K,ACIA-32K)

$(ROM_FDC_IMAGE): $(ROM_DEPS)
	$(call build_rom_variant,-DBLKDEV_FDC,ACIA-FDC)

# ============================================================
# 512KB testing ROM image (16KB ROM + fables disk at offset 32KB)
# Only ACIA variant; other variants are production-only.
# FDC testing image is built on demand for FDC tests.
# ============================================================

$(ROM_ACIA_512K_IMAGE): $(ROM_ACIA_IMAGE) | $(ROM_DIR)
	$(call build_512k,$(ROM_ACIA_IMAGE),$(FABLES_IMG),ACIA)

$(ROM_FDC_512K_IMAGE): $(ROM_FDC_IMAGE) | $(ROM_DIR)
	$(call build_512k,$(ROM_FDC_IMAGE),$(FABLES_IMG),ACIA-FDC)

# ============================================================
# Production 512KB ROM images (16KB ROM + production disk)
# ============================================================

$(PROD_ACIA_512K_IMAGE): $(ROM_ACIA_IMAGE) $(PROD_IMG) | $(ROM_DIR)
	$(call build_512k,$(ROM_ACIA_IMAGE),$(PROD_IMG),prod-ACIA)

$(PROD_SIO_512K_IMAGE): $(ROM_SIO_IMAGE) $(PROD_IMG) | $(ROM_DIR)
	$(call build_512k,$(ROM_SIO_IMAGE),$(PROD_IMG),prod-SIO)

$(PROD_SIO_SB_512K_IMAGE): $(ROM_SIO_SB_IMAGE) $(PROD_IMG) | $(ROM_DIR)
	$(call build_512k,$(ROM_SIO_SB_IMAGE),$(PROD_IMG),prod-SIO-SB)

$(PROD_Z180_512K_IMAGE): $(ROM_Z180_IMAGE) $(PROD_IMG) | $(ROM_DIR)
	$(call build_512k,$(ROM_Z180_IMAGE),$(PROD_IMG),prod-Z180)

$(PROD_SCC_512K_IMAGE): $(ROM_SCC_IMAGE) $(PROD_IMG) | $(ROM_DIR)
	$(call build_512k,$(ROM_SCC_IMAGE),$(PROD_IMG),prod-SCC)

$(PROD_FDC_512K_IMAGE): $(ROM_FDC_IMAGE) $(PROD_IMG) | $(ROM_DIR)
	$(call build_512k,$(ROM_FDC_IMAGE),$(PROD_IMG),prod-ACIA-FDC)

$(PROD_SCC_BUB_32K_IMAGE): $(ROM_SCC_BUB_32K_IMAGE) $(TINY_IMG) | $(ROM_DIR)
	$(call build_32k_rom,$(ROM_SCC_BUB_32K_IMAGE),$(TINY_IMG),prod-SCC-BUB-32K)

$(PROD_SCC_BUB_32K_BOTHBANK_IMAGE): $(PROD_SCC_BUB_32K_IMAGE) | $(ROM_DIR)
	# For programming a W27C512, duplicate the 32KB image
	cat $(PROD_SCC_BUB_32K_IMAGE) $(PROD_SCC_BUB_32K_IMAGE) > $(PROD_SCC_BUB_32K_BOTHBANK_IMAGE)

$(PROD_ACIA_32K_IMAGE): $(ROM_ACIA_32K_IMAGE) $(TINY_IMG) | $(ROM_DIR)
	$(call build_32k_rom,$(ROM_ACIA_32K_IMAGE),$(TINY_IMG),prod-ACIA-32K)

$(PROD_ACIA_32K_BOTHBANK_IMAGE): $(PROD_ACIA_32K_IMAGE) | $(ROM_DIR)
	# For programming a W27C512, duplicate the 32KB image
	cat $(PROD_ACIA_32K_IMAGE) $(PROD_ACIA_32K_IMAGE) > $(PROD_ACIA_32K_BOTHBANK_IMAGE)

# ============================================================
# Disk image management
# ============================================================

update-images:
	$(MAKE) -C tools
	$(MAKE) -C images clean all
	cp images/testing.img tests/testdata/test_base.img
	cp images/testing-native.img tests/testdata/test_native.img
	cp images/testing-3rdparty.img tests/testdata/test_3rdparty.img
	cp images/testing-extensions.img tests/testdata/test_extensions.img
	cp images/fables.img tests/testdata/fables_base.img
	cp images/production.img tests/testdata/production_base.img
	cp images/tiny.img tests/testdata/tiny_base.img

# ============================================================
# Emulator run targets
# ============================================================

# Run emulator macro: $(call run_emulator,ROM_IMAGE,CF_IMAGE,SERIAL_TYPE)
# Uses TEST_EMULATOR to select emulator: gocpusim (default) or rc2014
# SERIAL_TYPE is mandatory: "acia", "sio", "asci", or "scc"
# gocpusim uses: -s acia / -s sio / -s sio_sb / -s asci / -s scc / -s scc_sb
# rc2014 uses:   -a (ACIA) / -s (SIO, no argument)
define run_emulator
	@if [ "$(TEST_EMULATOR)" = "gocpusim" ]; then \
		echo $(EMULATOR_GOCPUSIM) -f $(1) --cf-image $(2) --cf-offset 1024 -s $(3); \
		$(EMULATOR_GOCPUSIM) -f $(1) --cf-image $(2) --cf-offset 1024 -s $(3); \
	elif [ "$(3)" = "asci" ]; then \
		echo "Error: Z180 ASCI is not supported by the rc2014 emulator" >&2; exit 1; \
	elif [ "$(3)" = "scc" ]; then \
		echo "Error: SCC is not supported by the rc2014 emulator" >&2; exit 1; \
	elif [ "$(3)" = "sio" ]; then \
		$(EMULATOR_RC2014) -s -r $(1) -m z80 -b -i $(2) -H; \
	elif [ "$(3)" = "acia" ]; then \
		$(EMULATOR_RC2014) -a -r $(1) -m z80 -b -i $(2) -H; \
	else \
		echo "Error: unknown serial type '$(3)'" >&2; exit 1; \
	fi
endef

run-testing: $(ROM_ACIA_512K_IMAGE)
	$(call run_emulator,$(ROM_ACIA_512K_IMAGE),$(CF_IMAGE),acia)

run-native: $(ROM_ACIA_512K_IMAGE)
	$(call run_emulator,$(ROM_ACIA_512K_IMAGE),images/testing-native.img,acia)

# IPS configurable: make run-native-throttled IPS=1000000
IPS ?= 2000000
run-native-throttled: $(ROM_ACIA_512K_IMAGE)
	$(EMULATOR_GOCPUSIM) -f $(ROM_ACIA_512K_IMAGE) --cf-image images/testing-native.img --cf-offset 1024 -s acia --ips $(IPS)

run-3rdparty: $(ROM_ACIA_512K_IMAGE)
	$(call run_emulator,$(ROM_ACIA_512K_IMAGE),images/testing-3rdparty.img,acia)

run-extensions: $(ROM_ACIA_512K_IMAGE)
	$(call run_emulator,$(ROM_ACIA_512K_IMAGE),images/testing-extensions.img,acia)

run-fables: $(ROM_ACIA_512K_IMAGE)
	$(call run_emulator,$(ROM_ACIA_512K_IMAGE),images/fables.img,acia)

run-production: $(PROD_ACIA_512K_IMAGE)
	$(call run_emulator,$(PROD_ACIA_512K_IMAGE),$(CF_IMAGE),acia)

run-production-sio: $(PROD_SIO_512K_IMAGE)
	$(call run_emulator,$(PROD_SIO_512K_IMAGE),$(CF_IMAGE),sio)

run-production-sio-sb: $(PROD_SIO_SB_512K_IMAGE)
	$(call run_emulator,$(PROD_SIO_SB_512K_IMAGE),$(CF_IMAGE),sio_sb)

run-production-z180: $(PROD_Z180_512K_IMAGE)
	$(call run_emulator,$(PROD_Z180_512K_IMAGE),$(CF_IMAGE),asci)

run-production-scc: $(PROD_SCC_512K_IMAGE)
	$(call run_emulator,$(PROD_SCC_512K_IMAGE),$(CF_IMAGE),scc_sb)

run-production-scc-bub-32k: $(PROD_SCC_BUB_32K_IMAGE)
	$(EMULATOR_GOCPUSIM) -f $(PROD_SCC_BUB_32K_IMAGE) --cf-image $(CF_IMAGE) --cf-offset 1024 -s scc_sb --fixed-32k

run-production-acia-32k: $(PROD_ACIA_32K_IMAGE)
	$(EMULATOR_GOCPUSIM) -f $(PROD_ACIA_32K_IMAGE) --cf-image $(CF_IMAGE) --cf-offset 1024 -s acia --fixed-32k

run-production-fdc: $(PROD_FDC_512K_IMAGE)
	@test -f $(FDC_IMAGE) || $(DD) if=/dev/zero of=$(FDC_IMAGE) bs=512 count=2880 2>/dev/null
	$(EMULATOR_GOCPUSIM) -f $(PROD_FDC_512K_IMAGE) --cf-image $(CF_IMAGE) --cf-offset 1024 --fdc-image $(FDC_IMAGE) -s acia

run-fdc: $(ROM_FDC_512K_IMAGE)
	@test -f $(FDC_IMAGE) || $(DD) if=/dev/zero of=$(FDC_IMAGE) bs=512 count=2880 2>/dev/null
	$(EMULATOR_GOCPUSIM) -f $(ROM_FDC_512K_IMAGE) --cf-image $(CF_IMAGE) --cf-offset 1024 --fdc-image $(FDC_IMAGE) -s acia

# ============================================================
# Test runner
# ============================================================

# $(call run_tests,TEST_LIST,ROM_IMAGE,LABEL[,BASE_IMAGE])
# Safety: output is capped at 1MB and emulator is killed after 120s
# BASE_IMAGE defaults to TEST_BASE_IMG if not provided
TEST_TIMEOUT ?= 120
TEST_MAX_OUTPUT ?= 1048576
define run_tests
	@mkdir -p testout
	@FAILED=""; \
	for t in $(1); do \
		echo "Running $(3): $$t..."; \
		cp $(or $(4),$(TEST_BASE_IMG)) $(TEST_WORK_IMG); \
		if [ -f tests/testdata/$$t.setup.sh ]; then \
			bash tests/testdata/$$t.setup.sh $(TEST_WORK_IMG); \
		fi; \
		if [ "$(TEST_EMULATOR)" = "gocpusim" ]; then \
			bash -o pipefail -c "timeout $(TEST_TIMEOUT) $(EMULATOR_GOCPUSIM) -f $(2) --cf-image $(TEST_WORK_IMG) --cf-offset 1024 -t tests/$$t.txt | head -c $(TEST_MAX_OUTPUT) > testout/$$t.out"; \
		else \
			bash -o pipefail -c "timeout $(TEST_TIMEOUT) $(EMULATOR_RC2014) -a -r $(2) -m z80 -f -b -i $(TEST_WORK_IMG) -t tests/$$t.txt -Q -H | head -c $(TEST_MAX_OUTPUT) > testout/$$t.out"; \
		fi; \
		EMU_RC=$$?; \
		if [ $$EMU_RC -eq 124 ]; then \
			echo "  ERROR: $$t TIMED OUT."; \
			FAILED="$$FAILED $$t"; \
		elif [ $$EMU_RC -ne 0 ] && [ $$EMU_RC -ne 141 ]; then \
			echo "  ERROR: $$t emulator failed (exit $$EMU_RC)."; \
			FAILED="$$FAILED $$t"; \
		elif sed 's/built on [0-9]*-[0-9]*-[0-9]*/built on DATE/' testgood/$$t.out > testout/$$t.expected && sed 's/built on [0-9]*-[0-9]*-[0-9]*/built on DATE/' testout/$$t.out > testout/$$t.actual && diff -u testout/$$t.expected testout/$$t.actual; then \
			echo "  $$t passed."; \
		else \
			echo "  ERROR: $$t FAILED."; \
			FAILED="$$FAILED $$t"; \
		fi; \
	done; \
	if [ -n "$$FAILED" ]; then \
		echo "FAILED $(3):$$FAILED"; \
		exit 1; \
	else \
		echo "All $(3) passed."; \
	fi
endef

# $(call run_fdc_tests,TEST_LIST,ROM_IMAGE,LABEL)
# Like run_tests but creates a blank 1.44MB floppy image and passes --fdc-image
# FDC emulation is only supported by gocpusim; skipped for other emulators
define run_fdc_tests
	@if [ "$(TEST_EMULATOR)" != "gocpusim" ]; then \
		echo "Skipping $(3) (FDC requires gocpusim, TEST_EMULATOR=$(TEST_EMULATOR))"; \
		exit 0; \
	fi; \
	mkdir -p testout; \
	FAILED=""; \
	for t in $(1); do \
		echo "Running $(3): $$t..."; \
		cp $(TEST_BASE_IMG) $(TEST_WORK_IMG); \
		$(DD) if=/dev/zero of=$(TEST_FDC_WORK_IMG) bs=512 count=2880 2>/dev/null; \
		bash -o pipefail -c "timeout $(TEST_TIMEOUT) $(EMULATOR_GOCPUSIM) -f $(2) --cf-image $(TEST_WORK_IMG) --cf-offset 1024 --fdc-image $(TEST_FDC_WORK_IMG) -t tests/$$t.txt | head -c $(TEST_MAX_OUTPUT) > testout/$$t.out"; \
		EMU_RC=$$?; \
		if [ $$EMU_RC -eq 124 ]; then \
			echo "  ERROR: $$t TIMED OUT."; \
			FAILED="$$FAILED $$t"; \
		elif [ $$EMU_RC -ne 0 ] && [ $$EMU_RC -ne 141 ]; then \
			echo "  ERROR: $$t emulator failed (exit $$EMU_RC)."; \
			FAILED="$$FAILED $$t"; \
		elif sed 's/built on [0-9]*-[0-9]*-[0-9]*/built on DATE/' testgood/$$t.out > testout/$$t.expected && sed 's/built on [0-9]*-[0-9]*-[0-9]*/built on DATE/' testout/$$t.out > testout/$$t.actual && diff -u testout/$$t.expected testout/$$t.actual; then \
			echo "  $$t passed."; \
		else \
			echo "  ERROR: $$t FAILED."; \
			FAILED="$$FAILED $$t"; \
		fi; \
	done; \
	if [ -n "$$FAILED" ]; then \
		echo "FAILED $(3):$$FAILED"; \
		exit 1; \
	else \
		echo "All $(3) passed."; \
	fi
endef

test: test-quick test-torture test-prod test-exec-standalone

# Run a single test: make test-one T=basic [I=tests/testdata/test_native.img]
test-one: $(ROM_ACIA_512K_IMAGE)
	$(call run_tests,$(T),$(or $(R),$(ROM_ACIA_512K_IMAGE)),test,$(I))

test-quick: $(ROM_ACIA_512K_IMAGE) $(ROM_FDC_512K_IMAGE)
	$(call run_tests,$(TESTS_QUICK),$(ROM_ACIA_512K_IMAGE),quick test)
	$(call run_tests,$(TESTS_QUICK_NATIVE),$(ROM_ACIA_512K_IMAGE),quick-native test,$(TEST_NATIVE_IMG))
	$(call run_tests,$(TESTS_QUICK_3RDPARTY),$(ROM_ACIA_512K_IMAGE),quick-3rdparty test,$(TEST_3RDPARTY_IMG))
	$(call run_tests,$(TESTS_QUICK_EXT),$(ROM_ACIA_512K_IMAGE),quick-ext test,$(TEST_EXT_IMG))
	$(call run_fdc_tests,$(TESTS_QUICK_FDC),$(ROM_FDC_512K_IMAGE),quick-fdc test)

test-torture: $(ROM_ACIA_512K_IMAGE)
	$(call run_tests,$(TESTS_TORTURE),$(ROM_ACIA_512K_IMAGE),torture test)
	$(call run_tests,$(TESTS_TORTURE_NATIVE),$(ROM_ACIA_512K_IMAGE),torture-native test,$(TEST_NATIVE_IMG))
	$(call run_tests,$(TESTS_TORTURE_3RDPARTY),$(ROM_ACIA_512K_IMAGE),torture-3rdparty test,$(TEST_3RDPARTY_IMG))
	$(call run_tests,$(TESTS_TORTURE_EXT),$(ROM_ACIA_512K_IMAGE),torture-ext test,$(TEST_EXT_IMG))

test-fdc: $(ROM_FDC_512K_IMAGE)
	$(call run_fdc_tests,$(TESTS_QUICK_FDC),$(ROM_FDC_512K_IMAGE),fdc test)

test-prod: $(PROD_ACIA_512K_IMAGE)
	$(call run_tests,$(PROD_TESTS),$(PROD_ACIA_512K_IMAGE),prod test)

test-exec-standalone: $(BUILD) $(BUILD_INFO)
	$(ASM) $(ASM_FLAGS) -o=$(BUILD)/exec-standalone.bin src/exec-standalone.asm

# ============================================================
# Utilities
# ============================================================

size: $(ALL_ROMS)
	@for entry in "$(ROM_ACIA_IMAGE):$(ROM_SIZE):ACIA" "$(ROM_SIO_IMAGE):$(ROM_SIZE):SIO" "$(ROM_SIO_SB_IMAGE):$(ROM_SIZE):SIO-SB" "$(ROM_Z180_IMAGE):$(ROM_SIZE):Z180" "$(ROM_SCC_IMAGE):$(ROM_SIZE):SCC" "$(ROM_FDC_IMAGE):$(ROM_SIZE):ACIA-FDC" "$(ROM_SCC_BUB_32K_IMAGE):$(ROM_SIZE):SCC-BUB-32K" "$(ROM_ACIA_32K_IMAGE):$(ROM_SIZE):ACIA-32K"; do \
	    binfile=$$(echo $$entry | cut -d: -f1); \
	    limit=$$(echo $$entry  | cut -d: -f2); \
	    tag=$$(echo $$entry    | cut -d: -f3); \
	    used=$$(wc -c < $$binfile); \
	    free=$$((limit - used)); \
	    printf "  %-12s %5d / %d bytes used,  %4d bytes free\n" $$tag $$used $$limit $$free; \
	done

tools:
	$(MAKE) -C tools

rebuild:
	$(MAKE) -C apps clean
	$(MAKE) -C apps
	$(MAKE) update-images
	$(MAKE) clean
	$(MAKE)

clean:
	$(RM) -r $(BUILD)
	find src -name "*.o" -delete
	find src -name "*.lst" -delete
	find src -name "*.lis" -delete
	#$(MAKE) -C tools clean

FORCE:
