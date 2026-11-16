# Емулятор плати 65C02 PC
#   make run PROG=guess     зібрати guess.s і запустити у вікні
#   make cli PROG=guess     запустити без вікна
#   make test               автотести емулятора і програм
PROG ?= lcd_demo
PY ?= python3

rom.bin: $(PROG).s lcd.inc board.cfg doom_data.inc
	ca65 --cpu 65C02 $(PROG).s -o $(PROG).o
	ld65 -C board.cfg $(PROG).o -o rom.bin

run: rom.bin
	$(PY) gui.py rom.bin

cli: rom.bin
	$(PY) emu.py rom.bin 200000

test:
	cd tests && $(PY) test_emu.py && $(PY) test_programs.py

clean:
	rm -f *.o rom.bin

.PHONY: rom.bin run cli test clean
