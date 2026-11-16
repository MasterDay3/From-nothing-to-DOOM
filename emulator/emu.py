"""Емулятор плати 65C02 PC: CPU + RAM + ROM + VIA + ST7920 + кнопки + світлодіоди.

Карта пам'яті (як на платі):
    $0000-$3FFF  RAM (16 KB)
    $4000-$5FFF  нічого не підключено: читання дає випадкове значення ("плаваюча" шина)
    $6000-$7FFF  VIA W65C22, 16 регістрів повторюються
    $8000-$FFFF  ROM (28C256)
Підключення VIA:
    PB0-PB7  дані ST7920 + 8 світлодіодів (через перемичку LED_EN)
    PA5 = RS, PA6 = R/W, PA7 = E дисплея
    PA0-PA4  кнопки MIDDLE, UP, DOWN, LEFT, RIGHT (0 = натиснута)
    IRQ VIA -> IRQ процесора

Наближення до реального заліза:
    - після ввімкнення RAM заповнена випадковими байтами (RESET її не чіпає);
    - дисплей приймає команди лише через 40 мс після ввімкнення / RESET;
    - час зайнятості дисплея рахується в мікросекундах з урахуванням частоти такту;
    - кнопки брязкотять ~3 мс після натискання і відпускання.
"""
import random
import sys

from py65.devices import mpu65c02
from py65.memory import ObservableMemory
from py65.utils.devices import make_instruction_decorator

RAM_END = 0x3FFF
VIA_START, VIA_END = 0x6000, 0x7FFF
ROM_START = 0x8000

PA_RS, PA_RW, PA_E = 0x20, 0x40, 0x80
BTN_MIDDLE, BTN_UP, BTN_DOWN, BTN_LEFT, BTN_RIGHT = 0x01, 0x02, 0x04, 0x08, 0x10
BOUNCE_US = 3000


class CPU(mpu65c02.MPU):
    """W65C02S: py65 + інструкції, яких у py65 немає (BBR/BBS, STP), і пробудження WAI."""

    instruct = mpu65c02.MPU.instruct[:]
    cycletime = mpu65c02.MPU.cycletime[:]
    extracycles = mpu65c02.MPU.extracycles[:]
    disassemble = mpu65c02.MPU.disassemble[:]
    instruction = make_instruction_decorator(instruct, disassemble, cycletime, extracycles)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.stopped = False

    def step(self):
        if self.stopped:
            self.processorCycles += 1
            return self
        return super().step()

    def irq(self):
        self.waiting = False            # WAI прокидається навіть при встановленому I
        if self.p & self.INTERRUPT:
            return
        super().irq()
        self.p &= ~self.DECIMAL         # 65C02 скидає D при перериванні

    def nmi(self):
        self.waiting = False
        super().nmi()
        self.p &= ~self.DECIMAL

    def _bb(self, bit, want):
        zp = self.ByteAt(self.pc)
        off = self.ByteAt((self.pc + 1) & 0xFFFF)
        self.pc = (self.pc + 2) & 0xFFFF
        if ((self.ByteAt(zp) >> bit) & 1) == want:
            if off & 0x80:
                off -= 0x100
            self.pc = (self.pc + off) & 0xFFFF
            self.excycles += 1

    @instruction(name="STP", mode="imp", cycles=3)
    def inst_0xdb(self):
        self.stopped = True


def _make_bb(op, bit, want):
    def f(self):
        self._bb(bit, want)
    f.__name__ = f"inst_0x{op:02x}"
    CPU.instruction(name=("BBS" if want else "BBR") + str(bit), mode="zpr", cycles=5)(f)


for _bit in range(8):
    _make_bb(0x0F + _bit * 0x10, _bit, 0)      # BBR0-7: $0F, $1F ... $7F
    _make_bb(0x8F + _bit * 0x10, _bit, 1)      # BBS0-7: $8F, $9F ... $FF


