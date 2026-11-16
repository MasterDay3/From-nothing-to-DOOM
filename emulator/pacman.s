; PAC-MAN для плати 65C02 PC
;
; Лабіринт 28x16 клітинок по 4x4 пікселі (112x64), справа 16 пікселів під рахунок
; і життя (текстовий шар ST7920). Стрілки — рух, MIDDLE — старт.
; Ритм гри задає таймер T1 VIA: переривання кожні 20 мс.
;
; Екран малюється в кадровий буфер у RAM; на дисплей передаються лише змінені
; 16-піксельні слова (ST7920 пише по 2 байти), бо кожен запис займає ~72 мкс.
.include "lcd.inc"

T1CL = $6004
T1CH = $6005
ACR  = $600B
IER  = $600E

FB    = $0200           ; кадровий буфер 128x64, 16 байтів на рядок (1 KB)
MAZE  = $0600           ; лабіринт 28x16 у RAM (448 байтів)
DIRTY = $0800           ; 128 прапорців "слово змінилось" (8 слів x 16 рядків клітинок)

MAZE_W = 28
TICK   = 20000 - 2      ; 20 мс при 1 MHz

PAC_SPEED    = 7        ; кадрів на крок
GHOST_SPEED  = 9
FRIGHT_SPEED = 14
FRIGHT_TIME  = 250      ; 5 с

; клітинки лабіринту (= номери гліфів 0-4)
C_EMPTY  = 0
C_WALL   = 1
C_DOT    = 2
C_PELLET = 3
C_DOOR   = 4
G_PAC    = 5            ; закритий рот
G_PAC_R  = 6            ; 6-9: рот праворуч, ліворуч, вгору, вниз
G_GHOST  = 10
G_FRIGHT = 11

D_RIGHT = 0             ; напрямок ^ 1 = протилежний
D_LEFT  = 1
D_UP    = 2
D_DOWN  = 3

BTN_MID   = %00001
BTN_UP    = %00010
BTN_DOWN  = %00100
BTN_LEFT  = %01000
BTN_RIGHT = %10000

PAC_X = 13
PAC_Y = 11
EXIT_X = 13             ; куди виходить привид із будиночка
EXIT_Y = 5

.zeropage
; сутності: 0 = Пакмен, 1-4 = привиди
ex:       .res 5
ey:       .res 5
edir:     .res 5
ecnt:     .res 5        ; лічильник кадрів до наступного кроку
gfright:  .res 5        ; привид наляканий
gwait:    .res 5        ; кадрів до виходу з будиночка (0 = на волі)

tick:     .res 1        ; збільшується в перериванні
rnd:      .res 1
want_dir: .res 1
anim:     .res 1
death:    .res 1
lives:    .res 1
score_lo: .res 1        ; BCD
score_hi: .res 1
hud_dirty: .res 1
dots_left: .res 1
fright_timer: .res 1
pac_cnt:  .res 1

cx:       .res 1        ; поточна клітинка для draw_tile / get_cell
cy:       .res 1
nx:       .res 1        ; результат next_pos
ny:       .res 1
ox:       .res 1        ; стара позиція
oy:       .res 1
ptr:      .res 2
ptr2:     .res 2
tmp:      .res 1
tmp2:     .res 1
goff:     .res 1
cnt:      .res 1
dloop:    .res 1        ; вибір напрямку привида
best:     .res 1
bestd:    .res 1
rmode:    .res 1
fw_y:     .res 1
fw_cw:    .res 1
fw_n:     .res 1

.segment "CODE"
reset:
    ldx #$FF
    txs
    sei
    jsr via_init
    jsr lcd_init

    lda #%01000000      ; T1 вільний біг, IRQ кожні 20 мс
    sta ACR
    lda #<TICK
    sta T1CL
    lda #>TICK
    sta T1CH
    lda #%11000000
    sta IER
    stz tick
    cli

title:
    jsr text_screen
    PRINT ROW1, s_title
    PRINT ROW3, s_press
@seed:                  ; поки гравець думає, крутимо генератор
    inc rnd
    lda PORTA
    and #BTN_MID
    bne @seed
    lda rnd
    ora #1              ; нуль "заклинює" генератор
    sta rnd
    jsr wait_release

