; MINI-DOOM для плати 65C02 PC
;
; Порт "1 MHz MINI-DOOM ENGINE v8" (Apple II) на нашу плату: ігрова логіка
; (рух із ковзанням уздовж стін, постріл, двері, вихід, демони, карта 32x32)
; взята з оригіналу; рендер, HUD, мінікарта і керування написані під
; ST7920 128x64 в 1 біті і 5 кнопок.
;
; Виправлено відносно оригіналу:
;   - check_collision затирав X, і перевірка демонів поруч ламалась;
;   - кут огляду був 180 градусів; тепер 256 кутів на коло, огляд 90 (як у DOOM);
;   - промінь ішов кроками по 1/4 клітинки і проскакував кути — тепер DDA
;     (від межі до межі клітинок, як у Wolfenstein 3D) з корекцією "риб'ячого ока".
;
; Екран: 3D-вікно 128x56 (64 промені по 2 пікселі): текстури стін 16x16,
; відтінки сірого дизерингом Байєра (стіни темнішають з відстанню, грані
; північ/південь темніші), підлога з градієнтом, демон — масштабований спрайт
; 32x32, рушниця 48 пікселів. Внизу рядок стану (HP, патрони, вбивства),
; у правому верхньому куті мінікарта 5x5.
; Кнопки: UP/DOWN — вперед/назад, LEFT/RIGHT — поворот, MIDDLE — постріл/двері/вихід.
; Гра покрокова: кадр малюється після кожної дії (затиснута кнопка повторюється).
.include "lcd.inc"

T1CL = $6004
T1CH = $6005
ACR  = $600B
IER  = $600E

FB   = $0200            ; кадровий буфер 128x64 (1 KB)
MAP  = $0600            ; карта 32x32 у RAM (1 KB, вирівняна на сторінку)
COLS = $0A00            ; дані про стовпці від raycaster'а (по 64 байти)
TOP   = COLS + $000     ; верх стіни (обрізаний)
BOT   = COLS + $040     ; низ стіни
CD    = COLS + $080     ; відстань, 1/16 клітинки (індекс таблиць)
TTYPE = COLS + $0C0     ; текстура: (тип-1)*32 + байт стовпчика
TU    = COLS + $100     ; стовпчик текстури (біт)
LIGHT = COLS + $140     ; яскравість 0-16
STOP  = COLS + $180     ; верх демона (0 = немає)
SBOT  = COLS + $1C0     ; низ демона
SCD   = COLS + $200     ; відстань до демона
SU    = COLS + $240     ; стовпчик спрайта демона 0-31
SHADOW = $1000          ; копія останнього переданого на дисплей кадру (1 KB)

RAYS     = 64
CENTER   = 32           ; промінь під прицілом
VIEW_H   = 56           ; 3D-вікно; рядки 56-63 — рядок стану
HORIZON  = 28
MAX_STEPS = 40          ; клітинок на промінь
FAR_TEX  = 40           ; далі 2.5 клітинки стіни без текстури
DOOR_RANGE = 32         ; двері/вихід ближче 2 клітинок (1/16 клітинки)
TICK     = 20000 - 2    ; 20 мс
TURN     = 8            ; 11.25 градуса за натискання

T_DOOR  = 5
T_EXIT  = 6
T_DEMON = 7

BTN_MID   = %00001
BTN_UP    = %00010
BTN_DOWN  = %00100
BTN_LEFT  = %01000
BTN_RIGHT = %10000

; гліфи мінікарти
G_EMPTY  = 0
G_WALL   = 1
G_DOOR   = 2
G_EXIT   = 3
G_DEMON  = 4
G_PLAYER = 5            ; 5-8: на схід, південь, захід, північ

; символи шрифту рядка стану
CH_H = 10
CH_P = 11
CH_A = 12
CH_M = 13
CH_K = 14
CH_SLASH = 15

.zeropage
posX_lo:  .res 1
posX_hi:  .res 1
posY_lo:  .res 1
posY_hi:  .res 1
p_angle:  .res 1
hp:       .res 1
ammo:     .res 1
kills:    .res 1
muzzle:   .res 1
won:      .res 1
hit_id:   .res 1        ; що під прицілом
hit_x:    .res 1
hit_y:    .res 1
hit_dist: .res 1

ri:       .res 1        ; raycaster (DDA)
ray_ang:  .res 1
ang_y:    .res 1
mapx:     .res 1
mapy:     .res 1
negx:     .res 1
negy:     .res 1
ddxL:     .res 1
ddxH:     .res 1
ddyL:     .res 1
ddyH:     .res 1
sideXL:   .res 1
sideXH:   .res 1
sideYL:   .res 1
sideYH:   .res 1
rdL:      .res 1
rdH:      .res 1
side:     .res 1
steps:    .res 1
idx:      .res 1
tile:     .res 1
mul_a:    .res 1
m16L:     .res 1
m16H:     .res 1
p1:       .res 1
p2:       .res 1

tx:       .res 1        ; клітинка для get_tile
ty:       .res 1
map_ptr:  .res 2
dxl:      .res 1        ; рух
dxh:      .res 1
dyl:      .res 1
dyh:      .res 1
candl:    .res 1
candh:    .res 1

