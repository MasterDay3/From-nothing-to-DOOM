; Лаунчер: меню вибору гри на ST7920 (128x64)
;
; UP/DOWN — вибір, MIDDLE або RIGHT — запуск.
; У грі: затиснути LEFT+RIGHT на 1 с (або RESET) — повернення в меню.
;
; Ігри НЕ змінюються: build.sh лінкує кожен emulator/*.s без змін у власний слот
; ROM (launcher/slot.cfg), а цей файл підключає слоти через .incbin. Останні
; 6 байтів слоту — вектори гри (NMI, RESET, IRQ): гра стартує через свій RESET,
; а переривання лаунчер пересилає на її IRQ.
;
; Збірка: ./launcher/build.sh   ->   launcher/build/rom.bin
; Або напряму (після генерації *.slot через ./launcher/build.sh):
;   ca65 --cpu 65C02 launcher/launcher.s -o launcher.o
;   ld65 -C emulator_c/rom.cfg launcher.o -o rom.bin
.segment "CODE"
code_start:
.include "../emulator/lcd.inc"

T1CL = $6004
T1CH = $6005
ACR  = $600B
IER  = $600E

BTN_MID   = %00001
BTN_UP    = %00010
BTN_DOWN  = %00100
BTN_LEFT  = %01000
BTN_RIGHT = %10000

EXIT_KEYS  = BTN_LEFT | BTN_RIGHT
EXIT_TICKS = 50         ; 50 тіків по 20 мс = 1 с
TICK       = 20000 - 2  ; 20 мс при 1 MHz, як в іграх

NUM_GAMES = 3

; Стан лаунчера, який живе й під час гри: верхні 16 байтів RAM.
; Ігри їх не чіпають: DOOM закінчується на $13FF, PAC-MAN на $087F,
; Вгадай число використовує лише нульову сторінку.
KEEP_FROM  = $3FF0      ; RAM нижче цієї адреси обнуляється перед запуском гри
game_irq   = $3FF0      ; 2 байти: обробник IRQ поточної гри
game_entry = $3FF2      ; 2 байти: RESET-вектор гри
exit_hold  = $3FF4      ; скільки тіків поспіль затиснуто LEFT+RIGHT
game_sel   = $3FF5      ; останній вибраний пункт (після повернення курсор на ньому)
game_timer = $3FF6      ; 1 = гра сама налаштовує таймер T1

.zeropage
sel:   .res 1           ; поточний пункт меню
key:   .res 1
fill:  .res 1           ; байт заливки GDRAM для gd_fill
bar_y: .res 1
bar_n: .res 1
ptr:   .res 2

.segment "CODE"
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #$7F            ; гра могла увімкнути переривання VIA: вимкнути всі
    sta IER
    stz ACR
    bit T1CL            ; скинути прапорець T1
    lda #<tick_ack      ; поки гри немає, IRQ нікуди не пересилаємо
    sta game_irq
    lda #>tick_ack
    sta game_irq+1
    stz exit_hold

    jsr via_init
    jsr lcd_init        ; 50 мс очікування + текстовий режим, очищення
    jsr gd_clear        ; у GDRAM може лишитися гра або сміття після ввімкнення

    lda game_sel        ; після ввімкнення RAM — сміття, перевіряємо діапазон
    cmp #NUM_GAMES
    bcc @sel
    lda #0
@sel:
    sta sel
    jsr draw_menu
    jsr wait_release    ; після виходу з гри LEFT+RIGHT ще можуть бути затиснуті

menu_loop:
    jsr get_key
    bit #BTN_UP
    bne @up
    bit #BTN_DOWN
    bne @down
    bit #(BTN_MID | BTN_RIGHT)
    beq menu_loop
    jmp launch

@up:
    jsr unselect
    lda sel
    bne @dec
    lda #NUM_GAMES      ; з першого пункту — на останній
@dec:
    dec a
    sta sel
    jsr select
    bra menu_loop

@down:
    jsr unselect
    lda sel
    inc a
    cmp #NUM_GAMES
    bcc @set
    lda #0              ; з останнього — на перший
@set:
    sta sel
    jsr select
    bra menu_loop

; ---------------------------------------------------------------------------
; Запуск гри sel. Сюди тільки через jmp: стек теж буде обнулено.

launch:
    jsr gd_clear        ; емулятор показує GDRAM і в текстовому режимі
    lda #$34            ; графіку вимкнути, текст очистити
    jsr lcd_cmd
    lda #$30
    jsr lcd_cmd
    lda #$01
    jsr lcd_cmd

    ldx sel             ; вектори гри -> стан лаунчера (переживе очищення)
    stx game_sel
    lda uses_timer,x
    sta game_timer
    txa
    asl
    tax
    lda game_vectors,x
    sta ptr
    lda game_vectors+1,x
    sta ptr+1
    ldy #2              ; NMI, [RESET], IRQ
    lda (ptr),y
    sta game_entry
    iny
    lda (ptr),y
    sta game_entry+1
    iny
    lda (ptr),y
    sta game_irq
    iny
    lda (ptr),y
    sta game_irq+1
    lda game_timer
    bne @irq_ok
    lda #<tick_ack      ; гра без таймера: її IRQ-обробник не скидає T1,
    sta game_irq        ; тож тіки лаунчера підтверджуємо самі
    lda #>tick_ack
    sta game_irq+1
@irq_ok:
    stz exit_hold

    ; Обнулити RAM $0200..KEEP_FROM-1, потім нульову сторінку і стек:
    ; гра стартує з чистою пам'яттю незалежно від попередньої гри.
    stz ptr
    lda #$02
    sta ptr+1
    lda #0
    ldy #0
@page:
    sta (ptr),y
    iny
    bne @page
    inc ptr+1
    ldx ptr+1
    cpx #>KEEP_FROM
    bne @page
@tail:
    sta KEEP_FROM & $FF00,y
    iny
    cpy #<KEEP_FROM
    bne @tail
    ldx #0
@zp:
    stz $00,x
    stz $0100,x
    inx
    bne @zp
    dex                 ; X = $FF: стек порожній, як після RESET
    txs

    lda game_timer
    bne @go
    ; Гра без таймера (Вгадай число): власний такт 20 мс, щоб працював вихід
    ; по LEFT+RIGHT. DOOM і PAC-MAN налаштовують T1 самі, як і без лаунчера.
    lda #%01000000      ; T1 вільний біг
    sta ACR
    lda #<TICK
    sta T1CL
    lda #>TICK
    sta T1CH
    lda #%11000000
    sta IER
    cli
@go:
    jmp (game_entry)

; ---------------------------------------------------------------------------
; Переривання: перевірити LEFT+RIGHT, далі передати обробнику гри.

irq:
    pha
    lda PORTA
    and #EXIT_KEYS      ; 0 = обидві затиснуті
    bne @released
    lda exit_hold
    inc a
    sta exit_hold
    cmp #EXIT_TICKS
    bcc @forward
    jmp reset           ; назад у меню: все ініціалізується заново
@released:
    stz exit_hold
@forward:
    pla
    jmp (game_irq)

tick_ack:               ; підтвердити T1 (для ігор без власного таймера)
    bit T1CL
nmi:
    rti

; ---------------------------------------------------------------------------
; Малювання меню

draw_menu:
    PRINT ROW1, s_title
    PRINT ROW2, s_doom
    PRINT ROW3, s_guess
    PRINT ROW4, s_pacman
    lda #15             ; лінія під заголовком
    sta bar_y
    lda #1
    sta bar_n
    lda #$FF
    sta fill
    jsr gd_fill
    ; далі — виділити пункт sel

; Позначити пункт sel: маркер '>' та інверсна смуга (GDRAM XOR текст)
select:
    lda #'>'
    ldx #$FF
    bra mark

; Зняти позначку з пункту sel
unselect:
    lda #' '
    ldx #$00
mark:                   ; A = маркер, X = заливка смуги
    stx fill
    pha
    ldy sel
    lda item_row,y
    jsr lcd_cmd
    pla
    jsr lcd_data
    lda sel             ; смуга: рядки пікселів 16*(sel+1) .. +15
    inc a               ; (рядок тексту 0 — заголовок)
    asl
    asl
    asl
    asl
    sta bar_y
    lda #16
    sta bar_n
    ; далі — gd_fill

; Залити bar_n рядків пікселів, починаючи з bar_y, байтом fill (на всю ширину)
gd_fill:
    lda #$36            ; розширений набір команд, графіка увімкнена
    jsr lcd_cmd
@row:
    lda bar_y
    jsr gd_goto
    ldy #16
@byte:
    lda fill
    jsr lcd_data
    dey
    bne @byte
    inc bar_y
    dec bar_n
    bne @row
    lda #$30            ; назад у базовий набір (для тексту)
    jmp lcd_cmd

; Очистити весь GDRAM. 32 байти від адреси (y, 0) заповнюють рядок y
; і рядок y+32 (права половина GDRAM — це нижня половина екрана).
gd_clear:
    lda #$36
    jsr lcd_cmd
    ldx #0
@row:
    txa
    jsr gd_goto
    ldy #32
@byte:
    lda #0
    jsr lcd_data
    dey
    bne @byte
    inx
    cpx #32
    bne @row
    lda #$30
    jmp lcd_cmd

; Адреса GDRAM: A = рядок пікселів 0-63, лівий край. Потрібен режим $36.
gd_goto:
    cmp #32
    bcs @bottom
    ora #$80
    jsr lcd_cmd
    lda #$80
    jmp lcd_cmd
@bottom:
    sbc #32             ; carry = 1
    ora #$80
    jsr lcd_cmd
    lda #$88
    jmp lcd_cmd

; ---------------------------------------------------------------------------
; Кнопки (як у guess.s)

; Чекати натискання; повертає в A маску натиснутих (1 = натиснута)
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

; ---------------------------------------------------------------------------
; Таблиці і рядки (у CODE, щоб .incbin слотів ішов підряд після вирівнювання)

s_title:  .byte "  SELECT GAME", 0
s_doom:   .byte "  DOOM", 0
s_guess:  .byte "  GUESS NUMBER", 0
s_pacman: .byte "  PAC-MAN", 0

; Таблиці пунктів меню (порядок: DOOM, Вгадай число, PAC-MAN)
item_row:     .byte ROW2, ROW3, ROW4
uses_timer:   .byte 1, 0, 1
game_vectors: .word doom_vectors, guess_vectors, pacman_vectors

; ---------------------------------------------------------------------------
; Ігри: готові слоти від build.sh (адреси збігаються з slot.cfg)

    .res ($8800 - $8000) - (* - code_start), $EA

    .incbin "build/guess.slot"
guess_vectors = * - 6

    .incbin "build/pacman.slot"
pacman_vectors = * - 6

    .incbin "build/doom.slot"
doom_vectors = * - 6

.segment "VECTORS"
    .word nmi, reset, irq