new_game:
    stz score_lo
    stz score_hi
    lda #3
    sta lives

new_level:
    jsr level_init
    jsr reset_positions
    jsr full_redraw
    lda #50             ; 1 с на підготовку
    jsr pause

game_loop:
    jsr wait_tick
    jsr read_input

    inc pac_cnt
    lda pac_cnt
    cmp #PAC_SPEED
    bcc @ghosts
    stz pac_cnt
    jsr pac_step

@ghosts:
    ldx #1
@gloop:
    lda gwait,x
    bne @gnext
    inc ecnt,x
    lda #GHOST_SPEED
    ldy gfright,x
    beq @speed
    lda #FRIGHT_SPEED
@speed:
    sta tmp
    lda ecnt,x
    cmp tmp
    bcc @gnext
    stz ecnt,x
    jsr ghost_step
@gnext:
    inx
    cpx #5
    bne @gloop

    jsr release_ghosts
    jsr fright_tick
    jsr flush

    lda hud_dirty
    beq @nohud
    stz hud_dirty
    jsr draw_hud
@nohud:
    lda death
    bne died
    lda dots_left
    bne game_loop
    lda #50             ; рівень пройдено
    jsr pause
    jmp new_level

died:
    stz death
    lda #50
    jsr pause
    dec lives
    beq game_over
    jsr reset_positions
    jsr full_redraw
    lda #50
    jsr pause
    jmp game_loop

game_over:
    jsr text_screen
    PRINT ROW1, s_over
    PRINT ROW2, s_score
    lda score_hi
    jsr put_bcd
    lda score_lo
    jsr put_bcd
    PRINT ROW4, s_again
@wait:
    lda PORTA
    and #BTN_MID
    bne @wait
    jsr wait_release
    jmp new_game

; ---------------------------------------------------------------------------
; Рівень і позиції

level_init:             ; скопіювати лабіринт з ROM у RAM, порахувати точки
    lda #<maze_rom
    sta ptr2
    lda #>maze_rom
    sta ptr2+1
    lda #<MAZE
    sta ptr
    lda #>MAZE
    sta ptr+1
    stz dots_left
    ldx #16
@row:
    ldy #0
@col:
    lda (ptr2),y
    cmp #'#'
    bne @n1
    lda #C_WALL
    bra @store
@n1:
    cmp #'.'
    bne @n2
    inc dots_left
    lda #C_DOT
    bra @store
@n2:
    cmp #'o'
    bne @n3
    inc dots_left
    lda #C_PELLET
    bra @store
@n3:
    cmp #'-'
    bne @n4
    lda #C_DOOR
    bra @store
@n4:
    lda #C_EMPTY
@store:
    sta (ptr),y
    iny
    cpy #MAZE_W
    bne @col
    clc
    lda ptr
    adc #MAZE_W
    sta ptr
    bcc @p1
    inc ptr+1
@p1:
    clc
    lda ptr2
    adc #MAZE_W
    sta ptr2
    bcc @p2
    inc ptr2+1
@p2:
    dex
    bne @row

    lda #PAC_X          ; на стартовій клітинці точки немає
    sta cx
    lda #PAC_Y
    sta cy
    lda #C_EMPTY
    jsr set_cell
    dec dots_left
    rts

reset_positions:
    lda #PAC_X
    sta ex
    lda #PAC_Y
    sta ey
    lda #D_LEFT
    sta edir
    sta want_dir
    stz pac_cnt
    stz fright_timer
    stz death
    ldx #4
@g:
    lda home_x,x
    sta ex,x
    lda #7
    sta ey,x
    lda release_time,x
    sta gwait,x
    lda #D_LEFT
    sta edir,x
    stz ecnt,x
    stz gfright,x
    dex
    bne @g
    rts

; ---------------------------------------------------------------------------
; Пакмен

read_input:
    lda PORTA
    eor #$FF            ; 1 = натиснута
    bit #BTN_RIGHT
    beq @l
    ldy #D_RIGHT
    bra @set
