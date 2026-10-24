@ INFO screen with tone-curve loading (stage 11, test build): INFO in shooting mode shows "Camera
@ stats" as stage 8, with a "Tone curve" row; UP loads \PROFILE.LUT from the card and sends it to
@ the Blackfin as its GAMMA table (LUT 1); INFO or SET closes. Until power-off: nothing is
@ written to flash, the camera loads its own GAMMA again at the next start.
@ Code placed over the four Blackfin-test debug commands and their two private helpers
@ (0x2ABD0-0x2B6E8, as stage 7; FINDINGS "Reclaimable space"). Each command entry stays a stub
@ returning 0; `.org` pins the stubs. Registrations untouched.
@
@ 0x2ABD0  bf_memtest1 entry, stub returning 0.
@ 0x2ABD8  info_open: as stage 8 (camInfoMenu + BodyDebugDataDialog the camera's own way, dialog
@          pointed at vt_idle, our copy of its method table).
@ on_key   INFO or SET: restore the dialog's own table 0xED1B8, then its own SET path 0x61868.
@          UP: load (below), then point the dialog at the table of the result and redraw (method
@          +0x1C, as stage 7). Others ignored. The result shown = which of our tables the dialog
@          uses (no other state).
@ load     as the firmware reads files (0x22004) and sends LUTs (0x90CB0 -> 0x906C4):
@          take the shared file buffer without waiting (0x20F18, as the GUI's own 0x499E0; busy ->
@          nothing done), open "\PROFILE.LUT" "rb" (0xA6428), size must be 31,760 (0xA4F6C), read
@          31,760 bytes into the buffer (0xA6A84), close (0xA6498); the first 24 bytes must equal
@          the stock GAMMA header; then 0x906C4(1, 1, 31760, buffer) = BF::CreateFile + writes +
@          close of LUT 1, the call the boot task makes for GAMMA; release the buffer (0x20F64).
@ Painting: as stage 8 (fill 0x98A40, text 0x996EC, width 0x99C0C, sprintf 0xB94EC).
@ Reads: body debug data (command 0x33 via 0x3E238 into the dialog's buffer +0xB0, once per
@ paint), the card file. Writes: the two flag bytes of stage 6, dialog+0 (method table), the
@ dialog's body-data buffer (by 0x3E238), the shared file buffer (by the file read), the screen,
@ our stack; the Blackfin's LUT 1 (by 0x906C4). No flash, EEPROM or settings.

    .syntax unified
    .arm
    .text

    .equ BASE,       0x0002ABD0     @ load address of `stub` (for the method tables)
    .equ MENU,       0x6F6C         @ camInfoMenu inside the application object
    .equ DIALOG,     0x138          @ BodyDebugDataDialog inside camInfoMenu
    .equ DLG_VT,     0x000ED1B8     @ the dialog's own method table
    .equ DLG_KEY,    0x00061868     @ the dialog's own key method (SET = close)
    .equ SHOW_PAGE,  0x00058FE8
    .equ SHOW,       0x00040360
    .equ RETURN,     0x00044F8C     @ application key handler epilogue
    .equ FILL,       0x00098A40     @ (x, y, w, h, [sp] colour565)
    .equ TEXT,       0x000996EC     @ (x, y, w, h, [sp] str, [sp+4] colour565, [sp+8] font)
    .equ TWIDTH,     0x00099C0C     @ (str, font) -> width + 1
    .equ SPRINTF,    0x000B94EC
    .equ BODY_DATA,  0x0003E238     @ (body link, dest) -> 0 = ok
    .equ P_CTX2,     0x000D421C
    .equ P_FILEBUF,  0x000D422C     @ -> shared file buffer object
    .equ BUF_TRY,    0x00020F18     @ (obj, 0) -> buffer, 0 = in use
    .equ BUF_FREE,   0x00020F64     @ (obj)
    .equ FOPEN,      0x000A6428     @ (name, mode) -> file, 0 = none
    .equ FSIZE,      0x000A4F6C     @ (file) -> bytes
    .equ FREAD,      0x000A6A84     @ (file, dest, n) -> bytes read
    .equ FCLOSE,     0x000A6498     @ (file)
    .equ LUT_SEND,   0x000906C4     @ (lut, 1, size, data) -> < 0 = failed
    .equ GAMMA_LUT,  1
    .equ GAMMA_SIZE, 31760
    .equ F3,         0x30000        @ font 3 (FONT1, 17 px) << 16
    .equ F4,         0x40000        @ font 4 (FONT2, 21 px) << 16
    .equ WHITE,      0xFFFF
    .equ GREY,       0x94B2         @ (150, 150, 150)
    .equ FOOT,       0x6B6D         @ (110, 110, 110)
    .equ BAR,        0x2945         @ (40, 40, 40)
    .equ VT_SIZE,    88             @ one method table, 22 words
    .equ R_OK, 1                    @ results = index into `results`
    .equ R_NOFILE, 2
    .equ R_BADFILE, 3
    .equ R_BUSY, 4
    .equ R_SENDFAIL, 5

