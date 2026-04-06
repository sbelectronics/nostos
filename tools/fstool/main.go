package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ============================================================
// Constants
// ============================================================

const (
	BlockSize    = 512
	MaxSpans     = 126
	MaxNameLen   = 16 // max chars (excluding null)
	DirEntrySize = 32
	DirsPerBlock = BlockSize / DirEntrySize // 16

	// Filesystem header offsets
	SigOffset            = 0x00
	NumBlocksOffset      = 0x04
	RootInodeOffset      = 0x06
	BitmapStartOffset    = 0x08 // direct block number where bitmap data begins
	SectorsPerTrackOffset = 0x0A
	TracksOffset         = 0x0B
	HeadsOffset          = 0x0C

	// Inode layout
	InodeSpanCountOffset = 0x00
	InodeNextOffset      = 0x02
	InodeSpansStart      = 0x08

	// Directory entry offsets
	DirTypeOffset  = 0x00
	DirNameOffset  = 0x01
	DirSizeOffset  = 0x12
	DirMTimeOffset = 0x16
	DirAttrOffset  = 0x1A
	DirOwnerOffset = 0x1B
	DirInodeOffset = 0x1C
	DirUnusedOffset = 0x1E

	// Type bits
	TypeUsed = 0x80
	TypeDir  = 0x40

	// Well-known block numbers
	HeaderBlock     = 0
	RootInodeBlock  = 1
	BitmapDataStart = 2 // bitmap data starts immediately after root inode

	// Each bitmap data block holds one bit per filesystem block.
	BitsPerBitmapBlock = BlockSize * 8 // 4096
)

var FSSig = [4]byte{0x53, 0x43, 0x4F, 0x54}

// ============================================================
// On-disk structures
// ============================================================

type FSHeader struct {
	Sig          [4]byte
	NumBlocks    uint16
	RootInode    uint16
	BitmapStart  uint16 // block number where bitmap data begins (no inode)
	SectorsTrack uint8
	Tracks       uint8
	Heads        uint8
}

type Span struct {
	First uint16
	Last  uint16
}

type Inode struct {
	SpanCount uint8
	Reserved1 uint8
	NextInode uint16
	Reserved2 [4]byte
	Spans     [MaxSpans]Span
}

type DirEntry struct {
	Type  uint8
	Name  [17]byte
	Size  uint32
	MTime uint32
	Attrs uint8
	Owner uint8
	Inode uint16
	Unused uint16
}

// ============================================================
// Filesystem image handle
// ============================================================

const HeaderSkip = 1024 // bytes to skip for EtchedPixels CF image header

type FS struct {
	f      *os.File
	header FSHeader
	offset int64 // byte offset into file where block 0 begins
}

func openFS(path string, offset int64) (*FS, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	fs := &FS{f: f, offset: offset}
	if err := fs.readHeader(); err != nil {
		f.Close()
		return nil, fmt.Errorf("invalid filesystem: %w", err)
	}
	return fs, nil
}

func (fs *FS) close() {
	fs.f.Close()
}

// ============================================================
// Block I/O
// ============================================================

func (fs *FS) readBlock(block uint16, buf []byte) error {
	_, err := fs.f.ReadAt(buf[:BlockSize], fs.offset+int64(block)*BlockSize)
	return err
}

func (fs *FS) writeBlock(block uint16, buf []byte) error {
	_, err := fs.f.WriteAt(buf[:BlockSize], fs.offset+int64(block)*BlockSize)
	return err
}

// ============================================================
// Header
// ============================================================

func (fs *FS) readHeader() error {
	buf := make([]byte, BlockSize)
	if err := fs.readBlock(HeaderBlock, buf); err != nil {
		return err
	}
	copy(fs.header.Sig[:], buf[SigOffset:SigOffset+4])
	if fs.header.Sig != FSSig {
		return fmt.Errorf("bad signature: %02X %02X %02X %02X",
			fs.header.Sig[0], fs.header.Sig[1], fs.header.Sig[2], fs.header.Sig[3])
	}
	fs.header.NumBlocks = binary.LittleEndian.Uint16(buf[NumBlocksOffset:])
	fs.header.RootInode = binary.LittleEndian.Uint16(buf[RootInodeOffset:])
	fs.header.BitmapStart = binary.LittleEndian.Uint16(buf[BitmapStartOffset:])
	fs.header.SectorsTrack = buf[SectorsPerTrackOffset]
	fs.header.Tracks = buf[TracksOffset]
	fs.header.Heads = buf[HeadsOffset]
	return nil
}

