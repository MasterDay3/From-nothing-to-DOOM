#include <SDL.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "vrEmu6502.h"
#include "vrEmu6522.h"
#include "St7920Emulator.hpp"

// ======================= Board configuration =======================
#define LCD_RS_BIT   0x20      // PA5
#define LCD_RW_BIT   0x40      // PA6
#define LCD_E_BIT    0x80      // PA7
#define VIA_BASE     0x6000    // $6000-$7FFF
#define USE_VIA_IRQ  1         // set to 0 if the IRQ lines below don't compile

// ======================= Machine state =======================
static uint8_t ram[0x4000];
static uint8_t rom[0x8000];
static VrEmu6522 *via = nullptr;
static VrEmu6502 *cpu = nullptr;

static uint8_t outA = 0, outB = 0, ddrA = 0, ddrB = 0;
static uint8_t buttons = 0x1F;          // PA0-PA4, 1 = released (1k pull-ups R5-R9)
static uint64_t bounceUntil[5] = {0};   // 3 ms mechanical switch bounce on SW2-SW6
static bool ledEn = true;               // JP1 (LED_EN) jumper
static bool lcdEn = true;               // LCD_EN jumper on PA7 (E)
static bool lastE = false;

static uint32_t pixels[128 * 64];
static bool quitRequested = false;
static int exitCode = 0;
static uint64_t cycles = 0;
static double clockHz = 1000000.0;

// ST7920 hardware timing & readback state (40 ms wake-up, 72 us exec, 1600 us clear)
static uint64_t lcdReadyCycle = 0;
static uint64_t lcdBusyCycle = 0;
static bool lcdExtended = false;
static bool lcdGdWaitX = false;
static uint8_t lcdAc = 0, lcdHalf = 0, lcdGdY = 0, lcdGdX = 0, lcdReadLatch = 0;
static uint8_t lcdDdram[64];
static uint8_t lcdGdram[1024];
static unsigned lcdEarly = 0, lcdTooFast = 0;

static uint64_t usToCycles(uint64_t us) {
    uint64_t c = (uint64_t)((double)us * clockHz / 1000000.0);
    return c > 0 ? c : 1;
}

// ======================= LCD =======================
static constexpr uint32_t LCD_BG = 0xFF1937C8;  // (25, 55, 200) blue ST7920 background
static constexpr uint32_t LCD_FG = 0xFFE1EBFF;  // (225, 235, 255) white ST7920 active pixel

static void clearDisplay() {
    for (auto &p : pixels) p = LCD_BG;
}

static void drawByte(uint8_t x, uint8_t y, uint8_t d) {
    if (y >= 64) return;
    for (uint8_t i = 0; i < 8; ++i) {
        int px = x + i;
        if (px >= 128) break;
        pixels[y * 128 + px] = (d & (1 << i)) ? LCD_FG : LCD_BG;
    }
}

static St7920Emulator lcd(clearDisplay, drawByte);

static void lcdAdvance() {
    lcdHalf ^= 1;
    if (lcdHalf == 0) {
        if (lcdExtended) lcdGdX = (lcdGdX + 1) & 0x0F;
        else             lcdAc  = (lcdAc  + 1) & 0x1F;
    }
}

static void lcdReset() {
    lcd.reset(true);
    memset(lcdDdram, ' ', sizeof lcdDdram);
    lcdExtended = false;
    lcdGdWaitX = false;
    lcdAc = lcdHalf = lcdGdY = lcdGdX = lcdReadLatch = 0;
    lcdBusyCycle = 0;
    lcdReadyCycle = cycles + usToCycles(40000);     // 40 ms power-on / RST wake-up
}

