"""Тести програм: демо, секундомір, гра "Вгадай число"."""
from util import board, press, run_tests, screen

MID, UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8, 16


def test_lcd_demo_shows_buttons():
    b = board("lcd_demo.s")
    b.run(150_000)
    assert screen(b)[2].startswith(". . . . .")
    b.set_button(UP, True)
    b.run(60_000)
    assert screen(b)[2].startswith(". # . . .")


def test_gfx_demo_fills_screen():
    b = board("gfx_demo.s")
    b.run(400_000)
    assert b.lcd.graphics and b.lcd.too_fast == 0
    assert b.lcd.pixel(0, 0) == 0 and b.lcd.pixel(4, 0) == 1


def test_timer_demo_counts_seconds():
    b = board("timer_demo.s")
    b.run(3_100_000)    # 3.1 с
    assert screen(b)[1].startswith("SECONDS: 3"), screen(b)[1]


def test_guess_game_binary_search_wins():
    b = board("guess.s")
    b.run(150_000)
    assert screen(b)[0] == "GUESS THE NUMBER"
    press(b, MID)
    lo, hi = 1, 99
    for _ in range(10):
        target = (lo + hi) // 2
        g = int(screen(b)[2][7:9])
        while g != target:
            if target - g >= 10:
                press(b, RIGHT)
            elif g - target >= 10:
                press(b, LEFT)
            elif target > g:
                press(b, UP)
            else:
                press(b, DOWN)
            g = int(screen(b)[2][7:9])
        press(b, MID)
        s = screen(b)
        if s[0].startswith("CORRECT"):
            assert int(s[1][8:10]) == target
            break
        if "LOW" in s[3]:
            lo = target + 1
        else:
            hi = target - 1
    else:
        raise AssertionError("не вгадав за 10 спроб")
    assert b.lcd.too_fast == 0 and b.lcd.early == 0


def test_pacman_starts_and_eats_dots():
    b = board("pacman.s")
    b.run(200_000)
    assert screen(b)[0].startswith("PAC-MAN 65C02")
    press(b, MID)
    b.run(1_500_000)                    # перемалювання і пауза перед стартом
    assert screen(b)[3].endswith("L3")
    b.set_button(LEFT, True)
    b.run(1_500_000)
    score = int(screen(b)[0][14:] + screen(b)[1][14:])
    assert score > 0, screen(b)
    assert b.lcd.graphics
    assert b.lcd.too_fast == 0 and b.lcd.early == 0


def test_doom_move_turn_and_kill_demon():
    b = board("doom.s")
    L, m = b.labels, b.mem
    b.run(200_000)
    assert screen(b)[0].startswith("MINI-DOOM 65C02")
    press(b, MID, gap=1_500_000)
    assert b.lcd.graphics
    assert (m[L["posX_hi"]], m[L["posY_hi"]], m[L["hp"]], m[L["ammo"]]) == (2, 2, 6, 6)

    press(b, MID, gap=1_500_000)        # демон прямо по курсу
    assert m[L["kills"]] == 1 and m[L["ammo"]] == 6

    press(b, RIGHT, gap=700_000)
    assert m[L["p_angle"]] == 8
    x0 = m[L["posX_hi"]] * 256 + m[L["posX_lo"]]
    press(b, UP, gap=700_000)
    assert m[L["posX_hi"]] * 256 + m[L["posX_lo"]] > x0
    assert b.lcd.too_fast == 0 and b.lcd.early == 0


if __name__ == "__main__":
    run_tests(globals())