func (fs *FS) writeHeader() error {
	buf := make([]byte, BlockSize)
	copy(buf[SigOffset:], fs.header.Sig[:])
	binary.LittleEndian.PutUint16(buf[NumBlocksOffset:], fs.header.NumBlocks)
	binary.LittleEndian.PutUint16(buf[RootInodeOffset:], fs.header.RootInode)
	binary.LittleEndian.PutUint16(buf[BitmapStartOffset:], fs.header.BitmapStart)
	buf[SectorsPerTrackOffset] = fs.header.SectorsTrack
	buf[TracksOffset] = fs.header.Tracks
	buf[HeadsOffset] = fs.header.Heads
	return fs.writeBlock(HeaderBlock, buf)
}

// ============================================================
// Inode I/O
// ============================================================

func (fs *FS) readInode(block uint16) (*Inode, error) {
	buf := make([]byte, BlockSize)
	if err := fs.readBlock(block, buf); err != nil {
		return nil, err
	}
	in := &Inode{}
	in.SpanCount = buf[InodeSpanCountOffset]
	in.Reserved1 = buf[0x01]
	in.NextInode = binary.LittleEndian.Uint16(buf[InodeNextOffset:])
	copy(in.Reserved2[:], buf[0x04:0x08])
	for i := 0; i < MaxSpans; i++ {
		off := InodeSpansStart + i*4
		in.Spans[i].First = binary.LittleEndian.Uint16(buf[off:])
		in.Spans[i].Last = binary.LittleEndian.Uint16(buf[off+2:])
	}
	return in, nil
}

func (fs *FS) writeInode(block uint16, in *Inode) error {
	buf := make([]byte, BlockSize)
	buf[InodeSpanCountOffset] = in.SpanCount
	buf[0x01] = in.Reserved1
	binary.LittleEndian.PutUint16(buf[InodeNextOffset:], in.NextInode)
	copy(buf[0x04:0x08], in.Reserved2[:])
	for i := 0; i < MaxSpans; i++ {
		off := InodeSpansStart + i*4
		binary.LittleEndian.PutUint16(buf[off:], in.Spans[i].First)
		binary.LittleEndian.PutUint16(buf[off+2:], in.Spans[i].Last)
	}
	return fs.writeBlock(block, buf)
}

// inodeBlocks returns all block numbers covered by an inode.
func (fs *FS) inodeBlocks(in *Inode) []uint16 {
	var blocks []uint16
	for i := 0; i < int(in.SpanCount); i++ {
		for b := in.Spans[i].First; b <= in.Spans[i].Last; b++ {
			blocks = append(blocks, b)
		}
	}
	return blocks
}

// ============================================================
// Free space bitmap
// ============================================================

// bitmapBlockCount returns the number of bitmap data blocks for this filesystem.
func (fs *FS) bitmapBlockCount() int {
	return (int(fs.header.NumBlocks) + BitsPerBitmapBlock - 1) / BitsPerBitmapBlock
}

// readBitmap returns the raw bitmap bytes.
func (fs *FS) readBitmap() ([]byte, error) {
	n := fs.bitmapBlockCount()
	bitmapBytes := make([]byte, n*BlockSize)
	buf := make([]byte, BlockSize)
	for i := 0; i < n; i++ {
		if err := fs.readBlock(fs.header.BitmapStart+uint16(i), buf); err != nil {
			return nil, err
		}
		copy(bitmapBytes[i*BlockSize:], buf)
	}
	return bitmapBytes, nil
}

func (fs *FS) writeBitmap(bitmapBytes []byte) error {
	n := fs.bitmapBlockCount()
	if len(bitmapBytes) < n*BlockSize {
		return fmt.Errorf("bitmap buffer too small: need %d bytes, got %d", n*BlockSize, len(bitmapBytes))
	}
	buf := make([]byte, BlockSize)
	for i := 0; i < n; i++ {
		copy(buf, bitmapBytes[i*BlockSize:(i+1)*BlockSize])
		if err := fs.writeBlock(fs.header.BitmapStart+uint16(i), buf); err != nil {
			return err
		}
	}
	return nil
}

func bitmapGet(bitmap []byte, block uint16) bool {
	return bitmap[block/8]&(1<<(block%8)) != 0
}

func bitmapSet(bitmap []byte, block uint16, free bool) {
	if free {
		bitmap[block/8] |= 1 << (block % 8)
	} else {
		bitmap[block/8] &^= 1 << (block % 8)
	}
}

// allocBlock finds and marks the first free block (excluding blocks 0-2).
func (fs *FS) allocBlock(bitmap []byte) (uint16, bool) {
	for b := uint16(3); b < fs.header.NumBlocks; b++ {
		if bitmapGet(bitmap, b) {
			bitmapSet(bitmap, b, false)
			return b, true
		}
	}
	return 0, false
}

