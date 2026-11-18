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
static uint8_t ram[0x8000];
static uint8_t rom[0x8000];
static VrEmu6522 *via = nullptr;
static VrEmu6502 *cpu = nullptr;

static uint8_t outA = 0, outB = 0, ddrA = 0, ddrB = 0;
static uint8_t buttons = 0x1F;          // PA0-PA4, 1 = released
static bool lastE = false;

static uint32_t pixels[128 * 64];
static bool quitRequested = false;
static int exitCode = 0;
static uint64_t cycles = 0;

// ======================= LCD =======================
static void clearDisplay() { for (auto &p : pixels) p = 0xFFFFFFFF; }

static void drawByte(uint8_t x, uint8_t y, uint8_t d) {
    if (y >= 64) return;
    for (int i = 0; i < 8; ++i) {
        int px = x + i;
        if (px >= 128) break;
        pixels[y * 128 + px] = (d & (1 << i)) ? 0xFF000000 : 0xFFFFFFFF;
    }
}

static St7920Emulator lcd(clearDisplay, drawByte);

static void lcdWrite(bool rs, uint8_t d) {
    if (!rs && d >= 0x04 && d <= 0x07) return;     // entry mode: breaks the emulator
    lcd.parseSerialData(rs ? 0xFA : 0xF8);
    lcd.parseSerialData(d & 0xF0);
    lcd.parseSerialData((d << 4) & 0xF0);
}

// Re-evaluate the LCD control lines after any change to ORA or DDRA.
static void evalPortA() {
    uint8_t pins = outA & ddrA;                     // undriven pins read as low
    bool e = pins & LCD_E_BIT;
    if (lastE && !e && !(pins & LCD_RW_BIT))        // falling edge of E with R/W=0 latches write
        lcdWrite(pins & LCD_RS_BIT, outB & ddrB);
    lastE = e;
}

static bool backlightOn() {
    return true;                                    // BLA/BLK hardwired to VCC/GND
}

// ======================= VIA / bus =======================
static uint8_t viaRead(uint8_t reg) {
    switch (reg) {
        case 0x00: return outB & ddrB;              // inputs read low (LED path)
        case 0x01:
        case 0x0F: {
            uint8_t pins = buttons | 0xE0;          // PA5-7 float high
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
    return ram[a];
}

static void memWrite(uint16_t a, uint8_t v) {
    if ((a & 0xE000) == VIA_BASE) { viaWrite(a & 0x0F, v); return; }
    if (a >= 0x8000) return;                        // ROM: writes ignored
    if (a == 0x5000) { printf("DBG %02X\n", v); fflush(stdout); }
    else if (a == 0x5001) { putchar(v); fflush(stdout); }
    else if (a == 0x5002) { exitCode = v; quitRequested = true; }
    ram[a] = v;                                     // write-through: it's still RAM
}

// ======================= IRQ =======================
static void updateIrq() {
#if USE_VIA_IRQ
    uint8_t ifr = vrEmu6522Read(via, 0x0D);
    uint8_t ier = vrEmu6522Read(via, 0x0E);
    bool pending = (ifr & ier & 0x7F) != 0;
    *vrEmu6502Int(cpu) = pending ? IntRequested : IntCleared;
#endif
}

static void resetSystem() {
    vrEmu6522Write(via, 0x0B, 0x00);                // ACR
    vrEmu6522Write(via, 0x0C, 0x00);                // PCR
    vrEmu6522Write(via, 0x0E, 0x7F);                // IER: disable all
    vrEmu6522Write(via, 0x0D, 0x7F);                // IFR: clear all
    outA = outB = ddrA = ddrB = 0;
    lastE = false;
    vrEmu6502Reset(cpu);
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
            putchar(pixels[y * 128 + x] == 0xFF000000 ? '#' : '.');
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

    // LCD: white pixels become backlight colour, black stay black
    if (backlightOn()) SDL_SetTextureColorMod(tex, 150, 215, 110);
    else               SDL_SetTextureColorMod(tex, 55, 65, 50);
    SDL_UpdateTexture(tex, nullptr, pixels, 128 * 4);
    SDL_Rect dst{0, 0, 512, 256};
    SDL_RenderCopy(r, tex, nullptr, &dst);

    // LEDs PB0..PB7 (left to right)
    for (int i = 0; i < 8; ++i)
        drawRect(r, 24 + i * 56, 268, 24, 24, ((outB & ddrB) >> i) & 1, 255, 50, 50);
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

    via = vrEmu6522New(VIA_6522);
    cpu = vrEmu6502New(CPU_W65C02, memRead, memWrite);
    vrEmu6502Reset(cpu);
    clearDisplay();

    const int cyclesPerFrame = (int)(hz / 60.0);

    if (headless) {
        while (!quitRequested && cycles < maxCycles) step();
        printf("stopped after %llu cycles, exit code %d\n", (unsigned long long)cycles, exitCode);
        dumpLcd();
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
            }
        }

        const uint8_t *k = SDL_GetKeyboardState(nullptr);
        buttons = 0x1F;
        if (k[SDL_SCANCODE_SPACE] || k[SDL_SCANCODE_RETURN]) buttons &= ~0x01;   // PA0 middle
        if (k[SDL_SCANCODE_UP])    buttons &= ~0x02;                             // PA1 up
        if (k[SDL_SCANCODE_DOWN])  buttons &= ~0x04;                             // PA2 down
        if (k[SDL_SCANCODE_LEFT])  buttons &= ~0x08;                             // PA3 left
        if (k[SDL_SCANCODE_RIGHT]) buttons &= ~0x10;                             // PA4 right

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
