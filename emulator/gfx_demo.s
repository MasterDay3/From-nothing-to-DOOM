; Демо графічного режиму: заповнює екран смугастим візерунком
.include "lcd.inc"

.zeropage
row: .res 1

.segment "CODE"
reset:
    ldx #$FF
    txs
    jsr via_init
    jsr lcd_init

    lda #$34            ; розширений набір команд
    jsr lcd_cmd

    stz row
@rows:
    lda row
    ora #$80            ; вертикальна адреса (0-31)
    jsr lcd_cmd
    lda #$80            ; горизонтальна адреса 0
    jsr lcd_cmd
    ldx #32             ; 32 байти = верхня і нижня половини рядка
@bytes:
    lda row
    and #%00000100      ; змінюємо візерунок кожні 4 рядки
    beq @a
    lda #%11110000
    bra @w
@a:
    lda #%00001111
@w:
    jsr lcd_data
    dex
    bne @bytes
    inc row
    lda row
    cmp #32
    bne @rows

    lda #$36            ; увімкнути графічний шар
    jsr lcd_cmd
@halt:
    bra @halt

nmi:
irq:
    rti

.segment "VECTORS"
    .word nmi, reset, irq