// freeCount returns the number of free blocks.
func freeCount(bitmap []byte, numBlocks uint16) int {
	count := 0
	for b := uint16(0); b < numBlocks; b++ {
		if bitmapGet(bitmap, b) {
			count++
		}
	}
	return count
}

// ============================================================
// Directory entry I/O
// ============================================================

func parseDirEntry(buf []byte, off int) DirEntry {
	var e DirEntry
	e.Type = buf[off+DirTypeOffset]
	copy(e.Name[:], buf[off+DirNameOffset:off+DirNameOffset+17])
	e.Size = binary.LittleEndian.Uint32(buf[off+DirSizeOffset:])
	e.MTime = binary.LittleEndian.Uint32(buf[off+DirMTimeOffset:])
	e.Attrs = buf[off+DirAttrOffset]
	e.Owner = buf[off+DirOwnerOffset]
	e.Inode = binary.LittleEndian.Uint16(buf[off+DirInodeOffset:])
	e.Unused = binary.LittleEndian.Uint16(buf[off+DirUnusedOffset:])
	return e
}

func writeDirEntry(buf []byte, off int, e DirEntry) {
	buf[off+DirTypeOffset] = e.Type
	copy(buf[off+DirNameOffset:], e.Name[:])
	binary.LittleEndian.PutUint32(buf[off+DirSizeOffset:], e.Size)
	binary.LittleEndian.PutUint32(buf[off+DirMTimeOffset:], e.MTime)
	buf[off+DirAttrOffset] = e.Attrs
	buf[off+DirOwnerOffset] = e.Owner
	binary.LittleEndian.PutUint16(buf[off+DirInodeOffset:], e.Inode)
	binary.LittleEndian.PutUint16(buf[off+DirUnusedOffset:], e.Unused)
}

func entryName(e DirEntry) string {
	name := e.Name[:]
	for i, c := range name {
		if c == 0 {
			return string(name[:i])
		}
	}
	return string(name)
}

// readDirEntries reads all directory entries from a directory inode.
func (fs *FS) readDirEntries(dirInode uint16) ([]DirEntry, []uint16, error) {
	in, err := fs.readInode(dirInode)
	if err != nil {
		return nil, nil, err
	}
	blocks := fs.inodeBlocks(in)
	var entries []DirEntry
	buf := make([]byte, BlockSize)
	for _, b := range blocks {
		if err := fs.readBlock(b, buf); err != nil {
			return nil, nil, err
		}
		for i := 0; i < DirsPerBlock; i++ {
			e := parseDirEntry(buf, i*DirEntrySize)
			entries = append(entries, e)
		}
	}
	return entries, blocks, nil
}

// expandDir allocates a new data block for a directory inode, updates the inode
// on disk, writes the updated bitmap, and returns extended entries and blocks slices.
// bitmap must reflect all prior allocations; it will be updated and re-written.
func (fs *FS) expandDir(dirInodeBlock uint16, entries []DirEntry, blocks []uint16, bitmap []byte) ([]DirEntry, []uint16, error) {
	newBlock, ok := fs.allocBlock(bitmap)
	if !ok {
		return nil, nil, fmt.Errorf("no free blocks to expand directory")
	}

	// Zero the new block on disk
	zeroBuf := make([]byte, BlockSize)
	if err := fs.writeBlock(newBlock, zeroBuf); err != nil {
		return nil, nil, err
	}

	// Read the directory inode and extend its span list
	in, err := fs.readInode(dirInodeBlock)
	if err != nil {
		return nil, nil, err
	}
	if in.SpanCount > 0 && in.Spans[in.SpanCount-1].Last+1 == newBlock {
		in.Spans[in.SpanCount-1].Last = newBlock
	} else {
		if int(in.SpanCount) >= MaxSpans {
			return nil, nil, fmt.Errorf("directory inode is full (no room for more spans)")
		}
		in.Spans[in.SpanCount] = Span{First: newBlock, Last: newBlock}
		in.SpanCount++
	}
	if err := fs.writeInode(dirInodeBlock, in); err != nil {
		return nil, nil, err
	}

	// Write updated bitmap (marks newBlock as used)
	if err := fs.writeBitmap(bitmap); err != nil {
		return nil, nil, err
	}

	// Extend the in-memory slices with the new empty block's slots
	blocks = append(blocks, newBlock)
	for i := 0; i < DirsPerBlock; i++ {
		entries = append(entries, DirEntry{})
	}
	return entries, blocks, nil
}