class ST7920:
    """Контролер дисплея 128x64, 8-бітний паралельний режим.

    Текстовий режим (4 рядки по 16 символів), графічний (GDRAM), читання
    флага зайнятості і RAM дисплея. Лічильники помилок:
        too_fast  записи, поки дисплей зайнятий (на залізі губляться);
        early     записи в перші 40 мс після ввімкнення/RESET (ігноруються);
        wide      символи >= $80 (справжній чип покаже ієрогліф на 2 клітинки).
    """

    EXEC_US = 72
    CLEAR_US = 1600
    POWERUP_US = 40000
    TEXT_ROWS = (0x00, 0x10, 0x08, 0x18)   # DDRAM-адреси початку рядків

    def __init__(self, now_us):
        self.now = now_us
        self.too_fast = self.early = self.wide = 0
        self.gdram = bytearray(random.getrandbits(8) for _ in range(32 * 32))  # після ввімкнення: сміття
        self.reset()

    def reset(self):
        self.ddram = bytearray(b" " * 64)
        self.ac = 0
        self.half = 0
        self.re = False
        self.graphics = False
        self.display_on = False
        self.gd_y = self.gd_x = 0
        self.gd_wait_x = False
        self.ready_at = self.now() + self.POWERUP_US
        self.busy_until = 0
        self.read_latch = 0
        self.prev_e = 0
        self.dirty = True

    def busy(self):
        return self.now() < self.busy_until

    def _start(self, us):
        """Початок виконання команди. False, якщо дисплей ще не прокинувся."""
        t = self.now()
        if t < self.ready_at:
            self.early += 1
            return False
        if t < self.busy_until:
            self.too_fast += 1
        self.busy_until = t + us
        self.dirty = True
        return True

    def command(self, v):
        if not self._start(self.CLEAR_US if (v == 0x01 and not self.re) else self.EXEC_US):
            return
        if v & 0x80:
            if self.re:
                if self.gd_wait_x:
                    self.gd_x = v & 0x0F
                    self.gd_wait_x = False
                else:
                    self.gd_y = v & 0x3F
                    self.gd_wait_x = True
            else:
                self.ac = v & 0x1F
            self.half = 0
        elif v & 0x40:
            pass                    # CGRAM / вертикальний скрол: не моделюється
        elif v & 0x20:              # function set
            self.re = bool(v & 0x04)
            if self.re:
                self.graphics = bool(v & 0x02)
        elif v & 0x10:
            pass                    # зсув курсора/дисплея: не моделюється
        elif v & 0x08:
            if not self.re:
                self.display_on = bool(v & 0x04)
        elif v & 0x04:
            pass                    # entry mode: завжди інкремент
        elif v & 0x02:
            if not self.re:
                self.ac = self.half = 0
        elif v == 0x01:
            if not self.re:
                self.ddram[:] = b" " * 64
                self.ac = self.half = 0

    def _ram_index(self):
        if self.re:
            return "g", (self.gd_y & 0x1F) * 32 + ((self.gd_x * 2 + self.half) & 0x1F)
        return "d", self.ac * 2 + self.half

    def _advance(self):
        self.half ^= 1
        if self.half == 0:
            if self.re:
                self.gd_x = (self.gd_x + 1) & 0x0F
            else:
                self.ac = (self.ac + 1) & 0x1F

    def data(self, v):
        if not self._start(self.EXEC_US):
            return
        kind, i = self._ram_index()
        if kind == "g":
            self.gdram[i] = v
        else:
            if v >= 0x80:
                self.wide += 1
            self.ddram[i] = v
        self._advance()

    def read_data(self):
        """Кінець циклу читання даних: як у чипа, перше читання після адреси — фіктивне."""
        kind, i = self._ram_index()
        self.read_latch = self.gdram[i] if kind == "g" else self.ddram[i]
        self._advance()

    def update(self, pa, pb):
        """Викликається при кожній зміні порту A або B."""
        e = pa & PA_E
        if self.prev_e and not e:                       # спад E
            if not (pa & PA_RW):
                if pa & PA_RS:
                    self.data(pb)
                else:
                    self.command(pb)
            elif pa & PA_RS:
                self.read_data()
        self.prev_e = e

    def output(self, pa):
        """Що дисплей видає на шину даних (коли R/W=1 і E=1), інакше None."""
        if not ((pa & PA_RW) and (pa & PA_E)):
            return None
        if pa & PA_RS:
            return self.read_latch
        return (0x80 if self.busy() else 0) | self.ac

    def text_row(self, r):
        base = self.TEXT_ROWS[r] * 2
        return bytes(self.ddram[base:base + 16])

    def pixel(self, x, y):
        if y < 32:
            byte = self.gdram[y * 32 + x // 8]
        else:
            byte = self.gdram[(y - 32) * 32 + 16 + x // 8]
        return (byte >> (7 - x % 8)) & 1


class VIA:
    """W65C22S: порти A/B, таймери T1/T2, прапорці й дозвіл переривань.

    Не моделюються: зсувний регістр, handshake на CA/CB, вихід T1 на PB7.
    """

    IRQ_T2, IRQ_T1 = 0x20, 0x40

    def __init__(self, board):
        self.board = board
        self.reset()

    def reset(self):
        self.orb = self.ora = self.ddrb = self.ddra = 0
        self.t1_latch = self.t1_count = 0
        self.t2_latch_lo = self.t2_count = 0
        self.t1_running = self.t2_running = False
        self.t1_armed = self.t2_armed = False
        self.acr = self.pcr = self.ifr = self.ier = self.sr = 0

    def pins_a(self):
        return (self.ora & self.ddra) | (self.board.button_pins() & ~self.ddra & 0xFF)

    def pins_b(self):
        inp = self.board.lcd.output(self.pins_a())
        if inp is None:
            inp = 0xFF
        return (self.orb & self.ddrb) | (inp & ~self.ddrb & 0xFF)

    def irq_active(self):
        return bool(self.ifr & self.ier & 0x7F)

    def tick(self, cycles):
        if self.t1_running:
            self.t1_count -= cycles
            while self.t1_count < 0:
                if self.t1_armed:
                    self.ifr |= self.IRQ_T1
                if self.acr & 0x40:                     # вільний біг: перезавантаження
                    self.t1_count += self.t1_latch + 2
                else:
                    self.t1_armed = False
                    self.t1_count &= 0xFFFF
                    break
        if self.t2_running:
            self.t2_count -= cycles
            if self.t2_count < 0:
                if self.t2_armed:
                    self.ifr |= self.IRQ_T2
                    self.t2_armed = False
                self.t2_count &= 0xFFFF

    def read(self, addr):
        reg = addr & 0x0F
        if reg == 0x0:
            return self.pins_b()
        if reg in (0x1, 0xF):
            return self.pins_a()
        if reg == 0x2:
            return self.ddrb
        if reg == 0x3:
            return self.ddra
        if reg == 0x4:
            self.ifr &= ~self.IRQ_T1
            return self.t1_count & 0xFF
        if reg == 0x5:
            return (self.t1_count >> 8) & 0xFF
        if reg == 0x6:
            return self.t1_latch & 0xFF
        if reg == 0x7:
            return self.t1_latch >> 8
        if reg == 0x8:
            self.ifr &= ~self.IRQ_T2
            return self.t2_count & 0xFF
        if reg == 0x9:
            return (self.t2_count >> 8) & 0xFF
        if reg == 0xA:
            return self.sr
        if reg == 0xB:
            return self.acr
        if reg == 0xC:
            return self.pcr
        if reg == 0xD:
            return (self.ifr & 0x7F) | (0x80 if self.irq_active() else 0)
        if reg == 0xE:
            return self.ier | 0x80
        return 0

    def write(self, addr, value):
        reg = addr & 0x0F
        if reg == 0x0:
            self.orb = value
        elif reg in (0x1, 0xF):
            self.ora = value
        elif reg == 0x2:
            self.ddrb = value
        elif reg == 0x3:
            self.ddra = value
        elif reg in (0x4, 0x6):
            self.t1_latch = (self.t1_latch & 0xFF00) | value
            return
        elif reg == 0x5:
            self.t1_latch = (self.t1_latch & 0x00FF) | (value << 8)
            self.t1_count = self.t1_latch
            self.t1_running = self.t1_armed = True
            self.ifr &= ~self.IRQ_T1
            return
        elif reg == 0x7:
            self.t1_latch = (self.t1_latch & 0x00FF) | (value << 8)
            self.ifr &= ~self.IRQ_T1
            return
        elif reg == 0x8:
            self.t2_latch_lo = value
            return
        elif reg == 0x9:
            self.t2_count = self.t2_latch_lo | (value << 8)
            self.t2_running = self.t2_armed = True
            self.ifr &= ~self.IRQ_T2
            return
        elif reg == 0xA:
            self.sr = value
            return
        elif reg == 0xB:
            self.acr = value
            return
        elif reg == 0xC:
            self.pcr = value
            return
        elif reg == 0xD:
            self.ifr &= ~value & 0x7F
            return
        elif reg == 0xE:
            if value & 0x80:
                self.ier |= value & 0x7F
            else:
                self.ier &= ~value & 0x7F
            return
        self.board.ports_changed()


class Board:
    def __init__(self, rom_path, hz=1_000_000):
        rom = open(rom_path, "rb").read()
        if len(rom) != 0x8000:
            sys.exit(f"ROM має бути 32768 байт, а не {len(rom)}")
        self.hz = hz
        self._t_us = 0.0
        self._t_cycles = 0
        self.mem = ObservableMemory()
        for a in range(0, RAM_END + 1):                 # RAM після ввімкнення: сміття
            self.mem[a] = random.getrandbits(8)
        self.mem[ROM_START:0x10000] = list(rom)
        self.buttons = 0xFF                             # 1 = відпущена (підтяжка 1k)
        self._bounce_until = [0.0] * 5
        self.led_en = True                              # перемичка JP1
        self.cpu = CPU(memory=self.mem)
        self.lcd = ST7920(self.now_us)
        self.via = VIA(self)

        self.mem.subscribe_to_read(range(VIA_START, VIA_END + 1), self.via.read)
        self.mem.subscribe_to_write(range(VIA_START, VIA_END + 1), self.via.write)
        self.mem.subscribe_to_read(range(RAM_END + 1, VIA_START), lambda a: random.getrandbits(8))
        self.mem.subscribe_to_write(range(ROM_START, 0x10000), self._rom_write)
        self.reset()

    def _rom_write(self, addr, value):
        return self.mem._subject[addr]       # ROM не змінюється

    def now_us(self):
        """Реальний час плати в мікросекундах (коректно і при зміні частоти)."""
        c = self.cpu.processorCycles
        self._t_us += (c - self._t_cycles) * 1e6 / self.hz
        self._t_cycles = c
        return self._t_us

    def set_hz(self, hz):
        self.now_us()
        self.hz = hz

    def set_button(self, mask, pressed):
        """Натиснути/відпустити кнопку; кілька мс після цього контакт брязкотить."""
        if pressed:
            self.buttons &= ~mask & 0xFF
        else:
            self.buttons |= mask
        t = self.now_us()
        for i in range(5):
            if mask & (1 << i):
                self._bounce_until[i] = t + BOUNCE_US

    def button_pins(self):
        pins = self.buttons
        t = self.now_us()
        for i in range(5):
            if t < self._bounce_until[i] and random.getrandbits(1):
                pins ^= 1 << i
        return pins

    def ports_changed(self):
        self.lcd.update(self.via.pins_a(), self.via.orb & self.via.ddrb)

    def leds(self):
        return (self.via.orb & self.via.ddrb) if self.led_en else 0

    def reset(self):
        """Кнопка RESET: скидає CPU, VIA і дисплей (RST дисплея на тій же лінії). RAM не чіпає."""
        self.via.reset()
        self.lcd.reset()
        self.cpu.reset()
        self.cpu.waiting = self.cpu.stopped = False
        self.cpu.pc = self.mem[0xFFFC] | (self.mem[0xFFFD] << 8)

    def run(self, cycles):
        cpu, via = self.cpu, self.via
        target = cpu.processorCycles + cycles
        while cpu.processorCycles < target:
            before = cpu.processorCycles
            cpu.step()
            if via.t1_running or via.t2_running:
                via.tick(cpu.processorCycles - before)
            if via.ifr & via.ier & 0x7F:
                cpu.irq()


def show_leds(value):
    return "".join("●" if value & (1 << b) else "○" for b in range(7, -1, -1))


if __name__ == "__main__":
    # Режим без вікна: python emu.py rom.bin [тактів]
    board = Board(sys.argv[1] if len(sys.argv) > 1 else "rom.bin")
    last = None
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
    while board.cpu.processorCycles < total:
        board.run(100)
        if board.leds() != last:
            last = board.leds()
            print("LED:", show_leds(last))
    for r in range(4):
        print("LCD|" + board.lcd.text_row(r).decode("latin-1") + "|")
    lcd = board.lcd
    print(f"PC=${board.cpu.pc:04X}  тактів: {board.cpu.processorCycles}")
    print(f"помилки LCD: занадто швидко={lcd.too_fast}, до 40 мс={lcd.early}, символи>=$80={lcd.wide}")