static void lcdWrite(bool rs, uint8_t d) {
    if (cycles < lcdReadyCycle) { ++lcdEarly; return; }
    if (cycles < lcdBusyCycle)  { ++lcdTooFast; return; }

    bool isClear = (!rs && !lcdExtended && d == 0x01);
    lcdBusyCycle = cycles + usToCycles(isClear ? 1600 : 72);

    if (!rs) {
        if (d & 0x80) {
            if (lcdExtended) {
                if (lcdGdWaitX) { lcdGdX = d & 0x0F; lcdGdWaitX = false; }
                else            { lcdGdY = d & 0x3F; lcdGdWaitX = true;  }
            } else {
                lcdAc = d & 0x1F;
            }
            lcdHalf = 0;
        } else if ((d & 0xE0) == 0x20) {
            lcdExtended = (d & 0x04) != 0;
        } else if (!lcdExtended && (d & 0xFE) == 0x02) {
            lcdAc = lcdHalf = 0;
        } else if (!lcdExtended && d == 0x01) {
            memset(lcdDdram, ' ', sizeof lcdDdram);
            lcdAc = lcdHalf = 0;
        }
    } else {
        if (lcdExtended)
            lcdGdram[(lcdGdY & 0x1F) * 32 + ((lcdGdX * 2 + lcdHalf) & 0x1F)] = d;
        else
            lcdDdram[(lcdAc * 2 + lcdHalf) & 0x3F] = d;
        lcdAdvance();
    }

    if (!rs && d >= 0x04 && d <= 0x07) return;      // entry mode: breaks St7920Emulator
    if (!rs && d == 0x34) d = 0x36;                 // allow GDRAM writes under $34
    lcd.parseSerialData(rs ? 0xFA : 0xF8);
    lcd.parseSerialData(d & 0xF0);
    lcd.parseSerialData((d << 4) & 0xF0);
}

static void lcdReadData() {
    if (lcdExtended)
        lcdReadLatch = lcdGdram[(lcdGdY & 0x1F) * 32 + ((lcdGdX * 2 + lcdHalf) & 0x1F)];
    else
        lcdReadLatch = lcdDdram[(lcdAc * 2 + lcdHalf) & 0x3F];
    lcdAdvance();
}

// Re-evaluate the LCD control lines after any change to ORA or DDRA.
static void evalPortA() {
    uint8_t pins = outA & ddrA;                     // undriven pins read as low
    bool e = lcdEn && (pins & LCD_E_BIT);
    if (lastE && !e) {                              // falling edge of E
        if (!(pins & LCD_RW_BIT))
            lcdWrite(pins & LCD_RS_BIT, outB & ddrB);
        else if (pins & LCD_RS_BIT)
            lcdReadData();                          // R/W=1, RS=1: dummy-first-read latch
    }
    lastE = e;
}

static bool backlightOn() {
    return true;                                    // BLA/BLK hardwired to VCC/GND
}

static uint8_t buttonPins() {
    uint8_t b = buttons;
    for (int i = 0; i < 5; ++i) {
        if (cycles < bounceUntil[i] && (rand() & 1))
            b ^= (1 << i);
    }
    return b | 0xE0;                                // PA5-PA7 float high when inputs
}

// ======================= VIA / bus =======================
static uint8_t viaRead(uint8_t reg) {
    switch (reg) {
        case 0x00: {
            uint8_t pa = outA & ddrA;
            uint8_t inB = 0x00;                     // LED path pulls undriven inputs low
            if (lcdEn && (pa & LCD_E_BIT) && (pa & LCD_RW_BIT)) {
                bool busy = (cycles < lcdReadyCycle) || (cycles < lcdBusyCycle);
                inB = (pa & LCD_RS_BIT) ? lcdReadLatch : ((busy ? 0x80 : 0x00) | (lcdAc & 0x7F));
            }
            return (outB & ddrB) | (inB & ~ddrB);
        }
        case 0x01:
        case 0x0F: {
            uint8_t pins = buttonPins();
            return (outA & ddrA) | (pins & ~ddrA);
        }
        case 0x02: return ddrB;
        case 0x03: return ddrA;
        default:   return vrEmu6522Read(via, reg);
    }
}

static void viaWrite(uint8_t reg, uint8_t v) {
    vrEmu6522Write(via, reg, v);                    // timers, IER, ACR, PCR etc.
    switch (reg) {
        case 0x00: outB = v; break;
        case 0x01:
        case 0x0F: outA = v; evalPortA(); break;
        case 0x02: ddrB = v; break;
        case 0x03: ddrA = v; evalPortA(); break;
    }
}

