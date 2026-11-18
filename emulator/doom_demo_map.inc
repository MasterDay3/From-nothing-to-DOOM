; Демонстрація: активна кімната x=1..9, y=1..5; решта 32x32 — стіна.
; Старт (2.5,2.5), кут 0. Демон 1=(4,2), двері=(5,2), вихід=(6,2),
; демон 2=(6,5): відстань 7 клітинок, перший хід ліворуч у (5,5).
.repeat 32
    .byte 1
.endrepeat
.byte 1,0,0,0,0,0,0,0,0,0,1
.repeat 21
    .byte 1
.endrepeat
.byte 1,0,0,0,7,5,6,0,0,0,1
.repeat 21
    .byte 1
.endrepeat
.byte 1,0,0,0,0,0,0,0,0,0,1
.repeat 21
    .byte 1
.endrepeat
.byte 1,0,0,0,0,0,0,0,0,0,1
.repeat 21
    .byte 1
.endrepeat
.byte 1,0,0,0,0,0,7,1,0,0,1
.repeat 21
    .byte 1
.endrepeat
.repeat 26 * 32
    .byte 1
.endrepeat
