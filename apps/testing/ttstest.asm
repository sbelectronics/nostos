; ============================================================
; ttstest.asm - TTS test application for NostOS
; Sends a list of test words to the TTS: character device,
; printing each word to the console first.
; ============================================================

    INCLUDE "../../src/include/syscall.asm"

    ORG  0

    ; Entry point — jump over the header
    JP   ttstest_main

    ; Header pad: 13 bytes of zeros (offsets 3-15 reserved)
    DEFS 13, 0

; ============================================================
; ttstest_main - entry point (at 0x0810)
; ============================================================
ttstest_main:
    ; Look up TTS device
    LD   DE, ttstest_devname
    LD   C, DEV_LOOKUP
    CALL KERNELADDR
    OR   A
    JP   NZ, ttstest_no_dev

    ; Save TTS device ID (returned in L)
    LD   A, L
    LD   (ttstest_tts_id), A

    ; Point to word list
    LD   HL, ttstest_words

ttstest_loop:
    ; Check for end of list (double null)
    LD   A, (HL)
    OR   A
    JP   Z, ttstest_done

    ; Save word pointer
    PUSH HL

    ; Print word to console
    LD   D, H
    LD   E, L
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print CRLF to console
    LD   DE, ttstest_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Send word to TTS device
    POP  HL
    PUSH HL
    LD   D, H
    LD   E, L
    LD   A, (ttstest_tts_id)
    LD   B, A
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Send space to TTS to flush the word
    LD   DE, ttstest_space
    LD   A, (ttstest_tts_id)
    LD   B, A
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Print blank line to console
    LD   DE, ttstest_crlf
    LD   B, LOGDEV_ID_CONO
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR

    ; Advance to next word (skip past null terminator)
    POP  HL
ttstest_skip:
    LD   A, (HL)
    INC  HL
    OR   A
    JP   NZ, ttstest_skip

    JP   ttstest_loop

ttstest_done:
    LD   C, SYS_EXIT
    CALL KERNELADDR

ttstest_no_dev:
    LD   B, LOGDEV_ID_CONO
    LD   DE, ttstest_err_msg
    LD   C, DEV_CWRITE_STR
    CALL KERNELADDR
    LD   C, SYS_EXIT
    CALL KERNELADDR

; ============================================================
; Data
; ============================================================
ttstest_devname:
    DEFM "TTS", 0
ttstest_crlf:
    DEFM 0x0D, 0x0A, 0
ttstest_space:
    DEFM " ", 0
ttstest_err_msg:
    DEFM "TTS device not found.", 0x0D, 0x0A, 0
ttstest_tts_id:
    DEFB 0

