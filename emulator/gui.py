"""Віконний емулятор плати: дисплей, світлодіоди, кнопки, RESET, налагодження.

Запуск:  python gui.py rom.bin [--mhz 1]
Клавіші:
    стрілки, пробіл   кнопки UP/DOWN/LEFT/RIGHT/MIDDLE
    R                 кнопка RESET
    L                 перемичка LED_EN (світлодіоди вкл/викл)
    P                 пауза / продовжити
    S                 один крок (інструкція) на паузі
    + / -             частота такту (x2 / /2)
    Esc               вихід
"""
import argparse
import time

import pygame

from emu import Board, BTN_MIDDLE, BTN_UP, BTN_DOWN, BTN_LEFT, BTN_RIGHT

SCALE = 5
LCD_W, LCD_H = 128 * SCALE, 64 * SCALE
PAD = 20
WIN_W = LCD_W + 2 * PAD
WIN_H = LCD_H + 2 * PAD + 180

BG = (30, 30, 34)
LCD_BG = (25, 55, 200)
LCD_FG = (225, 235, 255)
LCD_OFF = (15, 25, 60)
LED_ON = (255, 60, 50)
LED_OFF = (70, 25, 25)
TEXT = (220, 220, 220)
DIM = (140, 140, 150)
WARN = (255, 90, 80)

KEYS = {
    pygame.K_SPACE: BTN_MIDDLE, pygame.K_UP: BTN_UP, pygame.K_DOWN: BTN_DOWN,
    pygame.K_LEFT: BTN_LEFT, pygame.K_RIGHT: BTN_RIGHT,
}

# байт (8 пікселів) -> 24 байти RGB, щоб малювати екран без циклу по пікселях
_FG, _BG = bytes(LCD_FG), bytes(LCD_BG)
BYTE_RGB = [b"".join(_FG if b & (0x80 >> i) else _BG for i in range(8)) for b in range(256)]