// writeDirEntries writes directory entries back to the given blocks.
func (fs *FS) writeDirEntries(entries []DirEntry, blocks []uint16) error {
	buf := make([]byte, BlockSize)
	for bi, b := range blocks {
		// Zero the block first
		for i := range buf {
			buf[i] = 0
		}
		for i := 0; i < DirsPerBlock; i++ {
			idx := bi*DirsPerBlock + i
			if idx < len(entries) {
				writeDirEntry(buf, i*DirEntrySize, entries[idx])
			}
		}
		if err := fs.writeBlock(b, buf); err != nil {
			return err
		}
	}
	return nil
}

// findDirEntry finds an entry by name (case-insensitive) in a directory inode.
// Returns the entry and its index within the entries slice.
func (fs *FS) findDirEntry(dirInode uint16, name string) (*DirEntry, int, []DirEntry, []uint16, error) {
	upper := strings.ToUpper(name)
	entries, blocks, err := fs.readDirEntries(dirInode)
	if err != nil {
		return nil, -1, nil, nil, err
	}
	for i, e := range entries {
		if e.Type&TypeUsed != 0 && strings.ToUpper(entryName(e)) == upper {
			ec := e
			return &ec, i, entries, blocks, nil
		}
	}
	return nil, -1, entries, blocks, nil
}

// parsePath splits a path like "dir/file" or "file" into (dir, file).
// dir is empty string for root.
func parsePath(path string) (dir, name string) {
	path = strings.TrimLeft(path, "/")
	parts := strings.SplitN(path, "/", 2)
	if len(parts) == 1 {
		return "", parts[0]
	}
	return parts[0], parts[1]
}

// resolveDirInode returns the inode block for the directory portion of path.
// If dir is empty, returns RootInodeBlock.
func (fs *FS) resolveDirInode(dir string) (uint16, error) {
	if dir == "" {
		return RootInodeBlock, nil
	}
	e, _, _, _, err := fs.findDirEntry(RootInodeBlock, dir)
	if err != nil {
		return 0, err
	}
	if e == nil {
		return 0, fmt.Errorf("directory not found: %s", dir)
	}
	if e.Type&TypeDir == 0 {
		return 0, fmt.Errorf("%s is not a directory", dir)
	}
	return e.Inode, nil
}

// ============================================================
// Commands
// ============================================================

func cmdFormat(imagePath string, args []string, offset int64) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: fstool <image> format <blocks>")
	}
	var numBlocks int
	if _, err := fmt.Sscanf(args[0], "%d", &numBlocks); err != nil || numBlocks < 1 {
		return fmt.Errorf("blocks must be a positive number")
	}
	if numBlocks > BitsPerBitmapBlock {
		return fmt.Errorf("blocks must be <= %d (single bitmap block limit)", BitsPerBitmapBlock)
	}
	// Minimum: header + root inode + bitmap block + root dir block + 1 free block = 5
	if numBlocks < 5 {
		return fmt.Errorf("blocks must be >= 5 to have at least one free block")
	}

	// Check image is large enough
	info, err := os.Stat(imagePath)
	if err != nil {
		return err
	}
	required := offset + int64(numBlocks)*BlockSize
	if info.Size() < required {
		return fmt.Errorf("image file is too small: need %d bytes, have %d", required, info.Size())
	}

	f, err := os.OpenFile(imagePath, os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()

	zero := make([]byte, BlockSize)

	writeBlock := func(block int, buf []byte) error {
		_, err := f.WriteAt(buf, offset+int64(block)*BlockSize)
		return err
	}

	// Calculate how many blocks the bitmap needs.
	bitmapBlocks := (numBlocks + BitsPerBitmapBlock - 1) / BitsPerBitmapBlock
	// Layout: 0=header, 1=root inode, 2..2+bitmapBlocks-1=bitmap data, then root dir data.
	bitmapStart := BitmapDataStart // = 2
	rootDirBlock := bitmapStart + bitmapBlocks

	// --- Block 0: filesystem header ---
	hbuf := make([]byte, BlockSize)
	copy(hbuf[SigOffset:], FSSig[:])
	binary.LittleEndian.PutUint16(hbuf[NumBlocksOffset:], uint16(numBlocks))
	binary.LittleEndian.PutUint16(hbuf[RootInodeOffset:], RootInodeBlock)
	binary.LittleEndian.PutUint16(hbuf[BitmapStartOffset:], uint16(bitmapStart))
	if err := writeBlock(HeaderBlock, hbuf); err != nil {
		return err
	}

	// --- Block 1: root directory inode ---
	ribuf := make([]byte, BlockSize)
	ribuf[InodeSpanCountOffset] = 1
	binary.LittleEndian.PutUint16(ribuf[InodeNextOffset:], 0)
	binary.LittleEndian.PutUint16(ribuf[InodeSpansStart:], uint16(rootDirBlock))
	binary.LittleEndian.PutUint16(ribuf[InodeSpansStart+2:], uint16(rootDirBlock))
	if err := writeBlock(RootInodeBlock, ribuf); err != nil {
		return err
	}

	// --- Blocks 2+: bitmap data ---
	// Initially all bits = 1 (free), then mark used blocks as 0.
	bitmapData := make([]byte, bitmapBlocks*BlockSize)
	for i := range bitmapData {
		bitmapData[i] = 0xFF
	}
	// Mark blocks 0 through rootDirBlock as used (header, root inode, bitmap, root dir data).
	usedUpTo := rootDirBlock + 1
	for b := 0; b < usedUpTo; b++ {
		bitmapData[b/8] &^= 1 << (b % 8)
	}
	// Mark blocks beyond numBlocks as used (they don't exist).
	for b := numBlocks; b < bitmapBlocks*BlockSize*8; b++ {
		bitmapData[b/8] &^= 1 << (b % 8)
	}
	for i := 0; i < bitmapBlocks; i++ {
		if err := writeBlock(bitmapStart+i, bitmapData[i*BlockSize:(i+1)*BlockSize]); err != nil {
			return err
		}
	}

	// --- Root dir data block (immediately after bitmap) ---
	if err := writeBlock(rootDirBlock, zero); err != nil {
		return err
	}

	fmt.Printf("Formatted %d-block filesystem.\n", numBlocks)
	return nil
}

