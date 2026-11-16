; Демо таймера VIA і переривань: секундомір
; T1 у режимі вільного бігу кожні 10 мс генерує IRQ. Обробник рахує тіки,
; а головний цикл спить у WAI і оновлює дисплей раз на секунду.
.include "lcd.inc"

T1CL = $6004
T1CH = $6005
ACR  = $600B
IER  = $600E

TICK = 10000 - 2        ; 10 мс при 1 MHz (T1 рахує N+2 такти)

.zeropage
ticks: .res 1
secs:  .res 1
flags: .res 1           ; біт 0: минула секунда

.segment "CODE"
reset:
    ldx #$FF
    txs
    sei
    jsr via_init
    jsr lcd_init

    stz ticks           ; RAM після ввімкнення містить сміття: обнуляємо все
    stz secs
    stz flags

    PRINT ROW1, s_title
    PRINT ROW2, s_secs
    lda #0
    jsr lcd_num

    lda #%01000000      ; T1: вільний біг
    sta ACR
    lda #<TICK
    sta T1CL
    lda #>TICK
    sta T1CH            ; запис старшого байта запускає таймер
    lda #%11000000      ; дозволити переривання від T1
    sta IER
    cli

main:
    wai                 ; спати до переривання
    bbr0 flags, main    ; секунда ще не минула
    rmb0 flags
    lda #(ROW2 + 4)     ; позиція після "SECONDS:"
    jsr lcd_cmd
    lda secs
    jsr lcd_num
    bra main

irq:
    pha
    bit T1CL            ; читання T1C-L скидає прапорець переривання
    inc ticks
    lda ticks
    cmp #100
    bne @done
    stz ticks
    smb0 flags
    inc secs
    lda secs
    cmp #100
    bne @done
    stz secs
@done:
    pla
    rti

nmi:
    rti

.segment "RODATA"
s_title: .byte "TIMER IRQ DEMO", 0
s_secs:  .byte "SECONDS:", 0

.segment "VECTORS"
    .word nmi, reset, irq
