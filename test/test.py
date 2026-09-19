import glob
import itertools
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from PIL import Image, ImageChops


CLOCK_PERIOD_NS = 40  # 25 MHz simulation clock
H_DISPLAY = 640
H_FRONT = 16
H_SYNC = 96
H_BACK = 48
V_DISPLAY = 480
V_FRONT = 10
V_SYNC = 2
V_BACK = 33

H_SYNC_START = H_DISPLAY + H_FRONT
H_SYNC_END = H_SYNC_START + H_SYNC
H_TOTAL = H_SYNC_END + H_BACK

V_SYNC_START = V_DISPLAY + V_FRONT
V_SYNC_END = V_SYNC_START + V_SYNC
V_TOTAL = V_SYNC_END + V_BACK

CAPTURE_FRAMES = 3


def build_palette():
    palette = [bytes(3)] * 256

    for r1, r0, g1, g0, b1, b0 in itertools.product(range(2), repeat=6):
        red = 170 * r1 + 85 * r0
        green = 170 * g1 + 85 * g0
        blue = 170 * b1 + 85 * b0
        color_index = (
            (b0 << 6)
            | (g0 << 5)
            | (r0 << 4)
            | (b1 << 2)
            | (g1 << 1)
            | r1
        )
        for sync_bits in (0x00, 0x08, 0x80, 0x88):
            palette[color_index | sync_bits] = bytes((red, green, blue))

    return palette


async def check_line(dut, expected_vsync):
    for i in range(H_TOTAL):
        value = int(dut.uo_out.value)
        hsync = (value >> 7) & 1
        vsync = (value >> 3) & 1

        expected_hsync = 0 if H_SYNC_START <= i < H_SYNC_END else 1
        assert hsync == expected_hsync, (
            f"Unexpected hsync at pixel {i}: got {hsync}, "
            f"expected {expected_hsync}"
        )
        assert vsync == expected_vsync, (
            f"Unexpected vsync at pixel {i}: got {vsync}, "
            f"expected {expected_vsync}"
        )
        await ClockCycles(dut.clk, 1)


async def capture_line(dut, framebuffer, offset, palette):
    for i in range(H_TOTAL):
        value = int(dut.uo_out.value)
        hsync = (value >> 7) & 1
        vsync = (value >> 3) & 1

        expected_hsync = 0 if H_SYNC_START <= i < H_SYNC_END else 1
        assert hsync == expected_hsync, (
            f"Unexpected hsync at pixel {i}: got {hsync}, "
            f"expected {expected_hsync}"
        )
        assert vsync == 1, f"Unexpected vsync during active line: {vsync}"

        if i < H_DISPLAY:
            rgb = palette[value]
            start = offset + 3 * i
            framebuffer[start:start + 3] = rgb

        await ClockCycles(dut.clk, 1)


async def capture_frame(dut, frame_num, palette):
    framebuffer = bytearray(V_DISPLAY * H_DISPLAY * 3)

    for row in range(V_DISPLAY):
        await capture_line(dut, framebuffer, 3 * row * H_DISPLAY, palette)

    # After the final display line, we are at the vertical front porch.
    for row in range(V_FRONT):
        await check_line(dut, 1)

    for row in range(V_SYNC):
        await check_line(dut, 0)

    for row in range(V_BACK):
        await check_line(dut, 1)

    frame = Image.frombytes("RGB", (H_DISPLAY, V_DISPLAY), bytes(framebuffer))
    path = f"output/frame{frame_num}.png"
    frame.save(path)
    return frame


def compare_references(dut):
    for img_path in sorted(glob.glob("output/frame*.png")):
        basename = os.path.basename(img_path)
        ref_path = os.path.join("reference", basename)

        if not os.path.exists(ref_path):
            dut._log.warning(
                "Reference image %s is missing; sync/reset test passed, "
                "but visual reference comparison was skipped.",
                ref_path,
            )
            continue

        frame = Image.open(img_path).convert("RGB")
        ref = Image.open(ref_path).convert("RGB")

        diff = ImageChops.difference(frame, ref)
        if diff.getbbox() is not None:
            diff.save(os.path.join("output", f"diff_{basename}"))
            raise AssertionError(
                f"{basename} differs from reference image; "
                f"see output/diff_{basename}"
            )


@cocotb.test()
async def test_project(dut):
    palette = build_palette()
    clock = Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0

    # Hold reset long enough for all synchronizer/state registers.
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)

    # Basic reset/output sanity.
    assert int(dut.uio_oe.value) == 0x01, (
        "uio_oe must expose only uio[0] as the audio output"
    )

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    os.makedirs("output", exist_ok=True)

    for frame_num in range(CAPTURE_FRAMES):
        dut._log.info("Capturing frame %d", frame_num)
        await capture_frame(dut, frame_num, palette)

    compare_references(dut)