func cmdInfo(fs *FS) error {
	bitmap, err := fs.readBitmap()
	if err != nil {
		return err
	}
	free := freeCount(bitmap, fs.header.NumBlocks)
	used := int(fs.header.NumBlocks) - free

	// Count files and directories in root
	rootEntries, _, err := fs.readDirEntries(RootInodeBlock)
	if err != nil {
		return err
	}
	numDirs, numFiles := 0, 0
	for _, e := range rootEntries {
		if e.Type&TypeUsed == 0 {
			continue
		}
		if e.Type&TypeDir != 0 {
			numDirs++
		} else {
			numFiles++
		}
	}

	fmt.Printf("NostOS Filesystem Image\n")
	fmt.Printf("  Blocks total:    %d\n", fs.header.NumBlocks)
	fmt.Printf("  Blocks used:     %d\n", used)
	fmt.Printf("  Blocks free:     %d\n", free)
	fmt.Printf("  Block size:      %d bytes\n", BlockSize)
	fmt.Printf("  Total size:      %d bytes\n", int(fs.header.NumBlocks)*BlockSize)
	fmt.Printf("  Root inode:      block %d\n", fs.header.RootInode)
	fmt.Printf("  Bitmap start:    block %d\n", fs.header.BitmapStart)
	fmt.Printf("  Directories:     %d\n", numDirs)
	fmt.Printf("  Files (root):    %d\n", numFiles)
	return nil
}

func cmdDir(fs *FS, args []string) error {
	path := ""
	if len(args) > 0 {
		path = args[0]
	}
	path = strings.TrimLeft(path, "/")

	var dirInode uint16
	var dirLabel string
	if path == "" {
		dirInode = RootInodeBlock
		dirLabel = "/"
	} else {
		// path could be a directory name
		e, _, _, _, err := fs.findDirEntry(RootInodeBlock, path)
		if err != nil {
			return err
		}
		if e == nil {
			return fmt.Errorf("not found: %s", path)
		}
		if e.Type&TypeDir == 0 {
			return fmt.Errorf("%s is not a directory", path)
		}
		dirInode = e.Inode
		dirLabel = path
	}

	entries, _, err := fs.readDirEntries(dirInode)
	if err != nil {
		return err
	}

	fmt.Printf("Directory of %s\n\n", dirLabel)
	fmt.Printf("%-17s %-5s %10s  %-10s  %s\n", "Name", "Type", "Size", "Modified", "Inode")
	fmt.Printf("%-17s %-5s %10s  %-10s  %s\n",
		strings.Repeat("-", 17), "-----", "----------", "----------", "-----")

	count := 0
	for _, e := range entries {
		if e.Type&TypeUsed == 0 {
			continue
		}
		typ := "FILE"
		if e.Type&TypeDir != 0 {
			typ = "DIR"
		}
		mtime := "-"
		if e.MTime != 0 {
			t := time.Unix(int64(e.MTime), 0)
			mtime = t.Format("2006-01-02")
		}
		name := entryName(e)
		fmt.Printf("%-17s %-5s %10d  %-10s  %d\n", name, typ, e.Size, mtime, e.Inode)
		count++
	}
	fmt.Printf("\n%d entries\n", count)
	return nil
}

