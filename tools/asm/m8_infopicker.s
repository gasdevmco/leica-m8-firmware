@ INFO screen with picture-profile picker (stage 13): INFO in shooting mode shows "Camera stats"
@ (stage 8) with a "Tone curve" row; UP/DOWN opens "Picture profile": the .LUT files in
@ \PROFILES (made by tools/m8_profile.py), UP/DOWN to choose, SET loads it as the Blackfin's GAMMA
@ table (LUT 1) until power-off, INFO closes. Stock curves stay the camera's default.
@ Code placed over the four Blackfin-test debug commands and their two private helpers
@ (0x2ABD0-0x2B6E8, as stages 7 and 11). Each command entry stays a stub returning 0; `.org` pins
@ the stubs. Registrations untouched.
@
@ 0x2ABD0  bf_memtest1 entry, stub returning 0.
@ 0x2ABD8  info_open: as stage 8 (camInfoMenu + BodyDebugDataDialog the camera's own way, dialog
@          pointed at vt_info, our copy of its method table; page = Camera stats).
@ on_key   INFO: restore the dialog's own table 0xED1B8, then its own SET path 0x61868 (close).
@          SET: on Camera stats close; on Picture profile load the selected file.
@          UP/DOWN: on Camera stats switch to Picture profile; there move the selection.
@          Then redraw (method +0x1C, as stages 7 and 11). Others ignored.
@ List     OpenDir("\PROFILES") / ReadDir / GetName / GetAttr / GetSize / CloseDir (emFile, as the
@          update finder 0x23104): files only, size 31,760, name 1-8 letters/digits + ".LUT"
@          (any case; shown upper case), at most 10, in directory order. Re-read at every paint
@          and load (no list kept in memory).
@ load     as stage 11 (shared file buffer without waiting 0x20F18 / 0x20F64; FOpen "rb",
@          size, read, close; stock GAMMA header check; 0x906C4(1, 1, 31760, buffer)), with the
@          path "\PROFILES\NAME.LUT" of the selected entry.
@ State    16 bytes at 0x1531FC: the filename buffer of the `ldimg` debug command (reclaimed in
@          the DNG builds; otherwise only reachable from the service shell), in .bss: zero at every
@          start-up (0xF1BB0-0x1837E0 cleared at 0x20118), so the camera starts with nothing
@          selected and Leica's curves loaded. +0 selection, +1 profile loaded, +2 last result,
@          +3 entries found by the last paint, +4 page (0 Camera stats, 1 Picture profile),
@          +5 loaded name (11 bytes). Values are clamped before use. One method table; its
@          content method paints the page the state names.
@ Painting: dialog base paint 0x605AC clears the window and calls our +0x48 (title) and +0x4C
@ (content); drawing only with fill 0x98A40, text 0x996EC, text width 0x99C0C; sprintf 0xB94EC.
@ Reads: body debug data (command 0x33 via 0x3E238 into the dialog's buffer +0xB0, once per
@ Camera stats paint), the \PROFILES directory and the selected file.
@ Writes: the two flag bytes of stage 6, dialog+0 (method table), the dialog's body-data buffer
@ (by 0x3E238), the state bytes above, the shared file buffer (by the file read), the screen,
@ our stack; the Blackfin's LUT 1 (by 0x906C4). No flash, EEPROM, settings or card writes.

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
    .equ OPENDIR,    0x000A479C     @ (path) -> dir, 0 = none
    .equ READDIR,    0x000A4804     @ (dir) -> entry, 0 = end
    .equ GETNAME,    0x000A4898     @ (entry, buf) unbounded copy: buf of 256
    .equ GETATTR,    0x000A4864     @ (entry, &u8): 0x10 directory, 2 hidden, 4 system
    .equ GETSIZE,    0x000A48D8     @ (entry) -> bytes
    .equ CLOSEDIR,   0x000A47D0     @ (dir)
    .equ LUT_SEND,   0x000906C4     @ (lut, 1, size, data) -> < 0 = failed
    .equ GAMMA_LUT,  1
    .equ GAMMA_SIZE, 31760
    .equ STATE,      0x001531FC     @ 16 bytes, see above
    .equ S_SEL, 0
    .equ S_ACT, 1
    .equ S_RES, 2
    .equ S_CNT, 3
    .equ S_PAGE, 4
    .equ S_NAME, 5
    .equ MAXP,       10             @ list entries
    .equ ENTRY,      12             @ bytes per entry: name (<= 8) + NUL, padded
    .equ ROWH,       18
    .equ ROW0,       32
    .equ F3,         0x30000        @ font 3 (FONT1, 17 px) << 16
    .equ F4,         0x40000        @ font 4 (FONT2, 21 px) << 16
    .equ WHITE,      0xFFFF
    .equ GREY,       0x94B2         @ (150, 150, 150)
    .equ FOOT,       0x6B6D         @ (110, 110, 110)
    .equ BAR,        0x2945         @ (40, 40, 40)
    .equ SEL,        0x3186         @ (50, 50, 50) selected row
    .equ GREEN,      0x3E47
    .equ AMBER,      0xFD20
    .equ R_OK, 1                    @ results
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
    ldr     r1, =STATE
    strb    r3, [r1, #S_PAGE]       @ open on Camera stats
    add     r0, r0, #DIALOG
    la      r1, vt_info
    str     r1, [r0]                @ the dialog paints and handles keys with our methods
    mov     r1, #1
    fcall   SHOW                    @ show it, as 0x6567C
    ldr     pc, =RETURN

on_key:                             @ (this, key)
    and     r1, r1, #0xFF
    ldr     ip, =STATE
    ldrb    r3, [ip, #S_PAGE]       @ 0 Camera stats, 1 Picture profile
    cmp     r1, #'i'
    beq     9f
    cmp     r1, #'s'
    bne     1f
    cmp     r3, #1
    bne     9f                      @ SET on Camera stats: close
    push    {r4, lr}                @ SET on Picture profile: load
    mov     r4, r0
    lcall   load
    mov     r0, r4
    pop     {r4, lr}
    b       8f
1:  cmp     r1, #'u'
    cmpne   r1, #'d'
    bxne    lr                      @ other keys: ignored
    mov     r2, #0
    strb    r2, [ip, #S_RES]        @ a new choice clears the last result
    cmp     r3, #1
    movne   r2, #1
    strbne  r2, [ip, #S_PAGE]       @ on Camera stats: open the list
    bne     8f
    ldrb    r2, [ip, #S_SEL]
    ldrb    r3, [ip, #S_CNT]
    cmp     r3, #0
    beq     8f
    cmp     r1, #'u'
    subeq   r2, r2, #1
    addne   r2, r2, #1
    cmp     r2, #0
    addlt   r2, r2, r3              @ wrap round
    cmp     r2, r3
    movge   r2, #0
    strb    r2, [ip, #S_SEL]
8:  ldr     r2, [r0]
    mov     r1, #'u'
    ldr     pc, [r2, #0x1C]         @ redraw (method +0x1C, as stage 7), r0 = this
9:  ldr     r2, =DLG_VT             @ close with the dialog's own methods
    str     r2, [r0]
    mov     r1, #'s'
    ldr     pc, =DLG_KEY

content:                            @ (this): +0x4C, the page the state names
    ldr     ip, =STATE
    ldrb    r1, [ip, #S_PAGE]
    cmp     r1, #1
    beq     list_paint
    b       stats_paint

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

fill:                               @ (x, y, w, h), ip = colour
    push    {lr}
    sub     sp, sp, #4
    str     ip, [sp]
    fcall   FILL
    add     sp, sp, #4
    pop     {pc}

@ ---- title bar (+0x48): bar, page title, last result (list), footer
title:                              @ (this)
    push    {r4, lr}
    ldr     r4, =STATE
    ldrb    r4, [r4, #S_PAGE]       @ 1: Picture profile page
    ldr     ip, =BAR
    mov     r0, #0
    mov     r1, #0
    mov     r2, #320
    mov     r3, #25
    lcall   fill
    cmp     r4, #1
    mov     r0, #8
    mov     r1, #4
    la      r2, s_title_s
    ldr     r3, =(WHITE | F3)
    bne     1f
    la      r2, s_title_l
1:  lcall   text
    cmp     r4, #1
    mov     r0, #8
    mov     r1, #218
    la      r2, s_foot_s
    ldr     r3, =(FOOT | F3)
    bne     2f
    la      r2, s_foot_l
2:  lcall   text
    cmp     r4, #1
    popne   {r4, pc}
    ldr     ip, =STATE              @ last result, right of the title
    ldrb    r0, [ip, #S_RES]
    sub     r1, r0, #1
    cmp     r1, #(R_SENDFAIL - 1)
    pophi   {r4, pc}                @ 0 (none) or out of range: nothing
    la      r1, results
    ldr     r2, [r1, r0, lsl #2]
    ldr     r3, =(GREEN | F3)
    cmp     r0, #R_OK
    ldrne   r3, =(AMBER | F3)
    mov     r0, #312
    mov     r1, #4
    lcall   text_r
    pop     {r4, pc}

@ ---- Camera stats content (+0x4C)
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
4:  mov     r0, #12                 @ tone-curve row: loaded profile, else Leica's
    mov     r1, #176
    la      r2, s_curve
    ldr     r3, =(GREY | F3)
    lcall   text
    ldr     ip, =STATE
    mov     r0, #0
    strb    r0, [ip, #(S_NAME + 10)]    @ the name is always terminated
    ldrb    r0, [ip, #S_ACT]
    cmp     r0, #0
    add     r2, ip, #S_NAME
    beq     5f
    ldrb    r0, [r2]
    cmp     r0, #0
    bne     6f
5:  la      r2, s_stock
6:  mov     r0, #308
    mov     r1, #174
    ldr     r3, =(WHITE | F4)
    lcall   text_r
    add     sp, sp, #48
    pop     {r4-r6, pc}

take_name:                          @ (src, dst): "<1-8 letters/digits>.LUT" (any case) ->
    mov     r2, #0                  @ dst = NAME upper case + NUL; r0 = 1, else 0
1:  ldrb    r3, [r0, r2]
    cmp     r3, #'.'
    beq     2f
    cmp     r2, #8
    bhs     3f
    sub     ip, r3, #'a'
    cmp     ip, #26
    sublo   r3, r3, #32
    sub     ip, r3, #'0'
    cmp     ip, #10
    blo     4f
    sub     ip, r3, #'A'
    cmp     ip, #26
    bhs     3f
4:  strb    r3, [r1, r2]
    add     r2, r2, #1
    b       1b
2:  cmp     r2, #0
    beq     3f
    mov     ip, #0
    strb    ip, [r1, r2]
    add     r0, r0, r2
    ldrb    r3, [r0, #1]
    orr     r3, r3, #0x20
    cmp     r3, #'l'
    ldrbeq  r3, [r0, #2]
    orreq   r3, r3, #0x20
    cmpeq   r3, #'u'
    ldrbeq  r3, [r0, #3]
    orreq   r3, r3, #0x20
    cmpeq   r3, #'t'
    ldrbeq  r3, [r0, #4]
    cmpeq   r3, #0
    moveq   r0, #1
    bxeq    lr
3:  mov     r0, #0
    bx      lr

copy:                               @ (dst, src) -> r0 = dst's terminating NUL
1:  ldrb    r2, [r1], #1
    strb    r2, [r0], #1
    cmp     r2, #0
    bne     1b
    sub     r0, r0, #1
    bx      lr

    .align  2
    .ltorg

@ ---- bf_memtest2 entry (0x2B0E0): kept as a stub returning 0
    .org    0x2B0E0 - BASE
    mov     r0, #0
    bx      lr

@ ---- \PROFILES listing -> r0 = entries written to (r0 = list of MAXP x ENTRY bytes)
scan:
    push    {r4-r7, lr}
    sub     sp, sp, #260            @ name buffer (256) + attribute byte
    mov     r4, r0
    mov     r5, #0
    la      r0, s_dir
    fcall   OPENDIR
    movs    r6, r0
    beq     9f
1:  cmp     r5, #MAXP
    bhs     8f
    mov     r0, r6
    fcall   READDIR
    movs    r7, r0
    beq     8f
    mov     r1, sp
    fcall   GETNAME
    mov     r0, r7
    add     r1, sp, #256
    fcall   GETATTR
    ldrb    r0, [sp, #256]
    tst     r0, #0x16               @ directory, hidden, system: skip
    bne     1b
    mov     r0, r7
    fcall   GETSIZE
    ldr     r1, =GAMMA_SIZE
    cmp     r0, r1
    bne     1b
    mov     r0, sp
    mov     r1, #ENTRY
    mul     r1, r5, r1
    add     r1, r4, r1
    lcall   take_name
    cmp     r0, #0
    addne   r5, r5, #1
    b       1b
8:  mov     r0, r6
    fcall   CLOSEDIR
9:  mov     r0, r5
    add     sp, sp, #260
    pop     {r4-r7, pc}

@ ---- Picture profile content (+0x4C)
list_paint:                         @ (this)
    push    {r4-r8, lr}
    sub     sp, sp, #(MAXP * ENTRY)
    mov     r0, sp
    lcall   scan
    mov     r5, r0
    ldr     r6, =STATE
    strb    r5, [r6, #S_CNT]
    ldrb    r7, [r6, #S_SEL]
    cmp     r7, r5
    movhs   r7, #0
    strb    r7, [r6, #S_SEL]
    cmp     r5, #0
    bne     1f
    mov     r0, #12
    mov     r1, #90
    la      r2, s_none
    ldr     r3, =(WHITE | F3)
    lcall   text
    b       9f
1:  mov     r8, #0
2:  mov     r4, #ROWH
    mul     r4, r8, r4
    add     r4, r4, #ROW0           @ y of this row
    cmp     r8, r7
    bne     3f
    ldr     ip, =SEL
    mov     r0, #0
    mov     r1, r4
    mov     r2, #320
    mov     r3, #ROWH
    lcall   fill
3:  mov     r0, #ENTRY
    mul     r0, r8, r0
    add     r2, sp, r0
    mov     r0, #16
    mov     r1, r4
    ldr     r3, =(WHITE | F3)
    lcall   text
5:  add     r8, r8, #1
    cmp     r8, r5
    blo     2b
9:  add     sp, sp, #(MAXP * ENTRY)
    pop     {r4-r8, pc}


    .align  2
    .ltorg

    .align  2
vt_info:                            @ copy of 0xED1B8 with keys / title / content replaced
    .word   0xCD34C, 0xCD354, 0xCD35C, 0xCD364, 0x9A8D0, 0xD1E6C, 0xD1EB4, 0x9A47C
    .word   0xCD36C, 0x605AC, 0x9A8F0, BASE + (on_key - stub), 0x9ACD8, 0x9AD68, 0x9AD6C, 0x40360
    .word   0xCD370, 0xCD374, BASE + (title - stub), BASE + (content - stub), 0, 0

    .align  2
gamma_hdr:                          @ first 24 bytes of the stock GAMMA table (FINDINGS)
    .word   0x0E, 0x410, 0x1D0, 0x410, 15, 0x800
s_dir:    .asciz "\\PROFILES"
s_dirsep: .asciz "\\PROFILES\\"
s_ext:    .asciz ".LUT"
s_rb:     .asciz "rb"
    .align  2


@ ---- bf_memtest3 entry (0x2B338): kept as a stub returning 0
    .org    0x2B338 - BASE
    mov     r0, #0
    bx      lr

@ ---- data
    .align  2
rows:
    .word   s_shots - rows,      s_fmt_d - rows,  0x000E4     @ NumExposures (u32), as 0x61680
    .word   s_batt - (rows+12),  s_fmt_s - (rows+12), 0x200C8 @ battery state (byte), as 0x612D4
    .word   s_temp - (rows+24),  s_fmt_t - (rows+24), 0x000C4 @ temperature "normal", as 0x6124C
    .word   s_lens - (rows+36),  s_fmt_d - (rows+36), 0x100DD @ lens code (byte), as 0x615D8
batt:
    .word   b0 - batt, b1 - batt, b2 - batt, b3 - batt, b4 - batt, b5 - batt

s_nodata: .asciz "Body data unavailable"
s_shots:  .asciz "Shots taken"
s_batt:   .asciz "Battery"
s_temp:   .asciz "Temperature"
s_lens:   .asciz "Lens code"
s_curve:  .asciz "Tone curve"
s_stock:  .asciz "Leica (stock)"
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

    .align  2
results:                            @ result -> text (absolute addresses), 0 unused
    .word   0, BASE + (r_ok - stub), BASE + (r_nofile - stub), BASE + (r_badfile - stub)
    .word   BASE + (r_busy - stub), BASE + (r_sendfail - stub)
r_ok:       .asciz "Loaded"
r_nofile:   .asciz "Not found"
r_badfile:  .asciz "Bad file"
r_busy:     .asciz "Busy"
r_sendfail: .asciz "Failed"

@ ---- bf_checktrans entry (0x2B4B0): kept as a stub returning 0
    .org    0x2B4B0 - BASE
    mov     r0, #0
    bx      lr

@ ---- load the selected entry into the Blackfin's GAMMA table; result -> STATE+S_RES
load:
    push    {r4-r9, lr}
    sub     sp, sp, #(MAXP * ENTRY + 32)
    mov     r0, sp
    lcall   scan
    ldr     r8, =STATE
    ldrb    r9, [r8, #S_SEL]
    cmp     r9, r0
    movhs   r4, #R_NOFILE
    bhs     10f
    add     r0, sp, #(MAXP * ENTRY) @ path: \PROFILES\NAME.LUT
    la      r1, s_dirsep
    lcall   copy
    mov     r1, #ENTRY
    mul     r1, r9, r1
    add     r1, sp, r1
    lcall   copy
    la      r1, s_ext
    lcall   copy
    ldr     r0, =P_FILEBUF
    ldr     r0, [r0]
    mov     r1, #0
    fcall   BUF_TRY                 @ shared file buffer, without waiting
    movs    r5, r0
    moveq   r4, #R_BUSY
    beq     10f
    add     r0, sp, #(MAXP * ENTRY)
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
10: strb    r4, [r8, #S_RES]
    cmp     r4, #R_OK
    bne     11f
    mov     r0, #1
    strb    r0, [r8, #S_ACT]
    add     r0, r8, #S_NAME
    mov     r1, #ENTRY
    mul     r1, r9, r1
    add     r1, sp, r1
    lcall   copy                    @ <= 8 characters + NUL into the 12-byte field
11: add     sp, sp, #(MAXP * ENTRY + 32)
    pop     {r4-r9, pc}

    .align  2
    .ltorg

s_title_s:  .asciz "Camera stats"
s_title_l:  .asciz "Profiles"
s_foot_s:   .asciz "UP: profiles    SET: close"
s_foot_l:   .asciz "SET: load    INFO: close"
s_none:     .asciz "No profiles in \\PROFILES"
    .align  2