tick:     .res 1
btn:      .res 1
btn_prev: .res 1
rep:      .res 1
yy:       .res 1
ptr:      .res 2
ptr2:     .res 2
tmp:      .res 1
tmp2:     .res 1
cnt:      .res 1
nib:      .res 1
gy:       .res 1
gidx:     .res 1
mm_r:     .res 1
mm_c:     .res 1
col:      .res 1        ; рендер
bx:       .res 1
kexp:     .res 1
par:      .res 1
dbase:    .res 1
dbase2:   .res 1
texbit:   .res 1
texbase:  .res 1
vL:       .res 1
vH:       .res 1
vsL:      .res 1
vsH:      .res 1
sbyte:    .res 1
cmask:    .res 1
cbright:  .res 1
fr:       .res 1
uu:       .res 1
rowbuf:   .res 12
mB:       .res 1
r_lo:     .res 1
r_hi:     .res 1
nextw:    .res 1
half:     .res 1
force:    .res 1
litB:     .res 4        ; стіна: світло для рядків y&3
litD:     .res 4        ; стіна: тінь

.segment "CODE"
reset:
    ldx #$FF
    txs
    sei
    jsr via_init
    jsr lcd_init
    lda #%01000000      ; T1 вільний біг: такт гри 20 мс
    sta ACR
    lda #<TICK
    sta T1CL
    lda #>TICK
    sta T1CH
    lda #%11000000
    sta IER
    stz tick
    cli

    jsr text_screen
    PRINT ROW1, s_title
    PRINT ROW2, s_sub
    PRINT ROW4, s_press
    jsr wait_mid

new_game:
    jsr copy_map
    lda #$80            ; старт у (2.5, 2.5), обличчям на схід
    sta posX_lo
    sta posY_lo
    lda #2
    sta posX_hi
    sta posY_hi
    stz p_angle
    stz muzzle
    stz kills
    stz won
    lda #6
    sta hp
    sta ammo
    stz btn_prev

    lda #$30            ; очистити текстовий шар
    jsr lcd_cmd
    lda #$01
    jsr lcd_cmd
    lda #$34
    jsr lcd_cmd
    lda #1              ; дисплей щойно показував текст: передати весь кадр
    sta force
    jsr update_view
    lda #$36            ; увімкнути графіку
    jsr lcd_cmd

; --- Головний цикл: кнопка -> дія -> новий кадр -------------------------------
main_loop:
    jsr wait_tick
    lda PORTA
    eor #$FF
    and #$1F
    sta btn
    bne @pressed
    stz btn_prev
    bra main_loop
@pressed:
    cmp btn_prev
    beq @held
    sta btn_prev
    lda #12             ; перший повтор через 240 мс
    sta rep
    bra @act
@held:
    dec rep
    bne main_loop
    lda #5              ; далі кожні 100 мс
    sta rep
@act:
    jsr do_action
    lda hp
    beq died
    lda won
    bne exit_found
    bra main_loop

died:
    jsr text_screen
    PRINT ROW1, s_died
    jsr show_kills
    jsr wait_mid
    jmp new_game

exit_found:
    jsr text_screen
    PRINT ROW1, s_exit
    jsr show_kills
    jsr wait_mid
    jmp new_game

show_kills:
    PRINT ROW2, s_kills
    lda kills
    jsr lcd_num
    PRINT ROW4, s_again
    rts

do_action:
    lda btn
    bit #BTN_MID
    bne btn_action
    bit #BTN_UP
    beq @dn
    stz tmp2            ; вперед
    jmp move
@dn:
    bit #BTN_DOWN
    beq @lt
    lda #1              ; назад
    sta tmp2
    jmp move
@lt:
    bit #BTN_LEFT
    beq @rt
    lda p_angle
    sec
    sbc #TURN
    sta p_angle
    jmp update_view
@rt:
    lda p_angle
    clc
    adc #TURN
    sta p_angle
    jmp update_view

; --- MIDDLE: двері / вихід поруч, інакше постріл (як в оригіналі) --------------
btn_action:
    lda hit_dist
    cmp #DOOR_RANGE
    bcs @shoot
    lda hit_id
    cmp #T_DOOR
    beq @door
    cmp #T_EXIT
    beq @exit
@shoot:
    lda ammo
    bne @fire
    jmp update_view
@fire:
    dec ammo
    lda hit_id
    cmp #T_DEMON
    bne @shot
    lda hit_x           ; демон під прицілом: прибрати з карти
    sta tx
    lda hit_y
    sta ty
    jsr get_tile
    lda #0
    sta (map_ptr)
    inc kills
    lda ammo
    clc
    adc #2
    cmp #7
    bcc @save
    lda #6
@save:
    sta ammo
@shot:
    jsr update_enemies
    lda #1              ; кадр зі спалахом, пауза, звичайний кадр
    sta muzzle
    jsr update_view
    lda #6
    jsr pause
    stz muzzle
    jmp update_view
@door:
    lda hit_x
    sta tx
    lda hit_y
    sta ty
    jsr get_tile
    lda #0
    sta (map_ptr)
    jmp update_view
@exit:
    lda #1
    sta won
    rts