@l:
    bit #BTN_LEFT
    beq @u
    ldy #D_LEFT
    bra @set
@u:
    bit #BTN_UP
    beq @d
    ldy #D_UP
    bra @set
@d:
    bit #BTN_DOWN
    beq @none
    ldy #D_DOWN
@set:
    sty want_dir
@none:
    rts

pac_step:
    lda ex
    sta ox
    lda ey
    sta oy
    ldx #0
    lda want_dir        ; повернути, якщо можна
    jsr next_pos
    bcc @keep
    lda want_dir
    sta edir
@keep:
    lda edir
    jsr next_pos
    bcc @redraw         ; уперлися в стіну
    lda nx
    sta ex
    sta cx
    lda ny
    sta ey
    sta cy
    jsr get_cell
    cmp #C_DOT
    bne @pellet
    lda #C_EMPTY
    jsr set_cell
    dec dots_left
    lda #$01
    jsr add_score
    bra @redraw
@pellet:
    cmp #C_PELLET
    bne @redraw
    lda #C_EMPTY
    jsr set_cell
    dec dots_left
    lda #$05
    jsr add_score
    jsr frighten
@redraw:
    inc anim
    lda ox
    sta cx
    lda oy
    sta cy
    jsr draw_tile
    lda ex
    sta cx
    lda ey
    sta cy
    jsr draw_tile

    ldx #1              ; зіткнення з привидами
@coll:
    lda gwait,x
    bne @cnext
    lda ex,x
    cmp ex
    bne @cnext
    lda ey,x
    cmp ey
    bne @cnext
    jsr hit_ghost
@cnext:
    inx
    cpx #5
    bne @coll
    rts

; Пакмен і привид X на одній клітинці
hit_ghost:
    lda gfright,x
    bne eat_ghost
    lda #1
    sta death
    rts

eat_ghost:              ; X = привид; повертається в будиночок
    lda ex,x
    sta cx
    lda ey,x
    sta cy
    lda home_x,x
    sta ex,x
    lda #7
    sta ey,x
    stz gfright,x
    lda #150
    sta gwait,x
    phx
    jsr draw_tile       ; стара клітинка
    plx
    phx
    lda ex,x
    sta cx
    lda ey,x
    sta cy
    jsr draw_tile       ; будиночок
    plx
    lda #$10
    jmp add_score

frighten:
    lda #FRIGHT_TIME
    sta fright_timer
    ldx #1
@g:
    lda gwait,x
    bne @n
    lda #1
    sta gfright,x
    lda edir,x          ; налякані привиди розвертаються
    eor #1
    sta edir,x
@n:
    inx
    cpx #5
    bne @g
    jmp redraw_ghosts

fright_tick:
    lda fright_timer
    beq @r
    dec fright_timer
    bne @r
    ldx #1
@g:
    stz gfright,x
    inx
    cpx #5
    bne @g
    jmp redraw_ghosts
@r:
    rts

redraw_ghosts:
    ldx #1
@g:
    phx
    lda ex,x
    sta cx
    lda ey,x
    sta cy
    jsr draw_tile
    plx
    inx
    cpx #5
    bne @g
    rts

; ---------------------------------------------------------------------------
; Привиди

release_ghosts:
    ldx #1
@g:
    lda gwait,x
    beq @n
    dec gwait,x
    bne @n
    lda ex,x            ; вихід із будиночка
    sta cx
    lda ey,x
    sta cy
    lda #EXIT_X
    sta ex,x
    lda #EXIT_Y
    sta ey,x
    lda #D_LEFT
    sta edir,x
    phx
    jsr draw_tile
    plx
    phx
    lda #EXIT_X
    sta cx
    lda #EXIT_Y
    sta cy
    jsr draw_tile
    plx
@n:
    inx
    cpx #5
    bne @g
    rts

; Крок привида X. На кожній клітинці обирає напрямок (без розвороту):
; привид 1 женеться за Пакменом, 2-4 іноді блукають, налякані — випадково.
ghost_step:
    lda ex,x
    sta ox
    lda ey,x
    sta oy

    lda gfright,x       ; режим вибору: 0 = погоня, 1 = випадково
    bne @random
    cpx #2
    bcc @chase
    jsr random
    and #1
    bra @mode
