"""Збірка програм для тестів: ca65 + ld65 у тимчасову папку."""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from emu import Board  # noqa: E402

VECTORS = """
.segment "VECTORS"
    .word nmi, reset, irq
"""


def build(source, name="prog"):
    """source: текст програми або ім'я .s-файлу в корені проєкту. Повертає шлях до rom.bin."""
    tmp = tempfile.mkdtemp()
    if source.endswith(".s"):
        src = os.path.join(ROOT, source)
    else:
        src = os.path.join(tmp, name + ".s")
        with open(src, "w") as f:
            f.write(source)
    obj = os.path.join(tmp, name + ".o")
    rom = os.path.join(tmp, "rom.bin")
    lbl = os.path.join(tmp, "labels.txt")
    subprocess.run(["ca65", "-g", "--cpu", "65C02", "-I", ROOT, src, "-o", obj], check=True)
    subprocess.run(["ld65", "-C", os.path.join(ROOT, "board.cfg"), obj, "-o", rom, "-Ln", lbl], check=True)
    return rom, lbl


def labels(path):
    """Файл ld65 -Ln -> {ім'я: адреса}."""
    out = {}
    for line in open(path):
        parts = line.split()             # al 000003 .posX_lo
        if len(parts) == 3:
            out[parts[2].lstrip(".")] = int(parts[1], 16)
    return out


def board(source):
    rom, lbl = build(source)
    b = Board(rom)
    b.labels = labels(lbl)
    return b


def screen(b):
    return [b.lcd.text_row(r).decode("latin-1") for r in range(4)]


def press(b, mask, hold=30000, gap=40000):
    b.set_button(mask, True)
    b.run(hold)
    b.set_button(mask, False)
    b.run(gap)


def run_tests(module_globals):
    tests = [(n, f) for n, f in module_globals.items() if n.startswith("test_") and callable(f)]
    failed = 0
    for name, f in tests:
        try:
            f()
            print("ok  ", name)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("FAIL", name, "-", type(e).__name__, e)
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
