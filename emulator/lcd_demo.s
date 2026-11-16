; Демо текстового режиму: напис на дисплеї і стан кнопок
.include "lcd.inc"

.zeropage
btn: .res 1

.segment "CODE"
reset:
    ldx #$FF
    txs
    jsr via_init
    jsr lcd_init

    lda #$80            ; рядок 1
    jsr lcd_cmd
    ldx #<msg1
    ldy #>msg1
    jsr lcd_print

    lda #$90            ; рядок 2
    jsr lcd_cmd
    ldx #<msg2
    ldy #>msg2
    jsr lcd_print

main:
    lda #$88            ; рядок 3: стан кнопок
    jsr lcd_cmd
    lda PORTA
    sta btn
    ldx #5
@next:
    lsr btn             ; наступна кнопка в carry (0 = натиснута)
    lda #'#'
    bcc @show
    lda #'.'
@show:
    jsr lcd_data
    lda #' '
    jsr lcd_data
    dex
    bne @next
    bra main

nmi:
irq:
    rti

.segment "RODATA"
msg1: .byte "HELLO 65C02 PC!", 0
msg2: .byte "M U D L R", 0

.segment "VECTORS"
    .word nmi, reset, irq
