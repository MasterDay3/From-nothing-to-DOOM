; Гра "Вгадай число" (1-99)
; UP/DOWN: +1/-1, RIGHT/LEFT: +10/-10, MIDDLE: перевірити
.include "lcd.inc"

BTN_MID   = %00001
BTN_UP    = %00010
BTN_DOWN  = %00100
BTN_LEFT  = %01000
BTN_RIGHT = %10000


.zeropage
secret: .res 1
guess:  .res 1
tries:  .res 1
seed:   .res 1
key:    .res 1

.segment "CODE"
reset:
    ldx #$FF
    txs
    jsr via_init
    jsr lcd_init

new_game:
    jsr lcd_clear
    PRINT ROW1, s_title
    PRINT ROW3, s_press

    ; Випадкове число: лічильник крутиться, поки гравець не натисне MIDDLE
@wait:
    inc seed
    lda PORTA
    and #BTN_MID
    bne @wait
    jsr wait_release

    lda seed            ; secret = seed mod 99 + 1
@mod:
    cmp #99
    bcc @ok
    sbc #99
    bra @mod
@ok:
    adc #1              ; carry тут 0
    sta secret
    lda #50
    sta guess
    stz tries

    jsr lcd_clear
    PRINT ROW1, s_range
    PRINT ROW2, s_help

play:
    PRINT ROW3, s_guess
    lda guess
    jsr lcd_num

    jsr get_key
    bit #BTN_MID
    bne check
    bit #BTN_UP
    bne @up
    bit #BTN_DOWN
    bne @down
    bit #BTN_RIGHT
    bne @right
    ; LEFT: -10, але не менше 1
    lda guess
    sec
    sbc #10
    bcc @min
    beq @min
    bra @set
@min:
    lda #1
    bra @set
@right:                 ; +10, але не більше 99
    lda guess
    clc
    adc #10
    cmp #100
    bcc @set
    lda #99
    bra @set
@up:
    lda guess
    cmp #99
    beq play
    inc a
    bra @set
@down:
    lda guess
    cmp #1
    beq play
    dec a
@set:
    sta guess
    bra play

check:
    inc tries
    lda guess
    cmp secret
    beq win
    bcc @low
    PRINT ROW4, s_high
    bra play
@low:
    PRINT ROW4, s_low
    bra play

win:
    jsr lcd_clear
    PRINT ROW1, s_win
    PRINT ROW2, s_number
    lda secret
    jsr lcd_num
    PRINT ROW3, s_tries
    lda tries
    jsr lcd_num
    PRINT ROW4, s_again
@w:
    jsr get_key
    bit #BTN_MID
    beq @w
    jmp new_game

; ---------------------------------------------------------------------------

lcd_clear:
    lda #$01
    jmp lcd_cmd

; Чекати натискання будь-якої кнопки; повертає в A маску натиснутих (1 = натиснута)
get_key:
    lda PORTA
    eor #$FF
    and #$1F
    beq get_key
    sta key
    jsr delay           ; антибрязкіт
    jsr wait_release
    lda key
    rts

; Чекати, поки всі кнопки відпущені
wait_release:
    lda PORTA
    and #$1F
    cmp #$1F
    bne wait_release
    jmp delay

; Затримка ~13 мс при 1 MHz
delay:
    ldx #10
@outer:
    ldy #0
@inner:
    dey
    bne @inner
    dex
    bne @outer
    rts

nmi:
irq:
    rti

.segment "RODATA"
s_title:  .byte "GUESS THE NUMBER", 0
s_press:  .byte "PRESS MIDDLE", 0
s_range:  .byte "NUMBER 1-99", 0
s_help:   .byte "U/D:1  L/R:10", 0
s_guess:  .byte "GUESS: ", 0
s_low:    .byte "TOO LOW!  ", 0
s_high:   .byte "TOO HIGH! ", 0
s_win:    .byte "CORRECT!", 0
s_number: .byte "NUMBER: ", 0
s_tries:  .byte "TRIES:  ", 0
s_again:  .byte "MIDDLE = AGAIN", 0

.segment "VECTORS"
    .word nmi, reset, irq