; --- Рух із ковзанням уздовж стін: окремо по X і по Y ---------------------------
move:                   ; tmp2: 0 = вперед, 1 = назад; крок 1/4 клітинки
    ldy p_angle
    lda cos_lo,y
    asl
    sta dxl
    lda cos_hi,y
    rol
    sta dxh
    lda sin_lo,y
    asl
    sta dyl
    lda sin_hi,y
    rol
    sta dyh
    lda tmp2
    beq @x
    sec                 ; назад: змінити знак кроку
    lda #0
    sbc dxl
    sta dxl
    lda #0
    sbc dxh
    sta dxh
    sec
    lda #0
    sbc dyl
    sta dyl
    lda #0
    sbc dyh
    sta dyh
@x:
    clc
    lda posX_lo
    adc dxl
    sta candl
    lda posX_hi
    adc dxh
    sta candh
    sta tx
    lda posY_hi
    sta ty
    jsr get_tile
    bne @y
    lda candl
    sta posX_lo
    lda candh
    sta posX_hi
@y:
    clc
    lda posY_lo
    adc dyl
    sta candl
    lda posY_hi
    adc dyh
    sta candh
    sta ty
    lda posX_hi
    sta tx
    jsr get_tile
    bne @done
    lda candl
    sta posY_lo
    lda candh
    sta posY_hi
@done:
    jsr update_enemies
    jmp update_view

; Демони кусають, якщо стоять у сусідній клітинці
update_enemies:
    ldx #3
@l:
    lda posX_hi
    clc
    adc dir_dx,x
    sta tx
    lda posY_hi
    clc
    adc dir_dy,x
    sta ty
    jsr get_tile        ; X не змінюється
    cmp #T_DEMON
    bne @n
    lda hp
    beq @n
    dec hp
@n:
    dex
    bpl @l
    rts

; A = клітинка (tx, ty); map_ptr вказує на неї. X і Y не змінюються.
get_tile:
    lda ty
    and #31
    lsr
    lsr
    lsr
    clc
    adc #>MAP
    sta map_ptr+1
    lda ty
    and #7
    asl
    asl
    asl
    asl
    asl
    sta map_ptr
    lda tx
    and #31
    ora map_ptr
    sta map_ptr
    lda (map_ptr)
    rts

copy_map:               ; карта змінюється (двері, демони), тому живе в RAM
    lda #<map_rom
    sta ptr
    lda #>map_rom
    sta ptr+1
    lda #<MAP
    sta ptr2
    lda #>MAP
    sta ptr2+1
    ldx #4
    ldy #0
@c:
    lda (ptr),y
    sta (ptr2),y
    iny
    bne @c
    inc ptr+1
    inc ptr2+1
    dex
    bne @c
    rts

; --- Кадр ----------------------------------------------------------------------
update_view:
    jsr cast_all
    jsr mark_demons
    jsr render_view
    jsr draw_weapon
    jsr draw_status
    jsr draw_minimap
    jmp lcd_flush

; Raycaster DDA: 64 промені з кроком 1 кут (90 градусів огляду).
; Промінь іде від межі до межі клітинок: sideX/sideY — відстань уздовж променя
; до наступної вертикальної/горизонтальної межі, ddx/ddy — відстань між межами.
cast_all:
    stz ri
    stz hit_id
    lda #$FF
    sta hit_dist
    lda p_angle
    sec
    sbc #RAYS / 2
    sta ray_ang
@ray:
    ldx ri
    stz STOP,x
    lda #HORIZON        ; нічого не знайдено: лише стеля і підлога
    sta TOP,x
    sta BOT,x
    lda posX_hi
    sta mapx
    lda posY_hi
    sta mapy

    ldy ray_ang         ; --- вісь X: |1/cos|, напрямок і відстань до першої межі
    lda dd_lo,y
    sta ddxL
    sta m16L
    lda dd_hi,y
    sta ddxH
    sta m16H
    stz negx
    tya
    jsr is_neg
    bcc @xp
    inc negx
    lda posX_lo         ; до лівої межі: дробова частина
    bra @xm
@xp:
    lda posX_lo         ; до правої межі: 1 - дробова частина
    eor #$FF
@xm:
    sta mul_a
    jsr mul8x16
    lda p1
    sta sideXL
    lda p2
    sta sideXH

    lda ray_ang         ; --- вісь Y: sin(a) = cos(a - 64)
    sec
    sbc #64
    sta ang_y
    tay
    lda dd_lo,y
    sta ddyL
    sta m16L
    lda dd_hi,y
    sta ddyH
    sta m16H
    stz negy
    tya
    jsr is_neg
    bcc @yp
    inc negy
    lda posY_lo
    bra @ym
@yp:
    lda posY_lo
    eor #$FF
@ym:
    sta mul_a
    jsr mul8x16
    lda p1
    sta sideYL
    lda p2
    sta sideYH

    lda #MAX_STEPS
    sta steps
@dda:
    lda sideXH          ; ближча межа: X чи Y?
    cmp sideYH
    bcc @goX
    bne @goY
    lda sideXL
    cmp sideYL
    bcs @goY
@goX:
    lda sideXL
    sta rdL
    lda sideXH
    sta rdH
    clc
    lda sideXL
    adc ddxL
    sta sideXL
    lda sideXH
    adc ddxH
    sta sideXH
    lda negx
    beq @xi
    dec mapx
    bra @xd
@xi:
    inc mapx
@xd:
    stz side
    bra @chk
@goY:
    lda sideYL
    sta rdL
    lda sideYH
    sta rdH
    clc
    lda sideYL
    adc ddyL
    sta sideYL
    lda sideYH
    adc ddyH
    sta sideYH
    lda negy
    beq @yi
    dec mapy
    bra @yd