@random:
    lda #1
    bra @mode
@chase:
    lda #0
@mode:
    sta rmode

    lda #$FF
    sta best
    sta bestd
    stz dloop
@try:
    lda edir,x
    eor #1
    cmp dloop
    beq @next           ; не розвертатися
    lda dloop
    jsr next_pos
    bcc @next
    lda rmode
    beq @dist
    jsr random
    and #$7F
    bra @cmp
@dist:                  ; |nx - pac_x| + |ny - pac_y|
    lda nx
    sec
    sbc ex
    bcs @ax
    eor #$FF
    inc a
@ax:
    sta tmp2
    lda ny
    sec
    sbc ey
    bcs @ay
    eor #$FF
    inc a
@ay:
    clc
    adc tmp2
@cmp:
    cmp best
    bcs @next
    sta best
    lda dloop
    sta bestd
@next:
    inc dloop
    lda dloop
    cmp #4
    bne @try

    lda bestd
    cmp #$FF
    bne @go
    lda edir,x          ; глухий кут: розвертаємося
    eor #1
    sta bestd
@go:
    lda bestd
    sta edir,x
    jsr next_pos
    bcc @drawn
    lda nx
    sta ex,x
    lda ny
    sta ey,x
@drawn:
    phx
    lda ox
    sta cx
    lda oy
    sta cy
    jsr draw_tile
    plx
    phx
    lda ex,x
    sta cx
    lda ey,x
    sta cy
    jsr draw_tile
    plx

    lda ex,x            ; зіткнення з Пакменом
    cmp ex
    bne @r
    lda ey,x
    cmp ey
    bne @r
    jmp hit_ghost
@r:
    rts

; ---------------------------------------------------------------------------
; Лабіринт

; A = напрямок, X = сутність -> nx, ny; carry = 1, якщо туди можна піти
next_pos:
    tay
    lda ex,x
    clc
    adc dx_tab,y
    cmp #$FF            ; тунель: з лівого краю на правий і навпаки
    bne @r
    lda #MAZE_W - 1
    bra @x
@r:
    cmp #MAZE_W
    bne @x
    lda #0
@x:
    sta nx
    lda ey,x
    clc
    adc dy_tab,y
    sta ny
    lda nx
    sta cx
    lda ny
    sta cy
    jsr get_cell
    cmp #C_WALL
    beq @no
    cmp #C_DOOR
    beq @no
    sec
    rts
@no:
    clc
    rts

; A = клітинка (cx, cy)
get_cell:
    ldy cy
    lda row_lo,y
    sta ptr
    lda row_hi,y
    sta ptr+1
    ldy cx
    lda (ptr),y
    rts

; клітинка (cx, cy) = A
set_cell:
    pha
    ldy cy
    lda row_lo,y
    sta ptr
    lda row_hi,y
    sta ptr+1
    ldy cx
    pla
    sta (ptr),y
    rts

; ---------------------------------------------------------------------------
; Графіка

; Намалювати клітинку (cx, cy) у кадровий буфер. Псує X, Y.
draw_tile:
    lda ex
    cmp cx
    bne @ghosts
    lda ey
    cmp cy
    bne @ghosts
    lda anim            ; Пакмен: рот відкривається через крок
    and #1
    beq @closed
    lda edir
    clc
    adc #G_PAC_R
    bra @have
@closed:
    lda #G_PAC
    bra @have
@ghosts:
    ldx #4
@gl:
    lda ex,x
    cmp cx
    bne @gn
    lda ey,x
    cmp cy
    bne @gn
    lda gfright,x
    beq @gnorm
    lda #G_FRIGHT
    bra @have
@gnorm:
    lda #G_GHOST
    bra @have
@gn:
    dex
    bne @gl
    jsr get_cell        ; код клітинки = номер гліфа
