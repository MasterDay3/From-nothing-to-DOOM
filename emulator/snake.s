; SNAKE для плати 65C02 PC
;
; Поле 28x16 клітинок по 4x4 пікселі (112x64), справа 16 пікселів під рахунок
; (текстовий шар ST7920). Стрілки — напрямок руху, MIDDLE — старт / повтор.
; Ритм гри задає таймер T1 VIA: переривання кожні 20 мс.
.include "lcd.inc"

T1CL = $6004
T1CH = $6005
ACR  = $600B
IER  = $600E

FB     = $0200          ; кадровий буфер 128x64, 16 байтів на рядок (1 KB)
GRID   = $0600          ; поле 28x16 у RAM (448 байтів)
DIRTY  = $0800          ; 128 прапорців "слово змінилось" (8 слів x 16 рядків клітинок)
BODY_X = $0900          ; кільцевий буфер X-координат сегментів змійки (256 байтів)
BODY_Y = $0A00          ; кільцевий буфер Y-координат сегментів змійки (256 байтів)

GRID_W      = 28
GRID_H      = 16
TICK        = 20000 - 2 ; 20 мс при 1 MHz
SNAKE_SPEED = 6         ; кадрів на крок (120 мс)
MAX_LEN     = 240

; клітинки поля (= номери гліфів 0-4)
C_EMPTY = 0
C_WALL  = 1
C_BODY  = 2
C_HEAD  = 3
C_FOOD  = 4

D_RIGHT = 0             ; напрямок ^ 1 = протилежний
D_LEFT  = 1
D_UP    = 2
D_DOWN  = 3

BTN_MID   = %00001
BTN_UP    = %00010
BTN_DOWN  = %00100
BTN_LEFT  = %01000
BTN_RIGHT = %10000

.zeropage
tick:      .res 1       ; збільшується в перериванні
rnd:       .res 1
sdir:      .res 1
want_dir:  .res 1
step_cnt:  .res 1
dead:      .res 1
score_lo:  .res 1       ; BCD
score_hi:  .res 1
hud_dirty: .res 1

head_x:    .res 1
head_y:    .res 1
head_idx:  .res 1
tail_idx:  .res 1
snake_len: .res 1

cx:        .res 1       ; поточна клітинка для draw_tile / get_cell
cy:        .res 1
nx:        .res 1       ; наступна клітинка голови
ny:        .res 1
ptr:       .res 2
ptr2:      .res 2
tmp:       .res 1
goff:      .res 1
cnt:       .res 1
fw_y:      .res 1
fw_cw:     .res 1
fw_n:      .res 1

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
    ora #1              ; нуль "заклинює" LFSR
    sta rnd
    jsr wait_release

new_game:
    stz score_lo
    stz score_hi
    stz dead
    stz step_cnt
    stz hud_dirty

    jsr grid_init
    jsr snake_init
    jsr spawn_food
    jsr full_redraw
    lda #25             ; 0.5 с на підготовку
    jsr pause

game_loop:
    jsr wait_tick
    jsr read_input

    inc step_cnt
    lda step_cnt
    cmp #SNAKE_SPEED
    bcc @flush
    stz step_cnt
    jsr snake_step

@flush:
    jsr flush
    lda hud_dirty
    beq @check_dead
    stz hud_dirty
    jsr draw_hud
@check_dead:
    lda dead
    beq game_loop

game_over:
    lda #35
    jsr pause
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
; Ініціалізація поля і змійки

grid_init:
    stz cy
@row:
    stz cx
@col:
    lda cy
    beq @wall
    cmp #(GRID_H - 1)
    beq @wall
    lda cx
    beq @wall
    cmp #(GRID_W - 1)
    beq @wall
    lda #C_EMPTY
    bra @store
@wall:
    lda #C_WALL
@store:
    jsr set_cell
    inc cx
    lda cx
    cmp #GRID_W
    bne @col
    inc cy
    lda cy
    cmp #GRID_H
    bne @row
    rts

snake_init:
    stz tail_idx
    lda #2
    sta head_idx
    lda #3
    sta snake_len
    lda #D_RIGHT
    sta sdir
    sta want_dir
    lda #14
    sta head_x
    lda #8
    sta head_y

    lda #12
    sta BODY_X
    lda #13
    sta BODY_X+1
    lda #14
    sta BODY_X+2
    lda #8
    sta BODY_Y
    sta BODY_Y+1
    sta BODY_Y+2

    sta cy
    lda #12
    sta cx
    lda #C_BODY
    jsr set_cell
    lda #13
    sta cx
    lda #C_BODY
    jsr set_cell
    lda #14
    sta cx
    lda #C_HEAD
    jmp set_cell

; ---------------------------------------------------------------------------
; Керування і крок змійки

read_input:
    lda PORTA
    eor #$FF            ; 1 = натиснута
    sta tmp
    and #(BTN_LEFT | BTN_RIGHT)
    cmp #(BTN_LEFT | BTN_RIGHT)
    beq @none           ; ігнорувати вихід у меню (LEFT+RIGHT)

    lda tmp
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