@yi:
    inc mapy
@yd:
    lda #1
    sta side
@chk:
    lda mapx
    sta tx
    lda mapy
    sta ty
    jsr get_tile
    bne @hit
@more:
    dec steps
    bne @dda
    jmp @next

@hit:
    sta tile
    ldx ri              ; відстань без "риб'ячого ока": rd * cos(відхилення)
    lda fish,x
    sta mul_a
    lda rdL
    sta m16L
    lda rdH
    sta m16H
    jsr mul8x16
    lda p2              ; індекс = відстань у 1/16 клітинки (до 255)
    cmp #16
    bcc @i1
    lda #255
    bra @i3
@i1:
    asl
    asl
    asl
    asl
    sta tmp
    lda p1
    lsr
    lsr
    lsr
    lsr
    ora tmp
    bne @i3
    lda #1
@i3:
    sta idx

    lda ri              ; перше, у що влучив центральний промінь
    cmp #CENTER
    bne @kind
    lda hit_id
    bne @kind
    lda tile
    sta hit_id
    lda tx
    sta hit_x
    lda ty
    sta hit_y
    lda idx
    sta hit_dist

@kind:
    ldx ri
    lda tile
    cmp #T_DEMON
    bne @wall
    lda STOP,x          ; демон: запам'ятати (лише найближчого), промінь іде далі
    bne @more
    ldy idx
    tya
    sta SCD,x
    lda spr_top_lut,y
    sta STOP,x
    lda bot_lut,y
    sta SBOT,x
    bra @more

@wall:
    ldy idx
    tya
    sta CD,x
    lda top_lut,y
    sta TOP,x
    lda bot_lut,y
    sta BOT,x
    lda light_lut,y
    sta tmp2
    lda side            ; точка влучання вздовж стіни -> стовпчик текстури
    bne @ns
    ldy ang_y           ; перетнули вертикальну межу: координата Y
    lda acos,y
    sta mul_a
    lda rdL
    sta m16L
    lda rdH
    sta m16H
    jsr mul8x16
    lda negy
    bne @ysub
    lda posY_lo
    clc
    adc p1
    bra @u
@ysub:
    lda posY_lo
    sec
    sbc p1
    bra @u
@ns:                    ; горизонтальна межа: координата X, грань темніша
    lda tmp2
    sec
    sbc #4
    bcs @dk
    lda #0
@dk:
    sta tmp2
    ldy ray_ang
    lda acos,y
    sta mul_a
    lda rdL
    sta m16L
    lda rdH
    sta m16H
    jsr mul8x16
    lda negx
    bne @xsub
    lda posX_lo
    clc
    adc p1
    bra @u
@xsub:
    lda posX_lo
    sec
    sbc p1
@u:
    lsr                 ; 16 стовпчиків текстури
    lsr
    lsr
    lsr
    sta tmp
    ldx ri
    and #7
    tay
    lda bitmask8,y
    sta TU,x
    lda tile            ; текстура: (тип-1)*32 + номер байта (0/1)
    sec
    sbc #1
    and #7
    asl
    asl
    asl
    asl
    asl
    sta TTYPE,x
    lda tmp
    lsr
    lsr
    lsr
    ora TTYPE,x
    sta TTYPE,x
    lda tmp2
    sta LIGHT,x

@next:
    inc ray_ang
    inc ri
    lda ri
    cmp #RAYS
    beq @done
    jmp @ray
@done:
    rts

; carry = 1, якщо cos(A) < 0, тобто A у 65..191
is_neg:
    sec
    sbc #65
    cmp #127
    bcs @no
    sec
    rts
@no:
    clc
    rts

; mul_a (8 біт) * m16 (16 біт) -> mul_a (молодший), p1, p2 (старший). Псує X, Y.
; Два множення 8x8 через таблицю квадратів (у ROM) замість циклу зсувів.
mul8x16:
    lda m16L
    sta mB
    jsr mul8x8
    lda r_lo
    pha
    lda r_hi
    sta p1
    lda m16H
    sta mB
    jsr mul8x8
    clc
    lda p1
    adc r_lo
    sta p1
    lda r_hi
    adc #0
    sta p2
    pla
    sta mul_a
    rts

; mul_a * mB -> r_lo, r_hi;  a*b = f(a+b) - f(|a-b|), f(x) = x*x/4
mul8x8:
    lda mul_a
    sec
    sbc mB
    bcs @pos
    eor #$FF
    adc #1              ; carry тут 0
@pos:
    tay                 ; |a-b|
    lda mul_a
    clc
    adc mB
    tax                 ; a+b (молодший байт), carry = біт 8
    bcs @big
    lda sqlo0,x
    sec
    sbc sqlo0,y
    sta r_lo
    lda sqhi0,x
    sbc sqhi0,y
    sta r_hi
    rts
@big:
    lda sqlo1,x
    sec
    sbc sqlo0,y
    sta r_lo
    lda sqhi1,x
    sbc sqhi0,y
    sta r_hi
    rts

; Суміжні стовпці з демоном — це один демон: стовпець k із n отримує
; стовпчик спрайта u = (32k + 16) / n (рахуємо без ділення, накопиченням).
mark_demons:
    ldx #0
@find:
    lda STOP,x
    bne @run
    inx
    cpx #RAYS
    bne @find
    rts