@have:
    asl
    asl
    sta goff

    lda cy              ; ptr2 = FB + cy*64 + cx/2
    lsr
    lsr
    clc
    adc #>FB
    sta ptr2+1
    lda cy
    and #3
    asl
    asl
    asl
    asl
    asl
    asl
    sta ptr2
    lda cx
    lsr
    clc
    adc ptr2
    sta ptr2

    lda #4
    sta cnt
    ldx goff
    ldy #0
    lda cx
    and #1
    bne @low
@high:                  ; парна клітинка: старші 4 біти байта
    lda glyphs,x
    asl
    asl
    asl
    asl
    sta tmp
    lda (ptr2),y
    and #$0F
    ora tmp
    sta (ptr2),y
    inx
    tya
    clc
    adc #16
    tay
    dec cnt
    bne @high
    bra @dirty
@low:                   ; непарна: молодші 4 біти
    lda (ptr2),y
    and #$F0
    ora glyphs,x
    sta (ptr2),y
    inx
    tya
    clc
    adc #16
    tay
    dec cnt
    bne @low
@dirty:                 ; DIRTY[cy*8 + cx/4] = 1
    lda cy
    asl
    asl
    asl
    sta tmp
    lda cx
    lsr
    lsr
    ora tmp
    tax
    lda #1
    sta DIRTY,x
    rts

; Передати на дисплей усі змінені слова
flush:
    ldx #0
@loop:
    lda DIRTY,x
    beq @next
    stz DIRTY,x
    phx
    jsr flush_word
    plx
@next:
    inx
    bpl @loop
    rts

; X = номер слова: 4 рядки пікселів по 16 пікселів
flush_word:
    txa
    and #7
    sta fw_cw
    txa
    lsr
    lsr
    lsr
    asl
    asl
    sta fw_y
    lda #4
    sta fw_n
@row:
    lda fw_y            ; рядки 32-63 у GDRAM лежать праворуч від 0-31
    cmp #32
    bcs @bottom
    ora #$80
    jsr lcd_cmd
    lda fw_cw
    ora #$80
    jsr lcd_cmd
    bra @data
@bottom:
    sbc #32
    ora #$80
    jsr lcd_cmd
    lda fw_cw
    ora #$88
    jsr lcd_cmd
@data:
    lda fw_y            ; ptr2 = FB + y*16
    lsr
    lsr
    lsr
    lsr
    clc
    adc #>FB
    sta ptr2+1
    lda fw_y
    asl
    asl
    asl
    asl
    sta ptr2
    lda fw_cw
    asl
    tay
    lda (ptr2),y
    jsr lcd_data
    iny
    lda (ptr2),y
    jsr lcd_data
    inc fw_y
    dec fw_n
    bne @row
    rts

; Перемалювати весь екран
full_redraw:
    lda #$30            ; текстовий шар: очистити
    jsr lcd_cmd
    lda #$01
    jsr lcd_cmd

    lda #<FB            ; кадровий буфер = 0
    sta ptr2
    lda #>FB
    sta ptr2+1
    ldx #4
    ldy #0
    lda #0
@clr:
    sta (ptr2),y
    iny
    bne @clr
    inc ptr2+1
    dex
    bne @clr

    ldx #127            ; передати весь екран (зокрема праву смугу зі сміттям)
    lda #1
@d:
    sta DIRTY,x
    dex
    bpl @d

    stz cy
@ry:
    stz cx
@rx:
    jsr draw_tile
    inc cx
    lda cx
    cmp #MAZE_W
    bne @rx
    inc cy
    lda cy
    cmp #16
    bne @ry

    lda #$34            ; розширений набір команд, графіка поки вимкнена
    jsr lcd_cmd
    jsr flush
    lda #$36            ; увімкнути графіку
    jsr lcd_cmd
    jmp draw_hud

; Рахунок (4 цифри) і життя в правій смузі текстового шару
draw_hud:
    lda #$30
    jsr lcd_cmd
    lda #(ROW1 + 7)
    jsr lcd_cmd
    lda score_hi
    jsr put_bcd
    lda #(ROW2 + 7)
    jsr lcd_cmd
    lda score_lo
    jsr put_bcd
    lda #(ROW4 + 7)
    jsr lcd_cmd
    lda #'L'
    jsr lcd_data
    lda lives
    ora #'0'
    jsr lcd_data
    lda #$36
    jmp lcd_cmd