.macro fcall addr                   @ call a firmware routine without a relocation
    mov     lr, pc                  @ pc reads as this + 8 = the instruction after the ldr
    ldr     pc, =\addr
.endm
.macro la reg, label                 @ absolute address of a label here (adr cannot reach)
    ldr     \reg, =(BASE + \label - stub)
.endm
.macro lcall label                  @ call a local routine
    mov     lr, pc
    b       \label
.endm
.macro vtable                       @ copy of 0xED1B8 with keys / title / content replaced
    .word   0xCD34C, 0xCD354, 0xCD35C, 0xCD364, 0x9A8D0, 0xD1E6C, 0xD1EB4, 0x9A47C
    .word   0xCD36C, 0x605AC, 0x9A8F0, BASE + (on_key - stub), 0x9ACD8, 0x9AD68, 0x9AD6C, 0x40360
    .word   0xCD370, 0xCD374, BASE + (title - stub), BASE + (stats_paint - stub), 0, 0
.endm

stub:
    mov     r0, #0
    bx      lr

info_open:                          @ r4 = GUI application
    add     r0, r4, #(MENU & 0xFF00)
    add     r0, r0, #(MENU & 0x00FF)
    mov     r1, #1
    fcall   SHOW_PAGE               @ show camInfoMenu, as 0x44F78
    add     r3, r4, #0x25400
    mov     r2, #1
    strb    r2, [r3, #0x8F]         @ app+0x2548F = 1, as 0x44F88
    add     r0, r4, #(MENU & 0xFF00)
    add     r0, r0, #(MENU & 0x00FF)
    mov     r3, #0
    strb    r3, [r0, #0x99]         @ menu+0x99 = 0, as 0x65630
    add     r0, r0, #DIALOG
    la      r1, vt_idle
    str     r1, [r0]                @ the dialog paints and handles keys with our methods
    mov     r1, #1
    fcall   SHOW                    @ show it, as 0x6567C
    ldr     pc, =RETURN

on_key:                             @ (this, key)
    and     r1, r1, #0xFF
    cmp     r1, #'u'
    beq     1f
    cmp     r1, #'i'
    cmpne   r1, #'s'
    bxne    lr                      @ other keys: ignored
    ldr     r2, =DLG_VT             @ INFO or SET: close with the dialog's own methods
    str     r2, [r0]
    mov     r1, #'s'
    ldr     pc, =DLG_KEY
1:  push    {r4, lr}
    mov     r4, r0
    lcall   load                    @ -> r0 = result
    la      r1, results
    ldr     r2, [r1, r0, lsl #3]    @ that result's method table
    str     r2, [r4]
    mov     r0, r4
    mov     r1, #'u'
    pop     {r4, lr}
    ldr     pc, [r2, #0x1C]         @ redraw (method +0x1C, as stage 7), r0 = this

@ ---- helpers
text:                               @ (x, y, str, colour | font << 16), box to the right edge
    push    {r4, lr}
    sub     sp, sp, #16
    str     r2, [sp]
    mov     r4, r3, lsr #16
    str     r4, [sp, #8]
    mov     r3, r3, lsl #16
    mov     r3, r3, lsr #16
    str     r3, [sp, #4]
    rsb     r2, r0, #320
    mov     r3, #30
    fcall   TEXT
    add     sp, sp, #16
    pop     {r4, pc}

text_r:                             @ as text, but r0 = right edge
    push    {r4-r7, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    mov     r0, r2
    mov     r1, r3, lsr #16
    fcall   TWIDTH
    sub     r0, r4, r0
    mov     r1, r5
    mov     r2, r6
    mov     r3, r7
    lcall   text
    pop     {r4-r7, pc}

@ ---- title bar (+0x48): bar, title, footer
title:                              @ (this)
    push    {lr}
    sub     sp, sp, #4
    ldr     ip, =BAR
    str     ip, [sp]
    mov     r0, #0
    mov     r1, #0
    mov     r2, #320
    mov     r3, #25
    fcall   FILL
    add     sp, sp, #4
    mov     r0, #8
    mov     r1, #4
    la      r2, s_title
    ldr     r3, =(WHITE | F3)
    lcall   text
    mov     r0, #8
    mov     r1, #218
    la      r2, s_foot
    ldr     r3, =(FOOT | F3)
    lcall   text
    pop     {pc}

@ ---- content (+0x4C)
stats_paint:                        @ (this)
    push    {r4-r6, lr}
    sub     sp, sp, #48
    mov     r4, r0
    ldr     r0, =P_CTX2
    ldr     r0, [r0]
    add     r0, r0, #0x5000
    add     r0, r0, #0xC0
    add     r1, r4, #0xB0
    fcall   BODY_DATA               @ command 0x33, as 0x60FC0
    cmp     r0, #0
    beq     1f
    mov     r0, #8
    mov     r1, #100
    la      r2, s_nodata
    ldr     r3, =(WHITE | F4)
    lcall   text
    b       4f
1:  la      r6, rows                @ {label, format, field offset | type << 16} x 4
    mov     r5, #40
2:  ldr     r2, [r6]
    add     r2, r6, r2              @ label (offset from the row)
    mov     r0, #12
    mov     r1, r5
    ldr     r3, =(GREY | F3)
    lcall   text
    ldr     r3, [r6, #8]
    mov     r2, r3, lsl #16
    mov     r2, r2, lsr #16
    add     r2, r4, r2              @ field address
    tst     r3, #0x10000
    ldreq   r2, [r2]                @ type 0: u32, 1: byte
    ldrbne  r2, [r2]
    tst     r3, #0x20000            @ type 2: battery name
    beq     3f
    cmp     r2, #4
    movhi   r2, #5
    la      r1, batt
    ldr     r2, [r1, r2, lsl #2]
    add     r2, r1, r2              @ table holds offsets from `batt`
3:  ldr     r1, [r6, #4]
    add     r1, r6, r1              @ format (offset from the row)
    mov     r0, sp
    fcall   SPRINTF
    mov     r0, #308
    sub     r1, r5, #2
    mov     r2, sp
    ldr     r3, =(WHITE | F4)
    lcall   text_r
    add     r6, r6, #12
    add     r5, r5, #34
    cmp     r5, #(40 + 4 * 34)
    blo     2b
4:  mov     r0, #12                 @ tone-curve row: text of the result this table stands for
    mov     r1, #176
    la      r2, s_curve
    ldr     r3, =(GREY | F3)
    lcall   text
    ldr     r0, [r4]
    la      r1, results
5:  ldr     r2, [r1], #8            @ find our table in `results` (it is there: we set it)
    cmp     r2, r0
    bne     5b
    ldr     r2, [r1, #-4]
    mov     r0, #308
    mov     r1, #174
    ldr     r3, =(WHITE | F4)
    lcall   text_r
    add     sp, sp, #48
    pop     {r4-r6, pc}

@ ---- data
    .align  2
rows:
    .word   s_shots - rows,      s_fmt_d - rows,  0x000E4     @ NumExposures (u32), as 0x61680
    .word   s_batt - (rows+12),  s_fmt_s - (rows+12), 0x200C8 @ battery state (byte), as 0x612D4
    .word   s_temp - (rows+24),  s_fmt_t - (rows+24), 0x000C4 @ temperature "normal", as 0x6124C
    .word   s_lens - (rows+36),  s_fmt_d - (rows+36), 0x100DD @ lens code (byte), as 0x615D8
batt:
    .word   b0 - batt, b1 - batt, b2 - batt, b3 - batt, b4 - batt, b5 - batt
results:                            @ result -> {method table, tone-curve text}
    .word   BASE + (vt_idle - stub),     BASE + (r_idle - stub)
    .word   BASE + (vt_ok - stub),       BASE + (r_ok - stub)
    .word   BASE + (vt_nofile - stub),   BASE + (r_nofile - stub)
    .word   BASE + (vt_badfile - stub),  BASE + (r_badfile - stub)
    .word   BASE + (vt_busy - stub),     BASE + (r_busy - stub)
    .word   BASE + (vt_sendfail - stub), BASE + (r_sendfail - stub)
gamma_hdr:                          @ first 24 bytes of the stock GAMMA table (FINDINGS)
    .word   0x0E, 0x410, 0x1D0, 0x410, 15, 0x800

s_title:  .asciz "Camera stats"
s_foot:   .asciz "UP: load PROFILE.LUT    SET: close"
s_nodata: .asciz "Body data unavailable"
s_shots:  .asciz "Shots taken"
s_batt:   .asciz "Battery"
s_temp:   .asciz "Temperature"
s_lens:   .asciz "Lens code"
s_curve:  .asciz "Tone curve"
s_fmt_d:  .asciz "%d"
s_fmt_s:  .asciz "%s"
s_fmt_t:  .asciz "%d \302\260C"
b0:       .asciz "Empty"
b1:       .asciz "Almost empty"
b2:       .asciz "Half"
b3:       .asciz "Almost full"
b4:       .asciz "Full"
b5:       .asciz "Unknown"
    .align  2
    .ltorg

@ ---- bf_memtest2 entry (0x2B0E0): kept as a stub returning 0
    .org    0x2B0E0 - BASE
    mov     r0, #0
    bx      lr

@ ---- load \PROFILE.LUT into the Blackfin's GAMMA table -> r0 = result
load:
    push    {r4-r7, lr}
    ldr     r0, =P_FILEBUF
    ldr     r0, [r0]
    mov     r1, #0
    fcall   BUF_TRY                 @ shared file buffer, without waiting
    movs    r5, r0
    moveq   r0, #R_BUSY
    popeq   {r4-r7, pc}
    la      r0, s_path
    la      r1, s_rb
    fcall   FOPEN
    movs    r6, r0
    moveq   r4, #R_NOFILE
    beq     9f
    fcall   FSIZE
    ldr     r7, =GAMMA_SIZE
    cmp     r0, r7
    movne   r4, #R_BADFILE
    bne     8f
    mov     r0, r6
    mov     r1, r5
    mov     r2, r7
    fcall   FREAD
    cmp     r0, r7
    movne   r4, #R_BADFILE
    bne     8f
    la      r0, gamma_hdr           @ header check
    mov     r1, #0
1:  ldr     r2, [r0, r1]
    ldr     r3, [r5, r1]
    cmp     r2, r3
    movne   r4, #R_BADFILE
    bne     8f
    add     r1, r1, #4
    cmp     r1, #24
    blo     1b
    mov     r4, #0                  @ file ok: send after closing it
8:  mov     r0, r6
    fcall   FCLOSE
    cmp     r4, #0
    bne     9f
    mov     r0, #GAMMA_LUT
    mov     r1, #1
    mov     r2, r7
    mov     r3, r5
    fcall   LUT_SEND                @ as 0x90CB0 -> 0x906C4 for GAMMA at boot
    cmp     r0, #0
    movge   r4, #R_OK
    movlt   r4, #R_SENDFAIL
9:  ldr     r0, =P_FILEBUF
    ldr     r0, [r0]
    fcall   BUF_FREE
    mov     r0, r4
    pop     {r4-r7, pc}

s_path:     .asciz "\\PROFILE.LUT"
s_rb:       .asciz "rb"
r_idle:     .asciz "UP to load"
r_ok:       .asciz "Loaded"
r_nofile:   .asciz "No PROFILE.LUT"
r_badfile:  .asciz "Not a curve file"
r_busy:     .asciz "Busy, try again"
r_sendfail: .asciz "Send failed"
    .align  2
    .ltorg

@ ---- bf_memtest3 entry (0x2B338): kept as a stub returning 0
    .org    0x2B338 - BASE
    mov     r0, #0
    bx      lr

vt_idle:     vtable
vt_ok:       vtable
vt_nofile:   vtable
vt_badfile:  vtable

@ ---- bf_checktrans entry (0x2B4B0): kept as a stub returning 0
    .org    0x2B4B0 - BASE
    mov     r0, #0
    bx      lr

vt_busy:     vtable
vt_sendfail: vtable