@run:
    stx tmp             ; початок серії
@len:
    inx
    cpx #RAYS
    beq @end
    lda STOP,x
    bne @len
@end:
    stx tmp2            ; кінець (не включно)
    txa
    sec
    sbc tmp
    sta cnt             ; довжина n
    lda #16
    sta fr
    stz uu
    ldy tmp
@col:
    lda fr
    cmp cnt
    bcc @put
    sbc cnt
    sta fr
    inc uu
    bra @col
@put:
    lda uu
    sta SU,y
    lda fr
    clc
    adc #32
    sta fr
    iny
    cpy tmp2
    bne @col
    ldx tmp2
    cpx #RAYS
    bne @find
    rts

.macro NEXTROW          ; наступний рядок кадрового буфера
    clc
    lda ptr2
    adc #16
    sta ptr2
    bcc :+
    inc ptr2+1
:   inc yy
.endmacro

; 3D-вікно: фон (чорна стеля, підлога-градієнт) цілими рядками з таблиці,
; потім кожен стовпець малює свою стіну і демона
render_view:
    lda #<FB
    sta ptr2
    lda #>FB
    sta ptr2+1
    ldx #0
@bg:
    lda bgbyte,x
    ldy #15
@c2:
    sta (ptr2),y
    dey
    bpl @c2
    clc
    lda ptr2
    adc #16
    sta ptr2
    bcc @nc
    inc ptr2+1
@nc:
    inx
    cpx #VIEW_H
    bne @bg
    stz col
@col:
    jsr render_column
    inc col
    lda col
    cmp #RAYS
    bne @col
    rts

; ptr2 = FB + A*16 + bx
row_ptr:
    sta yy
    lsr
    lsr
    lsr
    lsr
    clc
    adc #>FB
    sta ptr2+1
    lda yy
    asl
    asl
    asl
    asl
    ora bx
    sta ptr2
    rts

; Стовпець col (2 пікселі): текстурована стіна і демон поверх фону
render_column:
    ldx col
    lda col
    lsr
    lsr
    sta bx              ; байт у рядку
    lda col
    and #3
    asl
    asl
    sta kexp            ; позиція 2 бітів у байті (для expand)
    ora #3
    tay
    lda expand,y
    eor #$FF
    sta cmask           ; маска, що стирає 2 біти стовпця
    lda col
    and #1
    sta par             ; парність стовпця (для дизерингу)

    lda TOP,x
    cmp BOT,x
    bcc @hasw
    jmp @spr            ; стіни немає
@hasw:
    jsr row_ptr
    ldy CD,x            ; координата текстури v і її крок (8.8)
    lda v0_lo,y
    sta vL
    lda v0_hi,y
    sta vH
    lda vstep_lo,y
    sta vsL
    lda vstep_hi,y
    sta vsH
    lda LIGHT,x         ; база дизерингу: яскравість*8 + парність
    asl
    asl
    asl
    ora par
    sta dbase
    sta dbase2
    cpy #FAR_TEX        ; далеко: без текстури (інакше вона стає шумом)
    bcs @flat
    lda LIGHT,x         ; тінь текстури: на 9 рівнів темніше
    sec
    sbc #9
    bcs @dk
    lda #0
@dk:
    asl
    asl
    asl
    ora par
    sta dbase2
@flat:
    ldy #3              ; 4 готові байти (світло і тінь) для рядків y&3 = 0..3
@pre:
    tya
    asl
    ora dbase
    phy
    tay
    lda dith,y
    ora kexp
    tay
    lda expand,y
    ply
    sta litB,y
    tya
    asl
    ora dbase2
    phy
    tay
    lda dith,y
    ora kexp
    tay
    lda expand,y
    ply
    sta litD,y
    dey
    bpl @pre
    lda TU,x
    sta texbit
    lda TTYPE,x
    sta texbase
@wall:
    lda vH              ; рядок текстури 0-15
    and #15
    asl
    ora texbase
    tay
    lda textures,y
    and texbit
    beq @seam
    lda yy
    and #3
    tay
    lda litB,y
    bra @put
@seam:
    lda yy
    and #3
    tay
    lda litD,y
@put:
    sta tmp
    lda (ptr2)
    and cmask
    ora tmp
    sta (ptr2)
    clc
    lda vL
    adc vsL
    sta vL
    lda vH
    adc vsH
    sta vH
    NEXTROW
    lda yy
    cmp BOT,x
    bcc @wall

@spr:                   ; демон поверх стіни/фону
    lda STOP,x
    bne @s1
    rts
@s1:
    jsr row_ptr
    ldy SCD,x
    lda sv0_lo,y
    sta vL
    lda sv0_hi,y
    sta vH
    lda svstep_lo,y
    sta vsL
    lda svstep_hi,y
    sta vsH
    lda SU,x            ; стовпчик спрайта: байт рядка (0-3) і біт
    pha
    lsr
    lsr
    lsr
    sta sbyte
    pla
    and #7
    tay
    lda bitmask8,y
    sta texbit
    lda kexp
    ora #3
    tay
    lda expand,y
    sta cbright         ; обидва пікселі стовпця
@srow:
    lda vH
    cmp #32
    bcs @sdone
    asl
    asl
    ora sbyte
    tay
    lda demon_mask,y
    and texbit
    beq @snext          ; поза силуетом: фон
    lda demon_light,y
    and texbit
    beq @sdark
    lda cbright
    bra @sput
