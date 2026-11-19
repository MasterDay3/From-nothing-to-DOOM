#!/bin/sh
# Зібрати ROM лаунчера: меню + DOOM + Вгадай число + Змійка.
#   ./launcher/build.sh
#   ./emulator_c/build/sim rom.bin
#
# Кожна гра асемблюється з emulator/*.s без жодних змін і лінкується у свій
# слот ROM; потім launcher.s підключає слоти через .incbin.
set -eu
cd "$(dirname "$0")/.."

CA65=${CA65:-ca65}
LD65=${LD65:-ld65}
OUT=launcher/build

# Карта ROM — єдине місце, де задано адреси слотів (слоти йдуть підряд).
GUESS_START=0x8800      # $8000-$87FF меню (2 KB)
SNAKE_START=0x9000      # Вгадай число (2 KB)
DOOM_START=0xA000       # Змійка (4 KB)
SLOTS_END=0xFFFA        # DOOM (~24 KB), далі вектори CPU

mkdir -p "$OUT"
rm -f "$OUT"/pacman.*

# slot ГРА ПОЧАТОК КІНЕЦЬ
slot() {
    "$CA65" --cpu 65C02 "emulator/$1.s" -o "$OUT/$1.o"
    "$LD65" -C launcher/slot.cfg -D SLOT_START=$(($2)) -D SLOT_SIZE=$(($3 - $2)) \
        "$OUT/$1.o" -o "$OUT/$1.slot" -m "$OUT/$1.map"
    used=0
    # рядки "Segment list" у .map: Name Start End Size Align
    for size in $(awk '($1 == "CODE" || $1 == "RODATA") && $2 ~ /^[0-9A-F]+$/ { print $4 }' "$OUT/$1.map"); do
        used=$((used + 0x$size))
    done
    printf '  %-7s $%04X-$%04X  %5d / %5d bytes\n' "$1" $(($2)) $(($3 - 1)) "$used" $(($3 - $2 - 6))
}

echo "ROM slots:"
slot guess  $GUESS_START  $SNAKE_START
slot snake  $SNAKE_START  $DOOM_START
slot doom   $DOOM_START   $SLOTS_END

"$CA65" --cpu 65C02 launcher/launcher.s -o "$OUT/launcher.o"
"$LD65" -C emulator_c/rom.cfg "$OUT/launcher.o" -o "$OUT/rom.bin" -m "$OUT/launcher.map"

size=$(wc -c < "$OUT/rom.bin" | tr -d ' ')
[ "$size" -eq 32768 ] || { echo "error: $OUT/rom.bin is $size bytes, expected 32768" >&2; exit 1; }
cp "$OUT/rom.bin" rom.bin
echo "OK: $OUT/rom.bin (copied to rom.bin)"
echo "Run: ./emulator_c/build/sim rom.bin"
