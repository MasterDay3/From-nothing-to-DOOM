# 65C02 PC emulator

Емулятор плати 65C02 PC: W65C02S, RAM 16 KB, ROM 32 KB, VIA W65C22S,
дисплей ST7920 128x64, 5 кнопок, 8 світлодіодів.

## Встановлення

Для збірки потрібен `ca65` із підтримкою цілі `W65C02` та інструкцій
`WAI` і `STP`. Не кожна пакетна версія cc65 її підтримує: зокрема, якщо
Homebrew-версія повідомляє `Invalid CPU: 'W65C02'`, встановіть перевірену
ревізію з вихідного коду. Перевірено коміт cc65
`eebf54af545f4ae52f8489a2f6d4d5f93e7942d2` (`ca65 V2.19 - Git eebf54a`).
На macOS з установленими Git і Command Line Tools виконайте:

```sh
mkdir -p "$HOME/src"
git clone https://github.com/cc65/cc65.git "$HOME/src/cc65-w65c02"
git -C "$HOME/src/cc65-w65c02" checkout eebf54af545f4ae52f8489a2f6d4d5f93e7942d2
make -C "$HOME/src/cc65-w65c02" bin
export PATH="$HOME/src/cc65-w65c02/bin:$PATH"
ca65 --version
```

`export` діє у поточному терміналі; додайте його до конфігурації оболонки,
якщо потрібен постійний доступ. Для іншої версії cc65 `make` перевіряє
підтримку цілі та обох інструкцій перед збіркою і тестами. Конкретні шляхи
до інструментів можна задати через `CA65` і `LD65`.

Python-залежності (з каталогу `emulator`):

```sh
python3.12 -m venv .venv312
.venv312/bin/python -m pip install -r requirements.txt
```

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

MINI-DOOM використовує 64 промені по два пікселі та framebuffer 128×64.
Демони діють кожні 500 тіків таймера T1 (10 секунд при 1 МГц), навіть якщо
гравець не рухається. У межах 6 клітинок за мангеттенською відстанню демон
стріляє на 1 HP, якщо має пряму видимість; стіни, двері й кути її блокують.
Інакше він пробує крок по X, а потім по Y. Інтервал, дальність і шкода —
константи `MOB_INTERVAL`, `MOB_RANGE` і `MOB_DAMAGE` у `doom.s`.
Таблиці й текстури генеруються командою
`python3 tools/gen_doom_data.py > doom_data.inc`.
Для збереження кадрів і циклів поточної збірки (потрібні `ca65`, `ld65`,
`py65` та `pygame`):

```sh
.venv312/bin/python tools/texture_benchmark.py after
```

Скрипт перезаписує ROM, map-файл, збільшені PNG з GDRAM та виміри циклів
у `texture-comparison/after/`. Це цикли моделі емулятора, а не вимірювання
на платі. Параметр `before` записує в окремий каталог базового варіанта.

Наприклад, щоб використати це середовище для тестів і GUI:

```sh
make PROG=doom
make test PY=.venv312/bin/python
.venv312/bin/python gui.py rom.bin
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