@sdark:
    lda #0
@sput:
    sta tmp
    lda (ptr2)
    and cmask
    ora tmp
    sta (ptr2)
@snext:
    clc
    lda vL
    adc vsL
    sta vL
    lda vH
    adc vsH
    sta vH
    NEXTROW
    lda yy
    cmp SBOT,x
    bcc @srow
@sdone:
    rts

; Рушниця (і спалах) над рядком стану, приціл посередині
draw_weapon:
    lda #<gun
    sta ptr
    lda #>gun
    sta ptr+1
    lda #VIEW_H - gun_ROWS
    sta gy
    lda #gun_ROWS
    sta cnt
    jsr blit48
    lda muzzle
    beq @cross
    lda #<flash
    sta ptr
    lda #>flash
    sta ptr+1
    lda #VIEW_H - gun_ROWS - flash_ROWS + 1
    sta gy
    lda #flash_ROWS
    sta cnt
    jsr blit48
@cross:                 ; "+" з дірочкою в центрі (x=64, y=28), XOR
    lda #<(FB + 27 * 16 + 8)
    sta ptr2
    lda #>(FB + 27 * 16 + 8)
    sta ptr2+1
    ldy #0
    lda (ptr2),y
    eor #$80
    sta (ptr2),y
    ldy #32
    lda (ptr2),y
    eor #$80
    sta (ptr2),y
    ldy #15             ; рядок 28, x=63 (байт 7)
    lda (ptr2),y
    eor #$01
    sta (ptr2),y
    ldy #16             ; рядок 28, x=65
    lda (ptr2),y
    eor #$40
    sta (ptr2),y
    rts

; Спрайт 48 пікселів на байти 5-10 (x=40..87) від рядка gy, cnt рядків.
; ptr: на рядок 6 байтів малюнка + 6 байтів маски (маска = чорний контур).
blit48:
    lda gy
    lsr
    lsr
    lsr
    lsr
    clc
    adc #>FB
    sta ptr2+1
    lda gy
    asl
    asl
    asl
    asl
    ora #5
    sta ptr2
@row:
    ldy #11
@cp:
    lda (ptr),y
    sta rowbuf,y
    dey
    bpl @cp
    ldy #5
@ap:
    lda rowbuf+6,y
    eor #$FF
    and (ptr2),y
    ora rowbuf,y
    sta (ptr2),y
    dey
    bpl @ap
    clc
    lda ptr
    adc #12
    sta ptr
    bcc @a
    inc ptr+1
@a:
    clc
    lda ptr2
    adc #16
    sta ptr2
    bcc @b
    inc ptr2+1
@b:
    dec cnt
    bne @row
    rts

; Рядок стану (рядки 56-63): лінія, "HP6  AM6  K1/6"
draw_status:
    lda #<(FB + VIEW_H * 16)
    sta ptr2
    lda #>(FB + VIEW_H * 16)
    sta ptr2+1
    ldy #0
    lda #$FF            ; лінія над рядком стану
@line:
    sta (ptr2),y
    iny
    cpy #16
    bne @line
    lda #0
@clr:
    sta (ptr2),y
    iny
    cpy #128
    bne @clr

    lda #VIEW_H + 2
    sta gy
    ldx #0
@txt:
    lda status_text,x
    cmp #$FF
    beq @num
    sta gidx
    stx tmp2
    lda status_nib,x
    sta nib
    jsr put_char
    ldx tmp2
    inx
    bra @txt
@num:
    lda #2
    sta nib
    lda hp
    sta gidx
    jsr put_char
    lda #8
    sta nib
    lda ammo
    sta gidx
    jsr put_char
    lda #13
    sta nib
    lda kills
    sta gidx
    jmp put_char

; Символ шрифту 4x5 gidx у півбайт nib (0-31), рядки gy..gy+4
put_char:
    lda gidx            ; font + gidx*5
    asl
    asl
    clc
    adc gidx
    tax
    lda #5
    sta cnt
    jsr nib_ptr
@r:
    lda font,x
    jsr put_nib
    inx
    tya
    clc
    adc #16
    tay
    dec cnt
    bne @r
    rts

; Мінікарта 5x5 у правому верхньому куті (поверх 3D-вікна)
draw_minimap:
    lda #<(FB + 13)     ; чорний фон: байти 13-15, рядки 0-20
    sta ptr2
    lda #>(FB + 13)
    sta ptr2+1
    ldx #21
@clr:
    ldy #2
    lda #0
@c2:
    sta (ptr2),y
    dey
    bpl @c2
    clc
    lda ptr2
    adc #16
    sta ptr2
    bcc @nc
    inc ptr2+1
@nc:
    dex
    bne @clr

    stz mm_r
@mr:
    stz mm_c
@mc:
    lda mm_r
    cmp #2
    bne @tile
    lda mm_c
    cmp #2
    bne @tile
    lda p_angle         ; гравець: стрілка в бік погляду
    clc
    adc #32
    lsr
    lsr
    lsr
    lsr
    lsr
    lsr
    clc
    adc #G_PLAYER
    bra @put
@tile:
    lda posX_hi
    sec
    sbc #2
    clc
    adc mm_c
    sta tx
    lda posY_hi
    sec
    sbc #2
    clc
    adc mm_r
    sta ty
    jsr get_tile
    tay
    lda tile_glyph,y
