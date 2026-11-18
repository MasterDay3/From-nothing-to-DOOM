# Емулятор плати 65C02 PC
#   make run PROG=guess     зібрати guess.s і запустити у вікні
#   make cli PROG=guess     запустити без вікна
#   make test               автотести емулятора і програм
PROG ?= lcd_demo
PY ?= python3
CA65 ?= ca65
LD65 ?= ld65
.DEFAULT_GOAL := rom.bin
export CA65 LD65

check-cpu:
	@tmp=$$(mktemp -d) || exit 1; \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	printf '.segment "CODE"\n    wai\n    stp\n' > "$$tmp/check.s"; \
	if ! $(CA65) --cpu W65C02 "$$tmp/check.s" -o "$$tmp/check.o" >/dev/null 2>&1; then \
	    printf '%s\n' 'Помилка: ca65 не підтримує ціль W65C02 з інструкціями WAI і STP.' \
	        'Встановіть перевірену ревізію cc65 за інструкціями в emulator/README.md і перевірте PATH або CA65.' >&2; \
	    exit 1; \
	fi

rom.bin: $(PROG).s lcd.inc board.cfg doom_data.inc | check-cpu
	$(CA65) --cpu W65C02 $(PROG).s -o $(PROG).o
	$(LD65) -C board.cfg $(PROG).o -o rom.bin

run: rom.bin
	$(PY) gui.py rom.bin

cli: rom.bin
	$(PY) emu.py rom.bin 200000

test: check-cpu
	cd tests && $(PY) test_emu.py && $(PY) test_programs.py

clean:
	rm -f *.o rom.bin

.PHONY: rom.bin run cli test clean check-cpu