def make_font():
    """8x16 шрифт для текстового режиму: glyph[code] = 16 байтів (по рядку пікселів)."""
    font = pygame.font.SysFont("menlo,dejavusansmono,consolas,couriernew,monospace", 12)
    glyphs = {}
    for code in range(32, 127):
        surf = pygame.Surface((8, 16))
        surf.fill((0, 0, 0))
        g = font.render(chr(code), False, (255, 255, 255))
        surf.blit(g, ((8 - g.get_width()) // 2, (16 - g.get_height()) // 2))
        rows = []
        for y in range(16):
            b = 0
            for x in range(8):
                if surf.get_at((x, y))[0] > 128:
                    b |= 0x80 >> x
            rows.append(b)
        glyphs[code] = rows
    # символи >= $80 на справжньому чипі — ієрогліфи; показуємо заштрихованими
    glyphs["wide"] = [0xAA if y % 2 else 0x55 for y in range(16)]
    return glyphs


def render_lcd(board, glyphs, surf):
    lcd = board.lcd
    if not lcd.display_on:
        surf.fill(LCD_OFF)
        return
    mono = bytearray(1024)                     # 64 рядки по 16 байтів
    if lcd.graphics:
        g = lcd.gdram
        for y in range(32):
            mono[y * 16:(y + 1) * 16] = g[y * 32:y * 32 + 16]
            mono[(y + 32) * 16:(y + 33) * 16] = g[y * 32 + 16:y * 32 + 32]
    blank = glyphs[32]
    for r in range(4):
        for i, code in enumerate(lcd.text_row(r)):
            rows = glyphs["wide"] if code >= 0x80 else glyphs.get(code, blank)
            if rows is blank:
                continue
            base = r * 256 + i
            for line in range(16):
                mono[base + line * 16] ^= rows[line]   # текст і графіка: XOR
    rgb = b"".join(BYTE_RGB[b] for b in mono)
    surf.blit(pygame.image.frombuffer(rgb, (128, 64), "RGB"), (0, 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom", nargs="?", default="rom.bin")
    ap.add_argument("--mhz", type=float, default=1.0, help="частота такту")
    ap.add_argument("--shot", help="зберегти скріншот після --cycles тактів і вийти")
    ap.add_argument("--cycles", type=int, default=200000)
    args = ap.parse_args()

    pygame.init()
    board = Board(args.rom, hz=args.mhz * 1e6)
    screen = pygame.display.set_mode((WIN_W, WIN_H))
    pygame.display.set_caption("65C02 PC emulator")
    glyphs = make_font()
    ui = pygame.font.SysFont("menlo,dejavusansmono,consolas,monospace", 14)
    lcd_surf = pygame.Surface((128, 64))

    if args.shot:
        board.run(args.cycles)
        render_lcd(board, glyphs, lcd_surf)
        draw(screen, board, lcd_surf, ui, False, 0)
        pygame.image.save(screen, args.shot)
        return

    paused = False
    clock = pygame.time.Clock()
    real_hz = 0.0
    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                return
            if ev.type == pygame.KEYDOWN:
                if ev.key == pygame.K_ESCAPE:
                    return
                if ev.key in KEYS:
                    board.set_button(KEYS[ev.key], True)
                elif ev.key == pygame.K_r:
                    board.reset()
                elif ev.key == pygame.K_l:
                    board.led_en = not board.led_en
                elif ev.key == pygame.K_p:
                    paused = not paused
                elif ev.key == pygame.K_s and paused:
                    board.run(1)
                    board.lcd.dirty = True
                elif ev.key in (pygame.K_PLUS, pygame.K_EQUALS, pygame.K_KP_PLUS):
                    board.set_hz(min(board.hz * 2, 16e6))
                elif ev.key in (pygame.K_MINUS, pygame.K_KP_MINUS):
                    board.set_hz(max(board.hz / 2, 1))
            if ev.type == pygame.KEYUP and ev.key in KEYS:
                board.set_button(KEYS[ev.key], False)

        if not paused:
            # такти за кадр (1/60 с), але не довше ~15 мс реального часу
            budget = int(board.hz / 60)
            start_c = board.cpu.processorCycles
            t0 = time.perf_counter()
            while board.cpu.processorCycles - start_c < budget and time.perf_counter() - t0 < 0.015:
                board.run(min(2000, budget))
            done = board.cpu.processorCycles - start_c
            real_hz = real_hz * 0.9 + done * 60 * 0.1

        if board.lcd.dirty:
            render_lcd(board, glyphs, lcd_surf)
            board.lcd.dirty = False
        draw(screen, board, lcd_surf, ui, paused, real_hz)
        pygame.display.flip()
        clock.tick(60)


def draw(screen, board, lcd_surf, ui, paused, real_hz):
    screen.fill(BG)
    pygame.draw.rect(screen, (10, 10, 10), (PAD - 6, PAD - 6, LCD_W + 12, LCD_H + 12), border_radius=4)
    screen.blit(pygame.transform.scale(lcd_surf, (LCD_W, LCD_H)), (PAD, PAD))

    y = PAD + LCD_H + 18
    leds = board.leds()
    for i in range(8):
        bit = 7 - i
        cx = PAD + 20 + i * 40
        pygame.draw.circle(screen, LED_ON if leds & (1 << bit) else LED_OFF, (cx, y + 10), 11)
        screen.blit(ui.render(f"PB{bit}", True, DIM), (cx - 14, y + 24))
    screen.blit(ui.render("LED_EN: " + ("ON" if board.led_en else "OFF"), True, TEXT),
                (PAD + 345, y + 2))

    names = ("MID", "UP", "DOWN", "LEFT", "RIGHT")
    x = PAD + 345
    for i, n in enumerate(names):
        pressed = not (board.buttons >> i) & 1
        screen.blit(ui.render(n, True, LED_ON if pressed else DIM), (x, y + 24))
        x += len(n) * 9 + 10

    c = board.cpu
    y += 56
    state = "  [STP]" if c.stopped else ("  [WAI]" if c.waiting else "")
    regs = (f"PC=${c.pc:04X} A=${c.a:02X} X=${c.x:02X} Y=${c.y:02X} SP=${c.sp:02X} "
            f"P=${c.p:02X}  cycles={c.processorCycles}{state}")
    screen.blit(ui.render(regs, True, TEXT), (PAD, y))
    status = (f"clock {board.hz/1e6:.3g} MHz, real {real_hz/1e6:.2f} MHz"
              + ("   [PAUSED]" if paused else ""))
    screen.blit(ui.render(status, True, TEXT), (PAD, y + 22))
    lcd = board.lcd
    errs = lcd.too_fast + lcd.early + lcd.wide
    err = f"LCD errors: too fast {lcd.too_fast}, before 40ms {lcd.early}, chars>=$80 {lcd.wide}"
    screen.blit(ui.render(err, True, WARN if errs else DIM), (PAD, y + 44))
    screen.blit(ui.render("arrows/space=buttons  R=reset  L=LED_EN  P=pause  S=step  +/-=clock",
                          True, DIM), (PAD, y + 72))


if __name__ == "__main__":
    main()
