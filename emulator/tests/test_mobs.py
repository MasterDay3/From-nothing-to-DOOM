"""MINI-DOOM: timer-driven enemy actions and collision/visibility."""
from util import board, press, run_tests


def cell(x, y):
    return 0x0600 + y * 32 + x


def fixture(player=(2, 2), mobs=(), walls=()):
    b = board('doom.s')
    m, l = b.mem, b.labels
    for a in range(0x0600, 0x0A00):
        m[a] = 0
    m[l['posX_hi']], m[l['posY_hi']] = player
    m[l['hp']] = 6
    for x, y in mobs:
        m[cell(x, y)] = 7
    for x, y, tile in walls:
        m[cell(x, y)] = tile
    return b


def call(b, name):
    cpu = b.cpu
    cpu.stPushWord(0x3FFF)
    cpu.pc = b.labels[name]
    start = cpu.processorCycles
    while cpu.pc != 0x4000 and cpu.processorCycles - start < 3_000_000:
        b.run(1)
    assert cpu.pc == 0x4000, (name, hex(cpu.pc))
    return cpu.processorCycles - start


def test_direct_and_diagonal_line_of_sight_shoot():
    for player, demon in [((2, 2), (5, 2)), ((2, 2), (5, 4))]:
        b = fixture(player, [demon])
        call(b, 'update_enemies')
        assert b.mem[b.labels['hp']] == 5
        assert b.mem[cell(*demon)] == 7


def test_wall_and_closed_door_block_shots():
    for obstacle in (1, 5):
        b = fixture((2, 2), [(5, 2)], [(4, 2, obstacle)])
        call(b, 'update_enemies')
        assert b.mem[b.labels['hp']] == 6
        assert b.mem[cell(5, 2)] == 7  # move toward player is blocked too


def test_diagonal_wall_corner_blocks_shot():
    b = fixture((2, 2), [(4, 4)], [(3, 4, 1)])
    call(b, 'update_enemies')
    assert b.mem[b.labels['hp']] == 6


def test_movement_collisions_and_one_action():
    # Beyond firing range: the first mob moves right into a later scan cell;
    # it must not be encountered a second time. The other mob blocks the way.
    b = fixture((15, 5), [(2, 5), (4, 5)], [(5, 5, 1)])
    call(b, 'update_enemies')
    assert b.mem[cell(2, 5)] == 0 and b.mem[cell(3, 5)] == 7
    assert b.mem[cell(4, 5)] == 7 and b.mem[cell(5, 5)] == 1
    assert b.mem[b.labels['hp']] == 6
    # Move helper rejects both a player cell and another occupied cell.
    b = fixture((3, 5), [(2, 5), (2, 6)])
    l, m = b.labels, b.mem
    m[l['mob_x']], m[l['mob_y']] = 2, 5
    for x, y in ((3, 5), (2, 6)):
        m[l['tx']], m[l['ty']] = x, y
        call(b, 'mob_try_move')
        assert m[cell(2, 5)] == 7 and m[cell(x, y)] in (0, 7)


def test_killed_demon_does_not_act():
    b = board('doom.s')
    b.run(200_000)
    press(b, 1, gap=1_500_000)
    press(b, 1, gap=3_000_000)  # player shoots the demon in the starting view
    assert b.mem[b.labels['kills']] == 1 and b.mem[cell(5, 2)] == 0
    for a in range(0x0600, 0x0A00):
        if b.mem[a] == 7:
            b.mem[a] = 0
    hp = b.mem[b.labels['hp']]
    call(b, 'update_enemies')
    assert b.mem[b.labels['hp']] == hp
    assert b.mem[b.labels['mob_changed']] == 0


def test_timer_no_input_first_and_second_interval():
    b = board('doom.s')
    l, m = b.labels, b.mem
    b.run(200_000)
    press(b, 1, gap=1_500_000)
    # Keep a single demon in clear sight, with no buttons pressed.
    for a in range(0x0600, 0x0A00):
        m[a] = 0
    m[l['posX_hi']], m[l['posY_hi']], m[l['hp']] = 2, 2, 6
    m[cell(5, 2)] = 7
    # The level timer has already counted the first rendered frame.
    remaining = m[l['mob_timer_lo']] + 256 * m[l['mob_timer_hi']]
    assert 0 < remaining < 500 and m[l['mob_pending']] == 0
    b.run((remaining - 3) * 20_000)
    assert m[l['hp']] == 6 and m[cell(5, 2)] == 7
    b.run(1_000_000)
    assert m[l['hp']] == 5
    b.run(8_000_000)
    assert m[l['hp']] == 5
    b.run(1_500_000)
    assert m[l['hp']] == 4


def test_level_timer_starts_at_500_ticks():
    b = board('doom.s')
    l, m = b.labels, b.mem
    b.run(200_000)
    b.set_button(1, True)
    b.run(30_000)
    b.set_button(1, False)
    while not m[l['mob_active']]:
        b.run(1)
    assert m[l['mob_timer_lo']] + 256 * m[l['mob_timer_hi']] == 500
    assert m[l['mob_pending']] == 0


def test_timer_during_render_and_wait_is_retained():
    b = board('doom.s')
    l, m = b.labels, b.mem
    b.run(200_000)
    press(b, 1, gap=1_500_000)
    for a in range(0x0600, 0x0A00):
        m[a] = 0
    m[l['posX_hi']], m[l['posY_hi']], m[l['hp']] = 2, 2, 6
    m[cell(5, 2)] = 7
    # Force the deadline while update_view is executing; IRQ must only queue it.
    m[l['mob_timer_lo']], m[l['mob_timer_hi']] = 1, 0
    m[l['mob_pending']] = 1
    call(b, 'update_view')
    assert m[l['mob_pending']] == 2 and m[l['hp']] == 6
    call(b, 'service_mobs')
    assert m[l['mob_pending']] == 1 and m[l['hp']] == 5
    call(b, 'service_mobs')
    assert m[l['mob_pending']] == 0 and m[l['hp']] == 4


def test_service_redraws_only_once_when_changed():
    for mobs, expected in (([], 0), ([(5, 2), (2, 5)], 1)):
        b = fixture((2, 2), mobs)
        l, m, cpu = b.labels, b.mem, b.cpu
        m[l['mob_pending']] = 1
        cpu.stPushWord(0x3FFF)
        cpu.pc = l['service_mobs']
        frames = 0
        start = cpu.processorCycles
        while cpu.pc != 0x4000 and cpu.processorCycles - start < 3_000_000:
            frames += cpu.pc == l['update_view']
            b.run(1)
        assert cpu.pc == 0x4000 and frames == expected


if __name__ == '__main__':
    run_tests(globals())