@put:
    sta gidx
    lda mm_c
    clc
    adc #27
    sta nib
    lda mm_r
    asl
    asl
    sta gy
    jsr put_glyph
    inc mm_c
    lda mm_c
    cmp #5
    bne @mc
    inc mm_r
    lda mm_r
    cmp #5
    bne @mr
    rts

; Гліф мінікарти 4x4 gidx у півбайт nib, рядки gy..gy+3
put_glyph:
    lda gidx
    asl
    asl
    tax
    lda #4
    sta cnt
    jsr nib_ptr
@r:
    lda mini_glyphs,x
    jsr put_nib
    inx
    tya
    clc
    adc #16
    tay
    dec cnt
    bne @r
    rts

; ptr = FB + gy*16 + nib/2, Y = 0
nib_ptr:
    lda gy
    lsr
    lsr
    lsr
    lsr
    clc
    adc #>FB
    sta ptr+1
    lda gy
    asl
    asl
    asl
    asl
    sta ptr
    lda nib
    lsr
    ora ptr
    sta ptr
    ldy #0
    rts

; записати 4 біти A у півбайт nib байта (ptr),y
put_nib:
    and #$0F
    sta tmp
    lda nib
    and #1
    bne @low
    lda tmp
    asl
    asl
    asl
    asl
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    rts
@low:
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    rts

; Передати на дисплей лише слова (16 пікселів), що змінилися від минулого
; кадру: копія переданого кадру лежить у SHADOW. force = 1 — передати все.
lcd_flush:
    stz yy
@row:
    lda #$FF            ; адресу треба виставити перед першим словом рядка
    sta nextw
    stz half
@half:
    lda yy              ; рядок буфера: yy або yy+32 (нижня половина GDRAM)
    ldx half
    beq @h0
    clc
    adc #32
@h0:
    sta tmp
    lsr
    lsr
    lsr
    lsr
    sta tmp2
    clc
    adc #>FB
    sta ptr2+1
    lda tmp2
    clc
    adc #>SHADOW
    sta ptr+1
    lda tmp
    asl
    asl
    asl
    asl
    sta ptr2
    sta ptr
    ldy #0
@word:
    lda force
    bne @send
    lda (ptr2),y
    cmp (ptr),y
    bne @send
    iny
    lda (ptr2),y
    cmp (ptr),y
    bne @send1
    iny
    bra @adv
@send1:
    dey
@send:
    tya                 ; номер слова: Y/2 + 8*half
    lsr
    ldx half
    beq @w0
    ora #8
@w0:
    sta tmp2
    cmp nextw
    beq @cont           ; продовжуємо підряд: адреса збільшилась сама
    lda yy
    ora #$80
    jsr lcd_cmd
    lda tmp2
    ora #$80
    jsr lcd_cmd
@cont:
    lda (ptr2),y
    sta (ptr),y
    jsr lcd_data
    iny
    lda (ptr2),y
    sta (ptr),y
    jsr lcd_data
    iny
    lda tmp2
    inc a
    sta nextw
@adv:
    cpy #16
    bne @word
    inc half
    lda half
    cmp #2
    bne @half
    inc yy
    lda yy
    cmp #32
    beq @done
    jmp @row
@done:
    stz force
    rts

; --- Допоміжне ------------------------------------------------------------------
text_screen:            ; вимкнути графіку, очистити текст
    lda #$34
    jsr lcd_cmd
    lda #$30
    jsr lcd_cmd
    lda #$01
    jmp lcd_cmd

wait_mid:               ; чекати натискання і відпускання MIDDLE
@w:
    lda PORTA
    and #BTN_MID
    bne @w
    lda #2
    jsr pause
@r:
    lda PORTA
    and #$1F
    cmp #$1F
    bne @r
    lda #2
    jmp pause

wait_tick:
    wai
    lda tick
    beq wait_tick
    stz tick
    rts

pause:                  ; A = кадрів по 20 мс
    sta cnt
@w:
    jsr wait_tick
    dec cnt
    bne @w
    rts

irq:
    bit T1CL
    inc tick
nmi:
    rti

; --- Дані -------------------------------------------------------------------------
.segment "RODATA"

s_title: .byte "MINI-DOOM 65C02", 0
s_sub:   .byte "1 MHZ RAYCASTER", 0
s_press: .byte "PRESS MIDDLE", 0
s_died:  .byte "YOU DIED", 0
s_exit:  .byte "EXIT FOUND!", 0
s_kills: .byte "KILLS: ", 0
s_again: .byte "MIDDLE = AGAIN", 0

dir_dx: .byte 1, $FF, 0, 0
dir_dy: .byte 0, 0, 1, $FF

bitmask8: .byte $80, $40, $20, $10, $08, $04, $02, $01

; рядок стану: символи і їхні півбайти; цифри HP/AM/K дописуються окремо
status_text: .byte CH_H, CH_P, CH_A, CH_M, CH_K, CH_SLASH, 6, $FF
status_nib:  .byte 0,    1,    6,    7,    12,   14,       15

tile_glyph: .byte G_EMPTY, G_WALL, G_WALL, G_WALL, G_WALL, G_DOOR, G_EXIT, G_DEMON