func cmdMkdir(fs *FS, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: fstool <image> mkdir <dirname>")
	}
	dirname := strings.ToUpper(args[0])
	if strings.Contains(dirname, "/") {
		return fmt.Errorf("nested directories not supported")
	}
	if len(dirname) > MaxNameLen {
		return fmt.Errorf("name too long (max %d chars)", MaxNameLen)
	}

	// Check doesn't already exist
	existing, _, entries, blocks, err := fs.findDirEntry(RootInodeBlock, dirname)
	if err != nil {
		return err
	}
	if existing != nil {
		return fmt.Errorf("already exists: %s", dirname)
	}

	// Allocate a block for the new directory
	bitmap, err := fs.readBitmap()
	if err != nil {
		return err
	}
	newBlock, ok := fs.allocBlock(bitmap)
	if !ok {
		return fmt.Errorf("no free blocks")
	}

	// Allocate an inode block for the new directory
	inodeBlock, ok2 := fs.allocBlock(bitmap)
	if !ok2 {
		return fmt.Errorf("no free blocks for inode")
	}

	// Write directory data block (empty)
	zeroBuf := make([]byte, BlockSize)
	if err := fs.writeBlock(newBlock, zeroBuf); err != nil {
		return err
	}

	// Write new directory inode
	newInode := &Inode{SpanCount: 1}
	newInode.Spans[0] = Span{First: newBlock, Last: newBlock}
	if err := fs.writeInode(inodeBlock, newInode); err != nil {
		return err
	}

	// Write updated bitmap
	if err := fs.writeBitmap(bitmap); err != nil {
		return err
	}

	// Add directory entry to root
	var newEntry DirEntry
	newEntry.Type = TypeUsed | TypeDir
	copy(newEntry.Name[:], []byte(dirname))
	newEntry.Inode = inodeBlock

	// Find a free slot in root directory entries
	slotFound := false
	for i, e := range entries {
		if e.Type&TypeUsed == 0 {
			entries[i] = newEntry
			slotFound = true
			break
		}
	}
	if !slotFound {
		entries, blocks, err = fs.expandDir(RootInodeBlock, entries, blocks, bitmap)
		if err != nil {
			return err
		}
		for i, e := range entries {
			if e.Type&TypeUsed == 0 {
				entries[i] = newEntry
				slotFound = true
				break
			}
		}
		if !slotFound {
			return fmt.Errorf("could not find free slot after directory expansion")
		}
	}

	return fs.writeDirEntries(entries, blocks)
}

func cmdAdd(fs *FS, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: fstool <image> add <srcfile> <destpath>")
	}
	srcPath := args[0]
	destPath := args[1]

	// Read source file
	data, err := os.ReadFile(srcPath)
	if err != nil {
		return err
	}

	destDir, destName := parsePath(destPath)
	destName = strings.ToUpper(destName)
	if len(destName) > MaxNameLen {
		return fmt.Errorf("name too long (max %d chars)", MaxNameLen)
	}

	dirInode, err := fs.resolveDirInode(destDir)
	if err != nil {
		return err
	}

	// Check doesn't already exist
	existing, _, entries, blocks, err := fs.findDirEntry(dirInode, destName)
	if err != nil {
		return err
	}
	if existing != nil {
		return fmt.Errorf("already exists: %s", destName)
	}

	// Allocate blocks for file data
	bitmap, err := fs.readBitmap()
	if err != nil {
		return err
	}

	numDataBlocks := (len(data) + BlockSize - 1) / BlockSize
	if numDataBlocks == 0 {
		numDataBlocks = 1
	}

	// Allocate data blocks (try to get contiguous spans via first-fit)
	dataBlocks := make([]uint16, 0, numDataBlocks)
	for len(dataBlocks) < numDataBlocks {
		b, ok := fs.allocBlock(bitmap)
		if !ok {
			return fmt.Errorf("no free blocks")
		}
		dataBlocks = append(dataBlocks, b)
	}

	// Build spans
	spans := buildSpans(dataBlocks)
	if len(spans) > MaxSpans {
		return fmt.Errorf("file too fragmented (would need >%d spans)", MaxSpans)
	}

	// Allocate inode block
	inodeBlock, ok := fs.allocBlock(bitmap)
	if !ok {
		return fmt.Errorf("no free blocks for inode")
	}

	// Write data blocks
	fileBuf := make([]byte, BlockSize)
	for i, b := range dataBlocks {
		for j := range fileBuf {
			fileBuf[j] = 0
		}
		start := i * BlockSize
		end := start + BlockSize
		if end > len(data) {
			end = len(data)
		}
		copy(fileBuf, data[start:end])
		if err := fs.writeBlock(b, fileBuf); err != nil {
			return err
		}
	}

	// Write inode
	newInode := &Inode{SpanCount: uint8(len(spans))}
	for i, s := range spans {
		newInode.Spans[i] = s
	}
	if err := fs.writeInode(inodeBlock, newInode); err != nil {
		return err
	}

	// Write bitmap
	if err := fs.writeBitmap(bitmap); err != nil {
		return err
	}

	// Add directory entry
	var newEntry DirEntry
	newEntry.Type = TypeUsed
	copy(newEntry.Name[:], []byte(destName))
	newEntry.Size = uint32(len(data))
	newEntry.Inode = inodeBlock

	slotFound := false
	for i, e := range entries {
		if e.Type&TypeUsed == 0 {
			entries[i] = newEntry
			slotFound = true
			break
		}
	}
	if !slotFound {
		entries, blocks, err = fs.expandDir(dirInode, entries, blocks, bitmap)
		if err != nil {
			return err
		}
		for i, e := range entries {
			if e.Type&TypeUsed == 0 {
				entries[i] = newEntry
				slotFound = true
				break
			}
		}
		if !slotFound {
			return fmt.Errorf("could not find free slot after directory expansion")
		}
	}

	if err := fs.writeDirEntries(entries, blocks); err != nil {
		return err
	}

	fmt.Printf("Added %s -> %s (%d bytes)\n", srcPath, destPath, len(data))
	return nil
}

