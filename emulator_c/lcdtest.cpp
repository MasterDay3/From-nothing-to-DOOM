#include <SDL.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "St7920Emulator.hpp"

static uint32_t pixels[128 * 64];
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

static void send(bool rs, uint8_t d) {
    lcd.parseSerialData(rs ? 0xFA : 0xF8);
    lcd.parseSerialData(d & 0xF0);
    lcd.parseSerialData((d << 4) & 0xF0);
}
static void cmd(uint8_t d) { send(false, d); }
static void dat(uint8_t d) { send(true, d); }

static const uint8_t rowAddr[4] = {0x80, 0x90, 0x88, 0x98};

static void testRows() {
    cmd(0x30); cmd(0x0C); cmd(0x01);
    for (int row = 0; row < 4; ++row) {
        char buf[17];
        snprintf(buf, sizeof buf, "R%d 0123456789ABC", row + 1);
        cmd(rowAddr[row]);
        for (int i = 0; i < 16; ++i) dat((uint8_t)buf[i]);
    }
}

static void testChars(int base, int count) {
    cmd(0x30); cmd(0x0C); cmd(0x01);
    for (int row = 0; row < 4; ++row) {
        cmd(rowAddr[row]);
        for (int i = 0; i < 16; ++i) {
            int n = row * 16 + i;
            dat(n < count ? (uint8_t)(base + n) : 0x20);
        }
    }
}

static void testGraphics() {
    static bool px[64][128];
    for (int x = 0; x < 128; ++x) px[0][x] = px[63][x] = true;      // border
    for (int y = 0; y < 64; ++y)  px[y][0] = px[y][127] = true;
    for (int x = 0; x < 128; ++x) px[x / 2][x] = true;              // diagonal
    for (int y = 0; y < 8; ++y)                                      // checkerboard
        for (int x = 0; x < 8; ++x)
            if ((x ^ y) & 1) px[40 + y][8 + x] = true;

    cmd(0x30); cmd(0x01);
    cmd(0x34);                    // extended instruction set
    cmd(0x36);                    // graphics on
    for (int y = 0; y < 32; ++y)
        for (int half = 0; half < 2; ++half) {
            cmd(0x80 | y);
            cmd(0x80 | (half * 8));
            int row = y + half * 32;
            for (int b = 0; b < 16; ++b) {
                uint8_t v = 0;
                for (int bit = 0; bit < 8; ++bit)
                    if (px[row][b * 8 + bit]) v |= 0x80 >> bit;     // MSB = leftmost
                dat(v);
            }
        }
}

int main(int argc, char **argv) {
    int mode = argc > 1 ? atoi(argv[1]) : 1;
    clearDisplay();
    switch (mode) {
        case 1: testRows(); break;
        case 2: testChars(0x20, 64); break;
        case 3: testChars(0x60, 31); break;
        case 4: testGraphics(); break;
    }
    SDL_Init(SDL_INIT_VIDEO);
    SDL_Window *w = SDL_CreateWindow("ST7920 test", SDL_WINDOWPOS_CENTERED,
                                     SDL_WINDOWPOS_CENTERED, 512, 256, 0);
    SDL_Renderer *r = SDL_CreateRenderer(w, -1, 0);
    SDL_Texture *t = SDL_CreateTexture(r, SDL_PIXELFORMAT_ARGB8888,                                       SDL_TEXTUREACCESS_STREAMING, 128, 64);
    
    for (bool run = true; run;) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) run = false;
        }
        SDL_UpdateTexture(t, nullptr, pixels, 128 * 4);
        SDL_RenderClear(r);
        SDL_RenderCopy(r, t, nullptr, nullptr);
        SDL_RenderPresent(r);
        SDL_Delay(20);
    }
    return 0;
}
