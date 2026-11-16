# 65C02 PC emulator

Емулятор плати 65C02 PC: W65C02S, RAM 16 KB, ROM 32 KB, VIA W65C22S,
дисплей ST7920 128x64, 5 кнопок, 8 світлодіодів.

## Встановлення

- cc65: `sudo dnf install cc65` (Fedora), `sudo apt install cc65` (Ubuntu), `brew install cc65` (macOS)
- Python-пакети: `pip3 install -r requirements.txt`

## Запуск

```
make run PROG=doom         # MINI-DOOM (raycaster)
make run PROG=pacman       # PAC-MAN
make run PROG=guess        # гра "Вгадай число"
make run PROG=lcd_demo     # текст + стан кнопок
make run PROG=gfx_demo     # графічний режим
make run PROG=timer_demo   # таймер VIA + переривання
make run PROG=blink        # біжучий вогник
make test                  # автотести
```

Клавіші у вікні: стрілки/пробіл — кнопки, R — RESET, L — перемичка LED_EN,
P — пауза, S — крок, +/- — частота такту, Esc — вихід.

## Файли

| Файл | Що це |
|---|---|
| `emu.py` | ядро: CPU, пам'ять, VIA, ST7920, кнопки |
| `gui.py` | вікно (pygame) |
| `board.cfg` | конфіг лінкера під карту пам'яті плати |
| `lcd.inc` | драйвер дисплея на асемблері (`lcd_init`, `lcd_cmd`, `lcd_data`, `lcd_print`, `lcd_num`, `PRINT`) |
| `*.s` | програми |
| `doom_data.inc` | таблиці для doom.s, генерує `python3 tools/gen_doom_data.py > doom_data.inc` |
| `tests/` | автотести |

`rom.bin`, що збирає `make`, прошивається в EEPROM без змін.

## Чим емулятор відрізняється від плати

Наближено до заліза: випадковий вміст RAM після ввімкнення, 40 мс до готовності
дисплея, час виконання команд дисплея в мікросекундах, брязкіт кнопок,
"плаваюча" шина на `$4000-$5FFF`.

Не моделюються: зсувний регістр і handshake VIA, вихід T1 на PB7, CGRAM і
скрол ST7920, справжній шрифт дисплея (використовується системний),
електричні ефекти (навантаження світлодіодів на шину, рівні напруг).
Затримка в `lcd_init` розрахована на 1 MHz.
