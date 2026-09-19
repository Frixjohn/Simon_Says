import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLOCK_PERIOD_NS = 40

ST_BOOT = 0
ST_IDLE = 1
ST_ADD_STEP = 2
ST_SHOW_ON = 3
ST_SHOW_OFF = 4
ST_WAIT_INPUT = 5
ST_FEEDBACK = 6
ST_ROUND_OK = 7
ST_MISS_FLASH = 8
ST_GAME_OVER = 9

BUTTON_WORD_BY_ID = {
    0: 1 << 5,   # LEFT
    1: 1 << 4,   # RIGHT
    2: 1 << 7,   # UP
    3: 1 << 6,   # DOWN
    4: 1 << 3,   # A
    5: 1 << 11,  # B
    6: 1 << 2,   # X
    7: 1 << 10,  # Y
    8: 1 << 1,   # L
    9: 1 << 0,   # R
    10: 1 << 9,  # SELECT
    11: 1 << 8,  # START
}

# hvsync_generator.v:
# horizontal total = 640 + 16 + 96 + 48 = 800 clocks
# vertical total   = 480 + 10 + 2 + 33 = 525 lines
CLKS_PER_LINE = 800
CLKS_PER_FRAME = 800 * 525


def get_state(dut):
    return int(dut.user_project.state.value)


def set_pmod(dut, data=0, pmod_clk=0, pmod_latch=0):
    # ui[6] = DATA, ui[5] = CLOCK, ui[4] = LATCH.
    dut.ui_in.value = (data << 6) | (pmod_clk << 5) | (pmod_latch << 4)


async def pmod_pulse_clock(dut, bit):
    # Give the 2-flop synchronizers time to see stable inputs.
    set_pmod(dut, data=bit, pmod_clk=0)
    await ClockCycles(dut.clk, 2)

    set_pmod(dut, data=bit, pmod_clk=1)
    await ClockCycles(dut.clk, 3)

    set_pmod(dut, data=bit, pmod_clk=0)
    await ClockCycles(dut.clk, 3)


async def send_gamepad_word(dut, word):
    # gamepad_pmod_driver shifts MSB first.
    for bit_index in range(11, -1, -1):
        await pmod_pulse_clock(dut, (word >> bit_index) & 1)

    # Rising latch captures the finished shift register.
    set_pmod(dut, data=0, pmod_clk=0, pmod_latch=0)
    await ClockCycles(dut.clk, 2)

    set_pmod(dut, data=0, pmod_clk=0, pmod_latch=1)
    await ClockCycles(dut.clk, 3)

    set_pmod(dut, data=0, pmod_clk=0, pmod_latch=0)
    await ClockCycles(dut.clk, 3)


async def press_button_id(dut, button_id):
    await send_gamepad_word(dut, BUTTON_WORD_BY_ID[button_id])
    await ClockCycles(dut.clk, 4)

    # Release all buttons so the next press creates a new edge.
    await send_gamepad_word(dut, 0)
    await ClockCycles(dut.clk, 4)


async def wait_for_state(dut, wanted, timeout_cycles, chunk=1000):
    elapsed = 0

    while elapsed < timeout_cycles:
        if get_state(dut) == wanted:
            return

        step = min(chunk, timeout_cycles - elapsed)
        await ClockCycles(dut.clk, step)
        elapsed += step

    raise AssertionError(
        f"Timed out waiting for FSM state {wanted}; "
        f"actual state={get_state(dut)} after {elapsed} clocks"
    )


async def wait_for_frame_start(dut, timeout_cycles):
    elapsed = 0

    while elapsed < timeout_cycles:
        if (
            int(dut.user_project.pix_x.value) == 0
            and int(dut.user_project.pix_y.value) == 0
        ):
            return

        step = min(1000, timeout_cycles - elapsed)
        await ClockCycles(dut.clk, step)
        elapsed += step

    raise AssertionError("Timed out waiting for VGA frame start")


