; Біжучий вогник на світлодіодах (VIA port B)
PORTB = $6000
DDRB  = $6002

.segment "CODE"
reset:
    ldx #$FF
    txs
    lda #$FF
    sta DDRB        ; PB0-PB7 = виходи
start:
    lda #$01
loop:
    sta PORTB
    asl a
    bne loop
    bra start

nmi:
irq:
    rti

.segment "VECTORS"
    .word nmi, reset, irq
