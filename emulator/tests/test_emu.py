"""Тести самого емулятора: CPU, VIA, ST7920, кнопки, пам'ять."""
from util import board, run_tests

HEAD = """
.segment "CODE"
nmi:
irq:
    rti
"""
TAIL = """
.segment "VECTORS"
    .word nmi, reset, irq
"""


def prog(body, irq="    rti"):
    return f"""
.segment "CODE"
nmi:
    rti
irq:
{irq}
reset:
    ldx #$FF
    txs
{body}
done:
    bra done
""" + TAIL


def test_ram_is_random_after_power_on():
    b = board(prog("    nop"))
    values = {b.mem[a] for a in range(0x0200, 0x0300)}
    assert len(values) > 50, "RAM має містити сміття, а не нулі"


def test_reset_keeps_ram():
    b = board(prog("    lda #$42\n    sta $0300"))
    b.run(100)
    b.reset()
    assert b.mem[0x0300] == 0x42


def test_unmapped_area_reads_random():
    b = board(prog("    nop"))
    values = {b.mem[0x4000] for _ in range(50)}
    assert len(values) > 10


def test_rom_is_read_only():
    b = board(prog("    lda #$00\n    sta $9000"))
    before = b.mem[0x9000]
    b.run(100)
    assert b.mem[0x9000] == before


def test_bbr_bbs_smb_rmb():
    b = board(prog("""
    stz $10
    smb3 $10
    bbs3 $10, @set
    lda #$EE
    bra done
@set:
    rmb3 $10
    bbr3 $10, @clr
    lda #$EE
    bra done
@clr:
    lda #$AA
"""))
    b.run(200)
    assert b.cpu.a == 0xAA


def test_stp_stops_cpu():
    b = board(prog("    lda #$11\n    stp\n    lda #$22"))
    b.run(200)
    assert b.cpu.stopped and b.cpu.a == 0x11


def test_via_t1_irq_wakes_wai():
    b = board(prog("""
    stz $20
    lda #%01000000
    sta $600B           ; T1 вільний біг
    lda #<998
    sta $6004
    lda #>998
    sta $6005           ; 1000 тактів
    lda #%11000000
    sta $600E
    cli
@loop:
    wai
    bra @loop
""", irq="""    pha
    bit $6004
    inc $20
    pla
    rti"""))
    b.run(10_500)
    assert 9 <= b.mem[0x20] <= 10, b.mem[0x20]


def test_t2_one_shot_sets_flag_once():
    b = board(prog("""
    lda #<500
    sta $6008
    lda #>500
    sta $6009
"""))
    b.run(300)
    assert not b.via.ifr & 0x20
    b.run(400)
    assert b.via.ifr & 0x20


def test_lcd_ignores_commands_in_first_40ms():
    src = """.include "lcd.inc"
.segment "CODE"
reset:
    ldx #$FF
    txs
    jsr via_init
    lda #$0C
    jsr lcd_cmd         ; без очікування 40 мс
done:
    bra done
nmi:
irq:
    rti
""" + TAIL
    b = board(src)
    b.run(5000)
    assert b.lcd.early == 1 and not b.lcd.display_on


def test_lcd_init_waits_and_shows_text():
    b = board("lcd_demo.s")
    b.run(150_000)
    assert b.lcd.early == 0 and b.lcd.too_fast == 0
    assert b.lcd.text_row(0).startswith(b"HELLO 65C02 PC!")


def test_lcd_timing_is_real_time_not_cycles():
    # затримка в lcd_init розрахована на 1 MHz; при 2 MHz вона триває 25 мс < 40 мс,
    # і емулятор має це помітити
    b = board("lcd_demo.s")
    b.set_hz(2_000_000)
    b.run(300_000)
    assert b.lcd.early > 0


def test_buttons_bounce():
    b = board(prog("    nop"))
    b.run(10)
    b.set_button(0x02, True)
    seen = {b.via.pins_a() & 0x02 for _ in range(100)}
    assert seen == {0, 2}, "одразу після натискання контакт брязкотить"
    b.run(5000)
    assert all(not b.via.pins_a() & 0x02 for _ in range(50))


if __name__ == "__main__":
    run_tests(globals())