snake_step:
    lda want_dir        ; заборонити миттєвий розворот на 180 градусів
    eor #1
    cmp sdir
    beq @keep_dir
    lda want_dir
    sta sdir
@keep_dir:
    ldy sdir
    lda head_x
    clc
    adc dx_tab,y
    sta nx
    lda head_y
    clc
    adc dy_tab,y
    sta ny

    lda nx
    sta cx
    lda ny
    sta cy
    jsr get_cell
    cmp #C_FOOD
    beq @eat
    cmp #C_EMPTY
    bne @hit
    jsr pop_tail
    jmp advance_head
@eat:
    lda snake_len
    cmp #MAX_LEN
    bcs @full
    inc snake_len
    bra @grow
@full:
    jsr pop_tail
@grow:
    jsr advance_head
    lda #$01
    jsr add_score
    jmp spawn_food
@hit:
    lda #1
    sta dead
    rts

pop_tail:
    ldx tail_idx
    lda BODY_X,x
    sta cx
    lda BODY_Y,x
    sta cy
    inc tail_idx
    lda #C_EMPTY
    jsr set_cell
    jmp draw_tile

advance_head:
    lda head_x
    sta cx
    lda head_y
    sta cy
    lda #C_BODY
    jsr set_cell
    jsr draw_tile

    inc head_idx
    ldx head_idx
    lda nx
    sta head_x
    sta cx
    sta BODY_X,x
    lda ny
    sta head_y
    sta cy
    sta BODY_Y,x
    lda #C_HEAD
    jsr set_cell
    jmp draw_tile

spawn_food:
    jsr random
    and #$0F
@ymod:
    cmp #14
    bcc @yset
    sbc #14
    bra @ymod
@yset:
    inc a
    sta cy

    jsr random
    and #$1F
@xmod:
    cmp #26
    bcc @xset
    sbc #26
    bra @xmod
@xset:
    inc a
    sta cx

@find:
    jsr get_cell
    cmp #C_EMPTY
    beq @place
    inc cx
    lda cx
    cmp #(GRID_W - 1)
    bcc @find
    lda #1
    sta cx
    inc cy
    lda cy
    cmp #(GRID_H - 1)
    bcc @find
    lda #1
    sta cy
    bra @find
@place:
    lda #C_FOOD
    jsr set_cell
    jmp draw_tile

; ---------------------------------------------------------------------------
; Поле і графіка (4x4 клітинки в кадровому буфері)

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

; Намалювати клітинку (cx, cy) у кадровий буфер. Псує X, Y.
draw_tile:
    jsr get_cell
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

; Передати на дисплей усі змінені 16-піксельні слова
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

    ldx #127
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
    cmp #GRID_W
    bne @rx
    inc cy
    lda cy
    cmp #GRID_H
    bne @ry

    lda #$34            ; розширений набір команд, графіка поки вимкнена
    jsr lcd_cmd
    jsr flush
    lda #$36            ; увімкнути графіку
    jsr lcd_cmd
    jmp draw_hud

; Рахунок (4 BCD-цифри) у правій смузі текстового шару
draw_hud:
    lda #$30
    jsr lcd_cmd
    lda #(ROW1 + 7)
    jsr lcd_cmd
    lda #'S'
    jsr lcd_data
    lda #'C'
    jsr lcd_data
    lda #(ROW2 + 7)
    jsr lcd_cmd
    lda score_hi
    jsr put_bcd
    lda #(ROW3 + 7)
    jsr lcd_cmd
    lda score_lo
    jsr put_bcd
    lda #$36
    jmp lcd_cmd

; ---------------------------------------------------------------------------
; Допоміжне

text_screen:            ; очистити GDRAM, вимкнути графіку, очистити текст
    lda #$36
    jsr lcd_cmd
    ldx #0
@gd_row:
    txa
    ora #$80
    jsr lcd_cmd
    lda #$80
    jsr lcd_cmd
    ldy #32
@gd_byte:
    lda #0
    jsr lcd_data
    dey
    bne @gd_byte
    inx
    cpx #32
    bne @gd_row
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

s_title: .byte "SNAKE 65C02", 0
s_press: .byte "PRESS MIDDLE", 0
s_over:  .byte "GAME OVER", 0
s_score: .byte "SCORE: ", 0
s_again: .byte "MIDDLE = AGAIN", 0

dx_tab: .byte 1, $FF, 0, 0
dy_tab: .byte 0, 0, $FF, 1

row_lo:
.repeat GRID_H, I
    .byte <(GRID + I * GRID_W)
.endrepeat
row_hi:
.repeat GRID_H, I
    .byte >(GRID + I * GRID_W)
.endrepeat

; гліфи 4x4 (молодші 4 біти, біт 3 = лівий піксель)
glyphs:
    .byte %0000, %0000, %0000, %0000    ; 0 порожньо
    .byte %1111, %1111, %1111, %1111    ; 1 стіна
    .byte %0110, %1111, %1111, %0110    ; 2 тіло змійки
    .byte %1111, %1001, %1001, %1111    ; 3 голова змійки
    .byte %0100, %1010, %0100, %0000    ; 4 їжа

.segment "VECTORS"
    .word nmi, reset, irq
