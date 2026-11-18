"""Save reproducible 64-ray frames, ROM map and emulator cycle counts."""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from emu import Board  # noqa: E402
import pygame  # noqa: E402


def build(out, tmp):
    obj, lbl = tmp / 'doom.o', tmp / 'doom.lbl'
    subprocess.run([os.environ.get('CA65', 'ca65'), '-g', '--cpu', 'W65C02',
                    'doom.s', '-o', str(obj)], cwd=ROOT, check=True)
    subprocess.run([os.environ.get('LD65', 'ld65'), '-C', 'board.cfg', str(obj),
                    '-o', str(out / 'doom.bin'), '-m', str(out / 'doom.map'),
                    '-Ln', str(lbl)], cwd=ROOT, check=True)
    return {p[2].lstrip('.'): int(p[1], 16) for line in lbl.read_text().splitlines()
            if len(p := line.split()) == 3}


def frame(board, labels, release_at=None):
    start = stack = None
    event = {}
    limit = board.cpu.processorCycles + 4_000_000
    while board.cpu.processorCycles < limit:
        c, pc = board.cpu.processorCycles, board.cpu.pc
        if release_at is not None and c >= release_at:
            board.set_button(16, False)
            release_at = None
        if start is None and pc == labels['update_view']:
            start, stack = c, board.cpu.sp
        if start is not None:
            for name in ('cast_all', 'mark_demons', 'render_view', 'draw_weapon', 'lcd_flush'):
                if name not in event and pc == labels[name]:
                    event[name] = c
            if board.cpu.sp == stack + 2:
                return {'render_view': event['draw_weapon'] - event['render_view'],
                        'lcd_flush': c - event['lcd_flush'], 'update_view': c - start}
        board.run(1)
    raise RuntimeError('Frame timeout')


def image(board, path):
    surface = pygame.Surface((128, 64))
    for y in range(64):
        for x in range(128):
            c = 235 if board.lcd.pixel(x, y) else 15
            surface.set_at((x, y), (c, c, c))
    pygame.image.save(pygame.transform.scale(surface, (768, 384)), str(path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('label', choices=('before', 'after'))
    args = parser.parse_args()
    out = ROOT / 'texture-comparison' / args.label
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        labels = build(out, Path(tmp))
    random.seed(2026)
    board = Board(str(out / 'doom.bin'))
    board.run(200_000)
    board.set_button(1, True)
    board.run(30_000)
    board.set_button(1, False)
    results = {'start': frame(board, labels)}
    image(board, out / 'start.png')
    while board.cpu.pc != labels['main_loop']:
        board.run(1)
    board.set_button(16, True)
    results['turn'] = frame(board, labels, board.cpu.processorCycles + 30_000)
    assert board.mem[labels['p_angle']] == 8
    image(board, out / 'turn.png')
    # Inspect walls at fixed positions; direct update_view calls are diagnostic,
    # not extra player actions. Angles use 256 units per circle.
    for scene, x, y, angle in [('close', 0x0280, 0x03C0, 64),
                               ('far', 0x0C80, 0x0280, 0)]:
        for name, value in [('posX_lo', x & 255), ('posX_hi', x >> 8),
                            ('posY_lo', y & 255), ('posY_hi', y >> 8),
                            ('p_angle', angle)]:
            board.mem[labels[name]] = value
        board.cpu.stPushWord(labels['main_loop'] - 1)
        board.cpu.pc = labels['update_view']
        results[scene] = frame(board, labels)
        image(board, out / (scene + '.png'))
    assert not board.lcd.early and not board.lcd.too_fast
    (out / 'cycles.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
