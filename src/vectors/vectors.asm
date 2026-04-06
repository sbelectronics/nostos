vectors:
	JP kernel_init		; rst 0
	DEFS 5, 0x00

	JP exec_main		; rst 1
	DEFS 5, 0x00

	JP syscall_entry	; rst 2
	DEFS 5, 0x00

	JP unexpected_rst	; rst 3
	DEFS 5, 0x00

	JP unexpected_rst	; rst 4
	DEFS 5, 0x00

	JP unexpected_rst	; rst 5
	DEFS 5, 0x00

	JP unexpected_rst	; rst 6
	DEFS 5, 0x00

	JP unexpected_rst	; rst 7
	DEFS 5, 0x00