static uint8_t memRead(uint16_t a, bool isDbg) {
    if ((a & 0xE000) == VIA_BASE) {
        if (isDbg) return 0xFF;                     // debugger peeks must not touch the VIA
        return viaRead(a & 0x0F);
    }
    if (a >= 0x8000) return rom[a - 0x8000];
    if (a < 0x4000) return ram[a];
    return (uint8_t)(rand() & 0xFF);                // $4000-$5FFF: U1 OE (A14) high, floating bus
}

static void memWrite(uint16_t a, uint8_t v) {
    if ((a & 0xE000) == VIA_BASE) { viaWrite(a & 0x0F, v); return; }
    if (a >= 0x8000) return;                        // ROM: writes ignored
    if (a == 0x5000) { printf("DBG %02X\n", v); fflush(stdout); }
    else if (a == 0x5001) { putchar(v); fflush(stdout); }
    else if (a == 0x5002) { exitCode = v; quitRequested = true; }
    if (a < 0x4000) ram[a] = v;
}

// ======================= IRQ =======================
static void updateIrq() {
#if USE_VIA_IRQ
    *vrEmu6502Int(cpu) = *vrEmu6522Int(via);
#endif
}

static void resetSystem() {
    vrEmu6522Reset(via);                            // U4 RES tied to RESET line
    outA = outB = ddrA = ddrB = 0;
    lastE = false;
    lcdReset();                                     // DS1 RST tied to RESET line (RAM untouched)
    vrEmu6502Reset(cpu);                            // U2 RES tied to RESET line
}

static void step() {
    vrEmu6502Tick(cpu);
    vrEmu6522Tick(via);
    updateIrq();
    ++cycles;
}

// ======================= Display =======================
static void dumpLcd() {
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 128; ++x)
            putchar(pixels[y * 128 + x] == LCD_FG ? '#' : '.');
        putchar('\n');
    }
}

static void drawRect(SDL_Renderer *r, int x, int y, int w, int h, bool on,
                     uint8_t onR, uint8_t onG, uint8_t onB) {
    SDL_Rect rc{x, y, w, h};
    if (on) SDL_SetRenderDrawColor(r, onR, onG, onB, 255);
    else    SDL_SetRenderDrawColor(r, onR / 5, onG / 5, onB / 5, 255);
    SDL_RenderFillRect(r, &rc);
}

static void render(SDL_Renderer *r, SDL_Texture *tex) {
    SDL_SetRenderDrawColor(r, 30, 30, 30, 255);
    SDL_RenderClear(r);

    if (backlightOn()) SDL_SetTextureColorMod(tex, 255, 255, 255);
    else               SDL_SetTextureColorMod(tex, 60, 60, 80);
    SDL_UpdateTexture(tex, nullptr, pixels, 128 * 4);
    SDL_Rect dst{0, 0, 512, 256};
    SDL_RenderCopy(r, tex, nullptr, &dst);

    // LEDs PB7..PB0 (left to right), gated by JP1 (LED_EN)
    uint8_t leds = ledEn ? (outB & ddrB) : 0;
    for (int i = 0; i < 8; ++i)
        drawRect(r, 24 + i * 56, 268, 24, 24, (leds >> (7 - i)) & 1, 255, 50, 50);
    // Buttons: middle, up, down, left, right (lit = pressed)
    for (int i = 0; i < 5; ++i)
        drawRect(r, 24 + i * 56, 300, 24, 12, !((buttons >> i) & 1), 80, 160, 255);

    SDL_RenderPresent(r);
}

