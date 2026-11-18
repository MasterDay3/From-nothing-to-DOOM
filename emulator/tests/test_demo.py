"""Presentation ROM: the actual route, including a timed autonomous move."""
from util import board, run_tests, screen


def cell(x, y):
    return 0x0600 + y * 32 + x


def test_presentation_route():
    b = board('doom.s', defines=('DEMO_LEVEL=1',))
    m, l = b.mem, b.labels

    def tap(mask, gap=900_000):
        b.buttons = 0xFF ^ mask
        b.run(30_000)
        b.buttons = 0xFF
        b.run(gap)

    b.run(200_000)
    assert screen(b)[0].startswith('MINI-DOOM 65C02')
    tap(1, 1_500_000)
    assert (m[l['posX_hi']], m[l['posY_hi']], m[l['hit_id']]) == (2, 2, 7)
    assert (m[l['hit_x']], m[l['hit_y']]) == (4, 2)
    assert m[cell(4, 2)] == m[cell(6, 5)] == 7
    tap(1, 1_800_000)
    assert m[l['kills']] == 1 and m[cell(4, 2)] == 0
    tap(16)
    assert m[l['p_angle']] == 8 and any(m[0x0B80 + i] for i in range(64))
    old_frame = bytes(b.lcd.gdram)
    old_position = tuple(m[l[k]] for k in ('posX_lo', 'posX_hi', 'posY_lo', 'posY_hi'))
    assert m[cell(6, 5)] == 7 and m[cell(5, 5)] == 0
    b.run(11_000_000)  # no buttons: first 500-tick AI update
    assert m[cell(6, 5)] == 0 and m[cell(5, 5)] == 7
    assert m[l['hp']] == 6  # distance 7: the mob moves instead of shooting
    assert old_position == tuple(m[l[k]] for k in ('posX_lo', 'posX_hi', 'posY_lo', 'posY_hi'))
    assert any(m[0x0B80 + i] for i in range(64)) and bytes(b.lcd.gdram) != old_frame

    tap(8)  # face east again
    assert m[l['p_angle']] == 0 and m[l['hit_id']] == 5
    for _ in range(8):
        if m[l['hit_id']] == 5 and m[l['hit_dist']] < 32:
            break
        tap(2, 1_200_000)
    else:
        raise AssertionError('door not reached')
    tap(1)
    assert m[cell(5, 2)] == 0 and m[l['hit_id']] == 6
    # A press during an AI frame may not be sampled; each tap is an actual input,
    # not an assumed movement of exactly one step.
    for _ in range(12):
        if m[l['hit_id']] == 6 and m[l['hit_dist']] < 32:
            break
        tap(2, 1_200_000)
    else:
        raise AssertionError('exit not reached')
    b.buttons = 0xFE
    b.run(200_000)
    assert m[l['won']] == 1 and screen(b)[0].startswith('EXIT FOUND!')
    assert not b.lcd.graphics and not b.lcd.early and not b.lcd.too_fast
    b.buttons = 0xFF
    b.run(200_000)
    assert m[l['won']] == 1 and screen(b)[0].startswith('EXIT FOUND!')


if __name__ == '__main__':
    run_tests(globals())
