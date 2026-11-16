; Драйвер ST7920 для плати 65C02 PC (8-бітний паралельний режим)
; PB0-PB7 = дані, PA5 = RS, PA6 = R/W, PA7 = E

PORTB = $6000
PORTA = $6001
DDRB  = $6002
DDRA  = $6003

; Адреси початку рядків тексту
ROW1 = $80
ROW2 = $90
ROW3 = $88
ROW4 = $98

; PRINT ROWn, рядок: вивести рядок з нулем на початок рядка дисплея
.macro PRINT row, str
    lda #row
    jsr lcd_cmd
    ldx #<str
    ldy #>str
    jsr lcd_print
.endmacro

LCD_E  = %10000000
LCD_RW = %01000000
LCD_RS = %00100000

.zeropage
lcd_tmp: .res 1
lcd_ptr: .res 2

.segment "CODE"

; Налаштувати порти: PA5-PA7 виходи, PA0-PA4 входи (кнопки), PB виходи
via_init:
    lda #%11100000
    sta DDRA
    lda #$FF
    sta DDRB
    rts

; Чекати, поки дисплей звільниться (читаємо busy flag). Зберігає A.
lcd_wait:
    pha
    lda #$00
    sta DDRB            ; PB = входи
@busy:
    lda #LCD_RW
    sta PORTA
    lda #(LCD_RW | LCD_E)
    sta PORTA
    lda PORTB
    sta lcd_tmp
    lda #LCD_RW
    sta PORTA
    lda lcd_tmp
    and #$80
    bne @busy
    lda #$FF
    sta DDRB            ; PB знову виходи
    pla
    rts

; Команда в A
lcd_cmd:
    jsr lcd_wait
    sta PORTB
    lda #0
    sta PORTA
    lda #LCD_E
    sta PORTA
    lda #0
    sta PORTA
    rts

; Байт даних в A
lcd_data:
    jsr lcd_wait
    sta PORTB
    lda #LCD_RS
    sta PORTA
    lda #(LCD_RS | LCD_E)
    sta PORTA
    lda #LCD_RS
    sta PORTA
    rts

; Ініціалізація в текстовому режимі
lcd_init:
    ; ST7920 після ввімкнення/RESET не приймає команд ~40 мс: чекаємо 50 мс (при 1 MHz)
    ldx #50
@ms:
    ldy #200
@us:
    dey
    bne @us             ; 200 x 5 тактів = 1 мс
    dex
    bne @ms

    lda #$30            ; 8 біт, базовий набір команд
    jsr lcd_cmd
    lda #$30
    jsr lcd_cmd
    lda #$0C            ; дисплей увімкнено, курсор вимкнено
    jsr lcd_cmd
    lda #$01            ; очистити
    jsr lcd_cmd
    lda #$06            ; інкремент адреси
    jsr lcd_cmd
    rts

; Вивести рядок, що закінчується нулем: X = молодший байт адреси, Y = старший
lcd_print:
    stx lcd_ptr
    sty lcd_ptr+1
    ldy #0
@loop:
    lda (lcd_ptr),y
    beq @done
    jsr lcd_data
    iny
    bne @loop
@done:
    rts

; Вивести A (0-99) двома символами, замість нуля попереду пробіл.
; 6502 не вміє ділити, тому десятки рахуємо відніманням.
lcd_num:
    ldx #0
@tens:
    cmp #10
    bcc @units
    sbc #10
    inx
    bra @tens
@units:
    pha
    txa
    bne @digit
    lda #' '
    bra @out
@digit:
    clc
    adc #'0'
@out:
    jsr lcd_data
    pla
    clc
    adc #'0'
    jmp lcd_data