// ======================= main =======================
int main(int argc, char **argv) {
    const char *path = "rom.bin";
    unsigned loadAddr = 0x8000;
    double hz = 1000000.0;
    bool headless = false;
    uint64_t maxCycles = 100000000ULL;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--addr") && i + 1 < argc)        loadAddr = (unsigned)strtoul(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "--hz") && i + 1 < argc)     hz = atof(argv[++i]);
        else if (!strcmp(argv[i], "--headless"))               headless = true;
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) maxCycles = strtoull(argv[++i], nullptr, 10);
        else path = argv[i];
    }

    FILE *f = fopen(path, "rb");
    if (!f) { printf("can't open %s\n", path); return 1; }
    static uint8_t buf[0x10000];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (loadAddr < 0x8000 || loadAddr - 0x8000 + n > 0x8000) {
        puts("ROM doesn't fit at that address ($8000-$FFFF)");
        return 1;
    }
    memset(rom, 0xEA, sizeof rom);
    memcpy(rom + (loadAddr - 0x8000), buf, n);
    printf("loaded %zu bytes at $%04X, reset vector = $%02X%02X\n",
           n, loadAddr, rom[0x7FFD], rom[0x7FFC]);

    clockHz = hz;
    for (auto &b : ram) b = (uint8_t)(rand() & 0xFF);       // HM62256BLP power-on random state
    for (auto &b : lcdGdram) b = (uint8_t)(rand() & 0xFF);  // ST7920 GDRAM power-on random state

    via = vrEmu6522New(VIA_65C22);                      // U4: W65C22SxP
    cpu = vrEmu6502New(CPU_W65C02, memRead, memWrite);  // U2: W65C02SxP
    resetSystem();

    const int cyclesPerFrame = (int)(hz / 60.0);

    if (headless) {
        while (!quitRequested && cycles < maxCycles) step();
        printf("stopped after %llu cycles, exit code %d (LCD early=%u, too_fast=%u)\n",
               (unsigned long long)cycles, exitCode, lcdEarly, lcdTooFast);
        dumpLcd();
        vrEmu6502Destroy(cpu);
        vrEmu6522Destroy(via);
        return exitCode;
    }

    if (SDL_Init(SDL_INIT_VIDEO) != 0) { printf("SDL error: %s\n", SDL_GetError()); return 1; }
    SDL_Window *win = SDL_CreateWindow("6502 + W65C22 + ST7920",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 512, 320, 0);
    SDL_Renderer *r = SDL_CreateRenderer(win, -1, 0);
    SDL_Texture *tex = SDL_CreateTexture(r, SDL_PIXELFORMAT_ARGB8888,
                                         SDL_TEXTUREACCESS_STREAMING, 128, 64);

    bool run = true, fast = false;
    const Uint64 freq = SDL_GetPerformanceFrequency();
    while (run && !quitRequested) {
        Uint64 start = SDL_GetPerformanceCounter();

        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) run = false;
            if (e.type == SDL_KEYDOWN && !e.key.repeat) {
                if (e.key.keysym.scancode == SDL_SCANCODE_R) resetSystem();
                if (e.key.keysym.scancode == SDL_SCANCODE_F) fast = !fast;
                if (e.key.keysym.scancode == SDL_SCANCODE_L) ledEn = !ledEn;
            }
        }

        const uint8_t *k = SDL_GetKeyboardState(nullptr);
        uint8_t newButtons = 0x1F;
        if (k[SDL_SCANCODE_SPACE] || k[SDL_SCANCODE_RETURN]) newButtons &= ~0x01;   // PA0 middle
        if (k[SDL_SCANCODE_UP])    newButtons &= ~0x02;                             // PA1 up
        if (k[SDL_SCANCODE_DOWN])  newButtons &= ~0x04;                             // PA2 down
        if (k[SDL_SCANCODE_LEFT])  newButtons &= ~0x08;                             // PA3 left
        if (k[SDL_SCANCODE_RIGHT]) newButtons &= ~0x10;                             // PA4 right
        uint8_t diff = buttons ^ newButtons;
        if (diff) {
            uint64_t bounce = usToCycles(3000);                                     // 3 ms switch bounce
            for (int i = 0; i < 5; ++i)
                if (diff & (1 << i)) bounceUntil[i] = cycles + bounce;
            buttons = newButtons;
        }

        for (int i = 0; i < (fast ? cyclesPerFrame * 20 : cyclesPerFrame) && !quitRequested; ++i)
            step();

        render(r, tex);

        double elapsed = (double)(SDL_GetPerformanceCounter() - start) / freq;
        if (!fast && elapsed < 1.0 / 60.0)
            SDL_Delay((Uint32)((1.0 / 60.0 - elapsed) * 1000.0));
    }

    printf("stopped after %llu cycles, exit code %d\n", (unsigned long long)cycles, exitCode);
    SDL_Quit();
    return exitCode;
}