; ============================================================
; Test words (null-terminated, double-null at end)
; ============================================================
ttstest_words:
    DEFM "a", 0
    DEFM "b", 0
    DEFM "c", 0
    DEFM "d", 0
    DEFM "e", 0
    DEFM "f", 0
    DEFM "g", 0
    DEFM "h", 0
    DEFM "i", 0
    DEFM "j", 0
    DEFM "k", 0
    DEFM "l", 0
    DEFM "m", 0
    DEFM "n", 0
    DEFM "o", 0
    DEFM "p", 0
    DEFM "q", 0
    DEFM "r", 0
    DEFM "s", 0
    DEFM "t", 0
    DEFM "u", 0
    DEFM "v", 0
    DEFM "w", 0
    DEFM "x", 0
    DEFM "y", 0
    DEFM "z", 0
    DEFM "one", 0
    DEFM "two", 0
    DEFM "three", 0
    DEFM "four", 0
    DEFM "five", 0
    DEFM "six", 0
    DEFM "seven", 0
    DEFM "eight", 0
    DEFM "nine", 0
    DEFM "ten", 0
    DEFM "alpha", 0
    DEFM "advertise", 0
    DEFM "aether", 0
    DEFM "aid", 0
    DEFM "all", 0
    DEFM "aloud", 0
    DEFM "anemone", 0
    DEFM "aptly", 0
    DEFM "awesome", 0
    DEFM "ball", 0
    DEFM "balloon", 0
    DEFM "baker", 0
    DEFM "base", 0
    DEFM "brekfast", 0
    DEFM "bring", 0
    DEFM "broadcast", 0
    DEFM "butiful", 0
    DEFM "cat", 0
    DEFM "certin", 0
    DEFM "chomp", 0
    DEFM "computer", 0
    DEFM "church", 0
    DEFM "coffee", 0
    DEFM "come", 0
    DEFM "country", 0
    DEFM "day", 0
    DEFM "delete", 0
    DEFM "doctor", 0
    DEFM "dog", 0
    DEFM "educated", 0
    DEFM "education", 0
    DEFM "either", 0
    DEFM "electroanalysis", 0
    DEFM "emergency", 0
    DEFM "every", 0
    DEFM "example", 0
    DEFM "exit", 0
    DEFM "far", 0
    DEFM "flywheel", 0
    DEFM "for", 0
    DEFM "fortran", 0
    DEFM "gave", 0
    DEFM "give", 0
    DEFM "go", 0
    DEFM "good", 0
    DEFM "half", 0
    DEFM "have", 0
    DEFM "hoard", 0
    DEFM "hotel", 0
    DEFM "if", 0
    DEFM "image", 0
    DEFM "imagery", 0
    DEFM "imagined", 0
    DEFM "india", 0
    DEFM "information", 0
    DEFM "isthmus", 0
    DEFM "joe", 0
    DEFM "joeseph", 0
    DEFM "just", 0
    DEFM "kaleidoscopes", 0
    DEFM "kilogram", 0
    DEFM "kilometer", 0
    DEFM "kitchen", 0
    DEFM "kitten", 0
    DEFM "knife", 0
    DEFM "knock", 0
    DEFM "know", 0
    DEFM "lima", 0
    DEFM "lime", 0
    DEFM "loose", 0
    DEFM "lonely", 0
    DEFM "lose", 0
    DEFM "lost", 0
    DEFM "lymph", 0
    DEFM "magazine", 0
    DEFM "medication", 0
    DEFM "men", 0
    DEFM "mingle", 0
    DEFM "mingles", 0
    DEFM "mingling", 0
    DEFM "mischievious", 0
    DEFM "mistake", 0
    DEFM "mosheenery", 0
    DEFM "muscle", 0
    DEFM "near", 0
    DEFM "nebraska", 0
    DEFM "next", 0
    DEFM "north", 0
    DEFM "nose", 0
    DEFM "now", 0
    DEFM "of", 0
    DEFM "open", 0
    DEFM "ouija", 0
    DEFM "out", 0
    DEFM "pause", 0
    DEFM "playground", 0
    DEFM "polygraph", 0
    DEFM "pronunsiation", 0
    DEFM "prowceejers", 0
    DEFM "pedal", 0
    DEFM "pepper", 0
    DEFM "petal", 0
    DEFM "quail", 0
    DEFM "quiet", 0
    DEFM "question", 0
    DEFM "round", 0
    DEFM "rodeo", 0
    DEFM "rowdeo", 0
    DEFM "rural", 0
    DEFM "scott", 0
    DEFM "separate", 0
    DEFM "simple", 0
    DEFM "sing", 0
    DEFM "sings", 0
    DEFM "some", 0
    DEFM "south", 0
    DEFM "speed", 0
    DEFM "speeded", 0
    DEFM "squash", 0
    DEFM "storm", 0
    DEFM "sun", 0
    DEFM "sunny", 0
    DEFM "system", 0
    DEFM "temple", 0
    DEFM "tenth", 0
    DEFM "test", 0
    DEFM "the", 0
    DEFM "their", 0
    DEFM "thing", 0
    DEFM "things", 0
    DEFM "thread", 0
    DEFM "threaded", 0
    DEFM "time", 0
    DEFM "timeless", 0
    DEFM "timely", 0
    DEFM "toast", 0
    DEFM "toggle", 0
    DEFM "tooth", 0
    DEFM "top", 0
    DEFM "tower", 0
    DEFM "type", 0
    DEFM "to", 0
    DEFM "unique", 0
    DEFM "use", 0
    DEFM "useless", 0
    DEFM "user", 0
    DEFM "utah", 0
    DEFM "variety", 0
    DEFM "vary", 0
    DEFM "venison", 0
    DEFM "very", 0
    DEFM "votrax", 0
    DEFM "walked", 0
    DEFM "who", 0
    DEFM "xerxes", 0
    DEFM "xilophone", 0
    DEFM "zany", 0
    DEFM "zero", 0
    DEFM "zoo", 0
    DEFM "zone", 0
    DEFB 0          ; end of list sentinel