async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


@cocotb.test()
async def test_vga_reset_and_sync(dut):
    """Check reset, output-enable configuration, and VGA sync timing."""
    clock = Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    assert int(dut.uio_oe.value) == 0x01, (
        f"Expected only uio[0] as output, got 0x{int(dut.uio_oe.value):02X}"
    )

    await wait_for_state(dut, ST_IDLE, CLKS_PER_FRAME + 10_000)
    await wait_for_frame_start(dut, CLKS_PER_FRAME + 10_000)

    # Start of active line: hsync/vsync are both high.
    value = int(dut.uo_out.value)
    assert ((value >> 7) & 1) == 1
    assert ((value >> 3) & 1) == 1

    # VGA horizontal sync is low for 96 clocks starting at x=656.
    await ClockCycles(dut.clk, 656)
    value = int(dut.uo_out.value)
    assert ((value >> 7) & 1) == 0, "hsync did not start at x=656"

    await ClockCycles(dut.clk, 96)
    value = int(dut.uo_out.value)
    assert ((value >> 7) & 1) == 1, "hsync did not end after 96 clocks"

    # Vertical sync is low for two complete lines starting at y=490.
    await ClockCycles(dut.clk, CLKS_PER_LINE * (490 - 1))
    value = int(dut.uo_out.value)
    assert ((value >> 3) & 1) == 0, "vsync did not start at y=490"

    await ClockCycles(dut.clk, CLKS_PER_LINE * 2)
    value = int(dut.uo_out.value)
    assert ((value >> 3) & 1) == 1, "vsync did not end after two lines"


@cocotb.test()
async def test_simon_game_fsm(dut):
    """Exercise Start -> reveal -> correct input -> next round -> wrong input."""
    clock = Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    assert get_state(dut) == ST_IDLE, (
        f"With BOOT_FRAMES=0, expected IDLE after reset; got {get_state(dut)}"
    )

    await press_button_id(dut, 11)  # START
    await ClockCycles(dut.clk, 8)

    # Round 1 has one shown glyph.
    await wait_for_state(dut, ST_SHOW_ON, CLKS_PER_FRAME + 10_000)
    first_glyph = int(dut.user_project.lit_id.value)
    assert 0 <= first_glyph <= 11, f"Invalid first glyph ID: {first_glyph}"

    # One SHOW_ON frame + one SHOW_OFF frame.
    await wait_for_state(dut, ST_WAIT_INPUT, 3 * CLKS_PER_FRAME + 20_000)

    await press_button_id(dut, first_glyph)
    await ClockCycles(dut.clk, 8)

    assert get_state(dut) == ST_ROUND_OK, (
        f"Correct first input did not produce ROUND_OK; state={get_state(dut)}"
    )

    # Round 2 has two shown glyphs. With zero show/gap settings it still
    # consumes one frame per SHOW_ON/SHOW_OFF state.
    await wait_for_state(dut, ST_SHOW_ON, 5 * CLKS_PER_FRAME + 20_000)
    second_glyph = int(dut.user_project.lit_id.value)
    assert 0 <= second_glyph <= 11, f"Invalid second glyph ID: {second_glyph}"

    await wait_for_state(dut, ST_WAIT_INPUT, 5 * CLKS_PER_FRAME + 20_000)

    wrong = (second_glyph + 1) % 12
    await press_button_id(dut, wrong)
    await ClockCycles(dut.clk, 8)

    assert get_state(dut) == ST_MISS_FLASH, (
        f"Wrong input did not produce MISS_FLASH; state={get_state(dut)}"
    )

    await wait_for_state(dut, ST_GAME_OVER, CLKS_PER_FRAME + 50_000)

    assert int(dut.user_project.high_score.value) == 1, (
        f"Expected high_score=1 after one completed round, "
        f"got {int(dut.user_project.high_score.value)}"
    )