// buildSpans converts a list of block numbers (possibly non-contiguous) into spans.
func buildSpans(blocks []uint16) []Span {
	if len(blocks) == 0 {
		return nil
	}
	var spans []Span
	cur := Span{First: blocks[0], Last: blocks[0]}
	for _, b := range blocks[1:] {
		if b == cur.Last+1 {
			cur.Last = b
		} else {
			spans = append(spans, cur)
			cur = Span{First: b, Last: b}
		}
	}
	spans = append(spans, cur)
	return spans
}

func cmdGet(fs *FS, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: fstool <image> get <srcpath> [destfile]")
	}
	srcPath := args[0]
	destFile := ""
	if len(args) >= 2 {
		destFile = args[1]
	} else {
		destFile = filepath.Base(strings.ToLower(srcPath))
	}

	srcDir, srcName := parsePath(srcPath)
	dirInode, err := fs.resolveDirInode(srcDir)
	if err != nil {
		return err
	}

	e, _, _, _, err := fs.findDirEntry(dirInode, srcName)
	if err != nil {
		return err
	}
	if e == nil {
		return fmt.Errorf("not found: %s", srcName)
	}
	if e.Type&TypeDir != 0 {
		return fmt.Errorf("%s is a directory", srcName)
	}

	in, err := fs.readInode(e.Inode)
	if err != nil {
		return err
	}
	dataBlocks := fs.inodeBlocks(in)

	// Read all data
	var data []byte
	buf := make([]byte, BlockSize)
	for _, b := range dataBlocks {
		if err := fs.readBlock(b, buf); err != nil {
			return err
		}
		data = append(data, buf...)
	}
	// Trim to actual file size
	if e.Size < uint32(len(data)) {
		data = data[:e.Size]
	}

	if err := os.WriteFile(destFile, data, 0644); err != nil {
		return err
	}
	fmt.Printf("Got %s -> %s (%d bytes)\n", srcPath, destFile, len(data))
	return nil
}

func cmdRmdir(fs *FS, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: fstool <image> rmdir <dirname>")
	}
	dirname := strings.ToUpper(args[0])

	e, idx, entries, blocks, err := fs.findDirEntry(RootInodeBlock, dirname)
	if err != nil {
		return err
	}
	if e == nil {
		return fmt.Errorf("not found: %s", dirname)
	}
	if e.Type&TypeDir == 0 {
		return fmt.Errorf("%s is not a directory", dirname)
	}

	// Check empty
	dirEntries, _, err := fs.readDirEntries(e.Inode)
	if err != nil {
		return err
	}
	for _, de := range dirEntries {
		if de.Type&TypeUsed != 0 {
			return fmt.Errorf("directory not empty: %s", dirname)
		}
	}

	// Free all blocks owned by this directory inode
	bitmap, err := fs.readBitmap()
	if err != nil {
		return err
	}
	dirInode, err := fs.readInode(e.Inode)
	if err != nil {
		return err
	}
	for _, b := range fs.inodeBlocks(dirInode) {
		bitmapSet(bitmap, b, true)
	}
	bitmapSet(bitmap, e.Inode, true)

	if err := fs.writeBitmap(bitmap); err != nil {
		return err
	}

	// Remove directory entry from root
	entries[idx] = DirEntry{}
	return fs.writeDirEntries(entries, blocks)
}