mini_glyphs:
    .byte %0000, %0000, %0000, %0000   ; 0 порожньо
    .byte %1111, %1111, %1111, %1111   ; 1 стіна
    .byte %0110, %0110, %0110, %0110   ; 2 двері
    .byte %1010, %0101, %1010, %0101   ; 3 вихід
    .byte %1001, %0110, %0110, %1001   ; 4 демон
    .byte %1100, %1110, %1110, %1100   ; 5 гравець на схід
    .byte %1111, %1111, %0110, %0110   ; 6 на південь
    .byte %0011, %0111, %0111, %0011   ; 7 на захід
    .byte %0110, %0110, %1111, %1111   ; 8 на північ

.include "doom_data.inc"

; Карта 32x32 з оригіналу: 1-4 стіни, 5 двері, 6 вихід, 7 демон
map_rom:
    .byte 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
    .byte 1,0,0,0,0,0,2,0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,3,0,0,0,0,0,0,0,1
    .byte 1,0,0,0,0,7,5,0,0,2,2,2,0,0,0,0,0,0,3,3,3,0,0,5,0,0,3,3,3,0,0,1
    .byte 1,0,0,0,0,0,2,0,7,2,0,2,0,0,0,0,0,0,3,0,7,0,0,3,0,0,0,0,3,0,0,1
    .byte 1,0,2,2,2,2,2,0,0,0,0,2,0,0,1,1,0,0,3,0,0,3,3,3,0,0,3,0,3,0,0,1
    .byte 1,2,2,0,5,0,2,0,0,0,0,0,0,0,1,1,0,0,0,0,0,3,3,0,0,0,3,0,0,0,0,1
    .byte 1,0,0,0,0,0,0,0,0,2,0,2,0,0,0,0,0,0,0,0,0,0,0,0,3,3,3,0,0,0,0,1
    .byte 1,0,2,2,2,0,7,0,0,2,5,2,0,0,0,0,0,0,3,0,3,0,0,0,0,0,0,0,3,0,0,1
    .byte 1,0,2,0,0,0,0,0,0,0,0,0,0,0,4,4,0,0,3,3,3,0,0,0,0,0,0,0,3,0,0,1
    .byte 1,0,2,0,0,2,2,0,0,0,0,0,0,0,4,4,0,0,0,0,0,0,0,3,0,3,0,0,0,0,0,1
    .byte 1,0,0,0,0,2,2,0,0,0,4,4,0,0,0,0,0,0,4,4,0,0,0,3,3,3,0,0,0,0,0,1
    .byte 1,2,2,2,0,0,0,0,0,0,4,0,0,0,0,7,0,0,0,4,0,0,0,0,0,0,0,3,3,3,1,1
    .byte 1,0,0,0,0,0,0,0,0,0,0,0,0,4,4,5,5,4,4,0,0,0,0,0,0,0,0,0,0,0,0,1
    .byte 1,0,0,2,0,0,0,0,4,4,0,0,0,4,0,0,0,0,4,0,0,0,4,4,0,0,0,3,0,0,0,1
    .byte 1,1,0,2,0,0,0,0,4,0,0,0,0,0,0,7,0,0,0,0,0,0,0,4,0,0,0,3,0,0,1,1
    .byte 1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,6,6,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1
    .byte 1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,6,6,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1
    .byte 1,1,0,2,0,0,0,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,0,0,0,3,0,0,1,1
    .byte 1,0,0,2,0,0,0,0,4,4,0,0,0,4,0,0,0,0,4,0,0,0,4,4,0,0,0,3,0,0,0,1
    .byte 1,0,0,0,0,0,0,0,0,0,0,0,0,4,4,5,5,4,4,0,0,0,0,0,0,0,0,0,0,0,0,1
    .byte 1,2,2,3,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,4,4,4,1,1
    .byte 1,0,0,0,0,0,2,2,0,0,4,4,0,0,0,0,0,0,4,4,0,0,0,4,0,0,0,0,0,0,0,1
    .byte 1,0,2,2,0,0,2,2,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,4,0,0,4,4,0,0,0,1
    .byte 1,0,2,0,0,0,0,0,0,0,0,0,0,0,1,1,0,0,0,0,4,4,4,4,0,0,4,4,0,0,0,1
    .byte 1,0,2,0,0,2,2,2,0,0,3,3,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,4,0,1
    .byte 1,0,0,0,0,2,0,0,0,0,3,3,0,0,0,0,0,0,0,0,4,0,0,4,4,4,0,0,0,4,0,1
    .byte 1,0,2,2,2,2,0,0,0,0,0,0,0,0,3,3,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,1
    .byte 1,0,0,0,0,0,0,0,2,2,0,0,0,0,3,3,0,0,4,4,0,0,0,4,0,0,4,4,4,0,0,1
    .byte 1,0,2,2,0,0,0,0,2,2,0,0,0,0,0,0,0,0,4,4,0,0,0,0,0,0,0,0,4,0,0,1
    .byte 1,0,2,2,0,0,2,0,0,0,0,3,3,0,0,0,0,0,0,0,0,0,4,4,0,0,0,0,0,0,0,1
    .byte 1,0,0,0,0,0,2,0,0,0,0,3,3,0,0,1,1,0,0,0,0,0,4,4,0,0,0,0,0,0,0,1
    .byte 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1

.segment "VECTORS"
    .word nmi, reset, irq
