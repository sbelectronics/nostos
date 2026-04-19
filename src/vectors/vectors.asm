vectors:
	JP kernel_init		; rst 0  (cold reset, kernel-reserved)
	DEFS 5, 0x00

	JP exec_main		; rst 1  (executive entry, kernel-reserved)
	DEFS 5, 0x00

	JP syscall_entry	; rst 2  (syscall, kernel-reserved)
	DEFS 5, 0x00

	JP RST3_RAM_VEC		; rst 3  (RAM-overridable; default unexpected_rst)
	DEFS 5, 0x00

	JP RST4_RAM_VEC		; rst 4  (RAM-overridable; default unexpected_rst)
	DEFS 5, 0x00

	JP RST5_RAM_VEC		; rst 5  (RAM-overridable; default unexpected_rst)
	DEFS 5, 0x00

	JP RST6_RAM_VEC		; rst 6  (RAM-overridable; default unexpected_rst)
	DEFS 5, 0x00

	JP RST7_RAM_VEC		; rst 7  (RAM-overridable; IM 1 vector)
	DEFS 5, 0x00