; ---------------------------------------------------------------------------
; Допоміжне

text_screen:            ; вимкнути графіку, очистити текст
    lda #$34
    jsr lcd_cmd
    lda #$30
    jsr lcd_cmd
    lda #$01
    jmp lcd_cmd

put_bcd:                ; A = дві BCD-цифри
    pha
    lsr
    lsr
    lsr
    lsr
    ora #'0'
    jsr lcd_data
    pla
    and #$0F
    ora #'0'
    jmp lcd_data

add_score:              ; A = BCD
    sed
    clc
    adc score_lo
    sta score_lo
    lda score_hi
    adc #0
    sta score_hi
    cld
    lda #1
    sta hud_dirty
    rts

random:                 ; 8-бітний LFSR
    lda rnd
    asl
    bcc @r
    eor #$1D
@r:
    sta rnd
    rts

wait_tick:
    wai
    lda tick
    beq wait_tick
    stz tick
    rts

pause:                  ; A = кількість кадрів по 20 мс
    sta cnt
@w:
    jsr wait_tick
    dec cnt
    bne @w
    rts

wait_release:           ; чекати, поки всі кнопки відпущені (+ антибрязкіт)
    lda #2
    jsr pause
@w:
    lda PORTA
    and #$1F
    cmp #$1F
    bne @w
    lda #2
    jmp pause

irq:
    bit T1CL            ; скинути прапорець T1
    inc tick
nmi:
    rti

; ---------------------------------------------------------------------------
.segment "RODATA"

s_title: .byte "PAC-MAN 65C02", 0
s_press: .byte "PRESS MIDDLE", 0
s_over:  .byte "GAME OVER", 0
s_score: .byte "SCORE: ", 0
s_again: .byte "MIDDLE = AGAIN", 0

dx_tab: .byte 1, $FF, 0, 0
dy_tab: .byte 0, 0, $FF, 1

home_x:       .byte 0, 12, 13, 14, 15
release_time: .byte 0, 50, 120, 190, 250

row_lo:
.repeat 16, I
    .byte <(MAZE + I * MAZE_W)
.endrepeat
row_hi:
.repeat 16, I
    .byte >(MAZE + I * MAZE_W)
.endrepeat

; гліфи 4x4 (молодші 4 біти, старший біт = лівий піксель)
glyphs:
    .byte %0000, %0000, %0000, %0000    ; 0 порожньо
    .byte %1111, %1111, %1111, %1111    ; 1 стіна
    .byte %0000, %0100, %0000, %0000    ; 2 точка
    .byte %0000, %0110, %0110, %0000    ; 3 енерджайзер
    .byte %0000, %1111, %0000, %0000    ; 4 двері будиночка
    .byte %0110, %1111, %1111, %0110    ; 5 Пакмен, рот закритий
    .byte %0110, %1100, %1100, %0110    ; 6 рот праворуч
    .byte %0110, %0011, %0011, %0110    ; 7 ліворуч
    .byte %1001, %1001, %1111, %0110    ; 8 вгору
    .byte %0110, %1111, %1001, %1001    ; 9 вниз
    .byte %0110, %1111, %1111, %1010    ; 10 привид
    .byte %0110, %1001, %1001, %1010    ; 11 наляканий привид

maze_rom:
    .byte "############################"
    .byte "#......#............#......#"
    .byte "#o##.#.#.####..####.#.#.##o#"
    .byte "#....#.......##.......#....#"
    .byte "###.##.###.#.##.#.###.##.###"
    .byte "#..........................#"
    .byte "#.###.#.#.###--###.#.#.###.#"
    .byte "......#.#.#      #.#.#......"
    .byte "#.###.#.#.########.#.#.###.#"
    .byte "#.....#..............#.....#"
    .byte "###.#####.#.####.#.#####.###"
    .byte "#.........#......#.........#"
    .byte "#o##.###.####..####.###.##o#"
    .byte "#....#......#..#......#....#"
    .byte "#...#..##..........##..#...#"
    .byte "############################"

.segment "VECTORS"
    .word nmi, reset, irq