func cmdRm(fs *FS, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: fstool <image> rm <pathname>")
	}
	path := args[0]
	dir, name := parsePath(path)

	dirInode, err := fs.resolveDirInode(dir)
	if err != nil {
		return err
	}

	e, idx, entries, blocks, err := fs.findDirEntry(dirInode, name)
	if err != nil {
		return err
	}
	if e == nil {
		return fmt.Errorf("not found: %s", name)
	}
	if e.Type&TypeDir != 0 {
		return fmt.Errorf("%s is a directory; use rmdir", name)
	}

	// Free file data blocks and inode
	bitmap, err := fs.readBitmap()
	if err != nil {
		return err
	}
	fileInode, err := fs.readInode(e.Inode)
	if err != nil {
		return err
	}
	for _, b := range fs.inodeBlocks(fileInode) {
		bitmapSet(bitmap, b, true)
	}
	bitmapSet(bitmap, e.Inode, true)

	if err := fs.writeBitmap(bitmap); err != nil {
		return err
	}

	// Remove directory entry
	entries[idx] = DirEntry{}
	return fs.writeDirEntries(entries, blocks)
}

func cmdRename(fs *FS, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: fstool <image> rename <oldname> <newname>")
	}
	oldName := strings.ToUpper(args[0])
	newName := strings.ToUpper(args[1])

	if len(newName) > MaxNameLen {
		return fmt.Errorf("new name too long (max %d chars)", MaxNameLen)
	}

	// Only supports root-level rename (same dir)
	oldDir, oldBase := parsePath(oldName)
	newDir, newBase := parsePath(newName)
	if oldDir != newDir {
		return fmt.Errorf("rename across directories not supported")
	}

	dirInode := uint16(RootInodeBlock)
	if oldDir != "" {
		di, err := fs.resolveDirInode(oldDir)
		if err != nil {
			return err
		}
		dirInode = di
	}

	e, idx, entries, blocks, err := fs.findDirEntry(dirInode, oldBase)
	if err != nil {
		return err
	}
	if e == nil {
		return fmt.Errorf("not found: %s", oldBase)
	}

	// Check new name doesn't exist
	existing, _, _, _, err := fs.findDirEntry(dirInode, newBase)
	if err != nil {
		return err
	}
	if existing != nil {
		return fmt.Errorf("already exists: %s", newBase)
	}

	// Update name in-place
	for i := range entries[idx].Name {
		entries[idx].Name[i] = 0
	}
	copy(entries[idx].Name[:], []byte(newBase))

	return fs.writeDirEntries(entries, blocks)
}

// ============================================================
// Main
// ============================================================

func usage() {
	fmt.Fprintf(os.Stderr, `Usage: fstool [-H] <imagefile> <command> [args...]

Flags:
  -H  Skip 1024-byte header (EtchedPixels RC2014 CF image format)

Commands:
  format <blocks>            Initialize filesystem with given number of blocks
  info                       Print filesystem information
  dir [pathname]             List directory (root if not specified)
  mkdir <dirname>            Create directory (root only)
  add <srcfile> <destpath>   Copy file from host to filesystem
  get <srcpath> [destfile]   Copy file from filesystem to host
  rmdir <dirname>            Remove empty directory
  rm <pathname>              Remove file
  rename <oldname> <newname> Rename file or directory
`)
	os.Exit(1)
}

func main() {
	var offset int64
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "-H" {
		offset = HeaderSkip
		args = args[1:]
	}

	if len(args) < 2 {
		usage()
	}

	imagePath := args[0]
	command := strings.ToLower(args[1])
	cmdArgs := args[2:]

	// format doesn't need a valid FS header
	if command == "format" {
		if err := cmdFormat(imagePath, cmdArgs, offset); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	fs, err := openFS(imagePath, offset)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening filesystem: %v\n", err)
		os.Exit(1)
	}
	defer fs.close()

	var cmdErr error
	switch command {
	case "info":
		cmdErr = cmdInfo(fs)
	case "dir":
		cmdErr = cmdDir(fs, cmdArgs)
	case "mkdir":
		cmdErr = cmdMkdir(fs, cmdArgs)
	case "add":
		cmdErr = cmdAdd(fs, cmdArgs)
	case "get":
		cmdErr = cmdGet(fs, cmdArgs)
	case "rmdir":
		cmdErr = cmdRmdir(fs, cmdArgs)
	case "rm":
		cmdErr = cmdRm(fs, cmdArgs)
	case "rename":
		cmdErr = cmdRename(fs, cmdArgs)
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", command)
		usage()
	}

	if cmdErr != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", cmdErr)
		os.Exit(1)
	}
}
