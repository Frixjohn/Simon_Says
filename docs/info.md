# How it works

**Simon Says** is a VGA-based memory game. After reset, the design shows a short
intro and then waits for the player to press the **START** button on a Gamepad
Pmod. Each round adds one more randomly selected button to the sequence.

The design displays the sequence on the Tiny VGA output. The player must repeat
the buttons in the same order. Correct inputs flash green and advance through
the current sequence; an incorrect input flashes red and ends the run. A simple
PWM sound output is provided on `uio[0]` for button notes and the miss tone.

The game uses twelve possible Gamepad inputs: LEFT, RIGHT, UP, DOWN, A, B, X, Y,
L, R, SELECT, and START.

## How to test

Connect the Tiny Tapeout VGA output to a compatible display and connect a
Gamepad Pmod to `ui[4:6]`:

- `ui[4]`: Gamepad LATCH
- `ui[5]`: Gamepad CLOCK
- `ui[6]`: Gamepad DATA

Press **START** to begin. Watch the highlighted pads, then repeat the sequence
on the controller. A correct sequence advances to the next round; a wrong
button ends the run. The optional audio output is available on `uio[0]`.

The repository also contains a cocotb RTL testbench. It checks reset and VGA
sync timing and exercises the actual Gamepad Pmod serial interface through the
Simon Says FSM.

## External hardware

- Tiny VGA Pmod / VGA-compatible display
- Gamepad Pmod
- Optional piezo or speaker connected through suitable filtering/amplification
  to `uio[0]`
