/*
 * Copyright (c) 2025 Uri Shaked
 * SPDX-License-Identifier: Apache-2.0
 *
 * ---------------------------------------------------------------------------
 * "Silicon Simon" extension
 * ---------------------------------------------------------------------------
 * This keeps the original tt_um_vga_example scaffolding completely intact
 * (VGA sync generation, gamepad Pmod decoding, the 12 glyph bitmaps and their
 * screen positions, and the 2-bit-per-channel palette) and adds a real,
 * synthesizable Simon-Says game FSM on top of it:
 *
 *   - A round-robin "show the sequence, then repeat it back" game loop.
 *   - A free-running LFSR reseeded every frame by a second, always-toggling
 *     LFSR so the sequence differs between power-ups depending on exactly
 *     when you press Start (a cheap but genuine on-chip source of jitter).
 *   - Per-round speed-up (the reveal flashes get shorter each round).
 *   - A single-bit PWM "chiptune" tone generator, one musical note per
 *     glyph, driven out on uio_out[0] (e.g. through an RC filter to a
 *     speaker/piezo on a Pmod). A low buzzer tone plays on a miss, and a
 *     pseudo-random hiss plays during the boot-static screen.
 *   - A CRT-style scanline dim (every other raster line loses one DAC step)
 *     on the game-over screen.
 *   - An on-chip "high score" register that tracks the best run for as long
 *     as the chip stays powered. NOTE: this is a plain flip-flop register,
 *     not non-volatile memory -- like every register on this ASIC it resets
 *     to 0 on power-cycle/reset. That is an honest hardware limitation, not
 *     a bug: real persistence across power-off would need external
 *     non-volatile storage this design does not have.
 *
 * Display: every button is a 40x40 rounded pad with a 2 px outline and a
 * redrawn 8x8 icon; face buttons keep their classic colours, and a pad
 * lights up green (ok) / red (miss) when the game highlights it. Also: a
 * "SIMON" title with drop shadow and cycling colours, LED-cell score bars,
 * a state-coloured border, and a subtle navy checkerboard background.
 *
 * Everything below is meant to run for real on the Tiny Tapeout chip (or in
 * simulation/FPGA) at the same 25.175 MHz pixel clock as the original demo.
 */

`default_nettype none

module tt_um_vga_example #(
    // Frame-rate timing constants (~59.5 Hz frame tick at 25.175 MHz pixel
    // clock). These are `parameter`s (not `localparam`) purely so a
    // testbench can override them with tiny values for fast simulation;
    // the chip itself is always instantiated with the defaults below,
    // which are the real gameplay timings.
    parameter [15:0] BOOT_FRAMES          = 16'd48,   // ~0.8s glyph-chase intro on power-up
    parameter [15:0] SHOW_GAP_FRAMES      = 16'd12,   // pause between reveal flashes
    parameter [15:0] BASE_SHOW_FRAMES     = 16'd34,   // round-1 reveal duration
    parameter [15:0] MIN_SHOW_FRAMES      = 16'd8,    // fastest reveal duration
    parameter [15:0] ROUND_OK_FRAMES      = 16'd30,   // pause after a completed round (praise text shows)
    parameter [15:0] INPUT_TIMEOUT_FRAMES = 16'd300,  // ~5s: give up waiting for a press
    parameter [15:0] FEEDBACK_FRAMES      = 16'd10,   // correct-press flash duration
    parameter [15:0] MISS_FLASH_FRAMES    = 16'd40    // wrong-press flash before game over
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // uio[0] is used as a 1-bit PWM audio output (feed it through an RC
  // low-pass into a speaker/piezo). Everything else on uio is unused.
  wire audio_pwm;
  assign uio_out = {7'b0, audio_pwm};
  assign uio_oe  = 8'b0000_0001;

  // Suppress unused signals warning
  wire _unused_ok = &{ena, ui_in[7], ui_in[4:0], uio_in};

  // VGA signals
  wire hsync;
  wire vsync;
  reg [1:0] R;
  reg [1:0] G;
  reg [1:0] B;
  wire video_active;
  wire [9:0] pix_x;
  wire [9:0] pix_y;

  // Tiny VGA Pmod
  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

  hvsync_generator vga_sync_gen (
      .clk(clk),
      .reset(~rst_n),
      .hsync(hsync),
      .vsync(vsync),
      .display_on(video_active),
      .hpos(pix_x),
      .vpos(pix_y)
  );

  // Gamepad Pmod
  wire inp_b, inp_y, inp_select, inp_start, inp_up, inp_down, inp_left, inp_right, inp_a, inp_x, inp_l, inp_r;

  gamepad_pmod_single driver (
      // Inputs:
      .rst_n(rst_n),
      .clk(clk),
      .pmod_data(ui_in[6]),
      .pmod_clk(ui_in[5]),
      .pmod_latch(ui_in[4]),
      // Outputs:
      .b(inp_b),
      .y(inp_y),
      .select(inp_select),
      .start(inp_start),
      .up(inp_up),
      .down(inp_down),
      .left(inp_left),
      .right(inp_right),
      .a(inp_a),
      .x(inp_x),
      .l(inp_l),
      .r(inp_r)
  );

  // ---------------------------------------------------------------------
  // Colors (2 bits per channel, exactly what the Tiny VGA Pmod's resistor
  // DAC can produce: 0, 85, 170 or 255 per channel)
  // ---------------------------------------------------------------------
  localparam [5:0] BLACK = {2'b00, 2'b00, 2'b00};
  localparam [5:0] GREEN = {2'b00, 2'b11, 2'b00};
  localparam [5:0] WHITE = {2'b11, 2'b11, 2'b11};
  localparam [5:0] RED   = {2'b11, 2'b00, 2'b00};
  localparam [5:0] BLUE  = {2'b00, 2'b00, 2'b11};
  localparam [5:0] CYAN  = {2'b00, 2'b11, 2'b11};
  localparam [5:0] YELLOW = {2'b11, 2'b11, 2'b00};
  localparam [5:0] DKGRAY = {2'b01, 2'b01, 2'b01};
  localparam [5:0] LTGRAY = {2'b10, 2'b10, 2'b10};
  localparam [5:0] NAVY   = {2'b00, 2'b00, 2'b01};
  localparam [5:0] DKCYAN = {2'b00, 2'b01, 2'b01};
  localparam [5:0] DKYELL = {2'b01, 2'b01, 2'b00};

  // Glyph definitions (8x8) -- identical bitmaps to the original demo, just
  // stored as plain packed 64-bit constants (row 7..0, MSB row first)
  // instead of an unpacked-array localparam with a '{...} initializer.
  // Icarus Verilog (and some synthesis front-ends) are unreliable at
  // parsing unpacked-array localparam initializers, while a packed vector
  // is universally supported by every Verilog-2001+ tool -- important
  // since this needs to actually build for real hardware/FPGA, not just
  // look right in one simulator.
  localparam [63:0] LEFT_GLYPH = {
      8'b00010000, 8'b00110000, 8'b01110000, 8'b11111111,
      8'b11111111, 8'b01110000, 8'b00110000, 8'b00010000
  };
  localparam [63:0] RIGHT_GLYPH = {
      8'b00001000, 8'b00001100, 8'b00001110, 8'b11111111,
      8'b11111111, 8'b00001110, 8'b00001100, 8'b00001000
  };
  localparam [63:0] UP_GLYPH = {
      8'b00011000, 8'b00111100, 8'b01111110, 8'b11111111,
      8'b00011000, 8'b00011000, 8'b00011000, 8'b00011000
  };
  localparam [63:0] DOWN_GLYPH = {
      8'b00011000, 8'b00011000, 8'b00011000, 8'b00011000,
      8'b11111111, 8'b01111110, 8'b00111100, 8'b00011000
  };
  localparam [63:0] A_GLYPH = {
      8'b00111100, 8'b01100110, 8'b01100110, 8'b01100110,
      8'b01111110, 8'b01100110, 8'b01100110, 8'b01100110
  };
  localparam [63:0] B_GLYPH = {
      8'b01111100, 8'b01100110, 8'b01100110, 8'b01111100,
      8'b01111100, 8'b01100110, 8'b01100110, 8'b01111100
  };
  localparam [63:0] X_GLYPH = {
      8'b11000011, 8'b01100110, 8'b00111100, 8'b00011000,
      8'b00011000, 8'b00111100, 8'b01100110, 8'b11000011
  };
  localparam [63:0] Y_GLYPH = {
      8'b11000011, 8'b01100110, 8'b00111100, 8'b00011000,
      8'b00011000, 8'b00011000, 8'b00011000, 8'b00011000
  };
  localparam [63:0] L_GLYPH = {
      8'b01100000, 8'b01100000, 8'b01100000, 8'b01100000,
      8'b01100000, 8'b01100000, 8'b01111110, 8'b01111110
  };
  localparam [63:0] R_GLYPH = {
      8'b01111100, 8'b01100110, 8'b01100110, 8'b01111100,
      8'b01111000, 8'b01101100, 8'b01100110, 8'b01100110
  };
  localparam [63:0] SELECT_GLYPH = {
      8'b00011000, 8'b00100100, 8'b01000010, 8'b10000001,
      8'b10000001, 8'b01000010, 8'b00100100, 8'b00011000
  };
  localparam [63:0] START_GLYPH = {
      8'b00011000, 8'b01011010, 8'b10011001, 8'b10011001,
      8'b10011001, 8'b10000001, 8'b01000010, 8'b00111100
  };

  // D-pad centre hub (decoration only): a small dot on a blank pad.
  localparam [63:0] HUB_GLYPH = {
      8'b00000000, 8'b00000000, 8'b00011000, 8'b00111100,
      8'b00111100, 8'b00011000, 8'b00000000, 8'b00000000
  };

  // ---- 5x7 text font -------------------------------------------------
  // Character codes (5 bits). 0 = space.
  localparam [4:0] CH_SP = 5'd0;
  localparam [4:0] CH_A = 5'd1;
  localparam [4:0] CH_B = 5'd2;
  localparam [4:0] CH_C = 5'd3;
  localparam [4:0] CH_D = 5'd4;
  localparam [4:0] CH_E = 5'd5;
  localparam [4:0] CH_G = 5'd6;
  localparam [4:0] CH_H = 5'd7;
  localparam [4:0] CH_I = 5'd8;
  localparam [4:0] CH_J = 5'd9;
  localparam [4:0] CH_K = 5'd10;
  localparam [4:0] CH_L = 5'd11;
  localparam [4:0] CH_M = 5'd12;
  localparam [4:0] CH_N = 5'd13;
  localparam [4:0] CH_O = 5'd14;
  localparam [4:0] CH_P = 5'd15;
  localparam [4:0] CH_R = 5'd16;
  localparam [4:0] CH_S = 5'd17;
  localparam [4:0] CH_T = 5'd18;
  localparam [4:0] CH_X = 5'd19;
  localparam [4:0] CH_EX = 5'd20;

  // One 35-bit word per letter (row 0 = top = MSB, 5 bits per row).
  localparam [34:0] F_A = {5'b01110, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};
  localparam [34:0] F_B = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10001, 5'b10001, 5'b11110};
  localparam [34:0] F_C = {5'b01110, 5'b10001, 5'b10000, 5'b10000, 5'b10000, 5'b10001, 5'b01110};
  localparam [34:0] F_D = {5'b11110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b11110};
  localparam [34:0] F_E = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};
  localparam [34:0] F_G = {5'b01110, 5'b10001, 5'b10000, 5'b10111, 5'b10001, 5'b10001, 5'b01111};
  localparam [34:0] F_H = {5'b10001, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};
  localparam [34:0] F_I = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b11111};
  localparam [34:0] F_J = {5'b00111, 5'b00010, 5'b00010, 5'b00010, 5'b00010, 5'b10010, 5'b01100};
  localparam [34:0] F_K = {5'b10001, 5'b10010, 5'b10100, 5'b11000, 5'b10100, 5'b10010, 5'b10001};
  localparam [34:0] F_L = {5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b11111};
  localparam [34:0] F_M = {5'b10001, 5'b11011, 5'b10101, 5'b10101, 5'b10001, 5'b10001, 5'b10001};
  localparam [34:0] F_N = {5'b10001, 5'b11001, 5'b10101, 5'b10011, 5'b10001, 5'b10001, 5'b10001};
  localparam [34:0] F_O = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};
  localparam [34:0] F_P = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10000, 5'b10000, 5'b10000};
  localparam [34:0] F_R = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10100, 5'b10010, 5'b10001};
  localparam [34:0] F_S = {5'b01111, 5'b10000, 5'b10000, 5'b01110, 5'b00001, 5'b00001, 5'b11110};
  localparam [34:0] F_T = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100};
  localparam [34:0] F_X = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b01010, 5'b10001, 5'b10001};
  localparam [34:0] F_EX = {5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00000, 5'b00100};

  // Messages: up to 10 characters per line, first character in the MSBs.
  localparam [49:0] M_NICE    = {CH_N, CH_I, CH_C, CH_E, 30'd0};
  localparam [49:0] M_GOOD    = {CH_G, CH_O, CH_O, CH_D, CH_SP, CH_J, CH_O, CH_B, 10'd0};
  localparam [49:0] M_EXCEL   = {CH_E, CH_X, CH_C, CH_E, CH_L, CH_L, CH_E, CH_N, CH_T, 5'd0};
  localparam [49:0] M_HIGH    = {CH_H, CH_I, CH_G, CH_H, CH_SP, CH_S, CH_C, CH_O, CH_R, CH_E};
  localparam [49:0] M_REACHED = {CH_R, CH_E, CH_A, CH_C, CH_H, CH_E, CH_D, CH_EX, 10'd0};
  localparam [49:0] M_NOPE    = {CH_N, CH_O, CH_P, CH_E, CH_EX, 25'd0};
  localparam [49:0] M_BOBO    = {CH_B, CH_O, CH_B, CH_O, CH_SP, CH_K, CH_A, CH_EX, 10'd0};

  // Glyph positions -- unchanged from the original demo
  localparam LEFT_X = 48, LEFT_Y = 240;
  localparam RIGHT_X = 144, RIGHT_Y = 240;
  localparam UP_X = 96, UP_Y = 192;
  localparam DOWN_X = 96, DOWN_Y = 288;
  localparam A_X = 560, A_Y = 240;
  localparam B_X = 512, B_Y = 296;
  localparam X_X = 512, X_Y = 184;
  localparam Y_X = 464, Y_Y = 240;
  localparam L_X = 32, L_Y = 92;
  localparam R_X = 592, R_Y = 92;
  localparam SEL_X = 264, SEL_Y = 240;
  localparam STRT_X = 328, STRT_Y = 240;
  localparam HUB_X = 96, HUB_Y = 240;
  // Each icon sits on a 40x40 rounded "pad" (4 px margin around the 32x32 icon).
  // Title "SIMON": 5 letters, 32 px per letter cell, 28 px tall.
  localparam [9:0] TITLE_X = 10'd240, TITLE_Y = 10'd24;

  // Pad geometry: glyph_pix returns {ink, ring, plate} for the pad under the
  // beam. plate = anywhere on the rounded 40x40 pad, ring = its 2 px outline,
  // ink = the icon pixels.
  wire [2:0] p_left  = glyph_pix(LEFT_X,  LEFT_Y,  LEFT_GLYPH);
  wire [2:0] p_right = glyph_pix(RIGHT_X, RIGHT_Y, RIGHT_GLYPH);
  wire [2:0] p_up    = glyph_pix(UP_X,    UP_Y,    UP_GLYPH);
  wire [2:0] p_down  = glyph_pix(DOWN_X,  DOWN_Y,  DOWN_GLYPH);
  wire [2:0] p_a     = glyph_pix(A_X,     A_Y,     A_GLYPH);
  wire [2:0] p_b     = glyph_pix(B_X,     B_Y,     B_GLYPH);
  wire [2:0] p_x     = glyph_pix(X_X,     X_Y,     X_GLYPH);
  wire [2:0] p_y     = glyph_pix(Y_X,     Y_Y,     Y_GLYPH);
  wire [2:0] p_l     = glyph_pix(L_X,     L_Y,     L_GLYPH);
  wire [2:0] p_r     = glyph_pix(R_X,     R_Y,     R_GLYPH);
  wire [2:0] p_sel   = glyph_pix(SEL_X,   SEL_Y,   SELECT_GLYPH);
  wire [2:0] p_strt  = glyph_pix(STRT_X,  STRT_Y,  START_GLYPH);
  wire [2:0] p_hub   = glyph_pix(HUB_X,   HUB_Y,   HUB_GLYPH);

  // Glyph id assignment (0-11), used throughout the game logic:
  //   0=LEFT 1=RIGHT 2=UP 3=DOWN 4=A 5=B 6=X 7=Y 8=L 9=R 10=SELECT 11=START
  wire [11:0] plate_vec = {p_strt[0], p_sel[0], p_r[0], p_l[0], p_y[0], p_x[0],
                           p_b[0], p_a[0], p_down[0], p_up[0], p_right[0], p_left[0]};
  wire [11:0] ring_vec  = {p_strt[1], p_sel[1], p_r[1], p_l[1], p_y[1], p_x[1],
                           p_b[1], p_a[1], p_down[1], p_up[1], p_right[1], p_left[1]};
  wire [11:0] ink_vec   = {p_strt[2], p_sel[2], p_r[2], p_l[2], p_y[2], p_x[2],
                           p_b[2], p_a[2], p_down[2], p_up[2], p_right[2], p_left[2]};
  wire [11:0] btn_now   = {inp_start, inp_select, inp_r, inp_l, inp_y, inp_x,
                            inp_b, inp_a, inp_down, inp_up, inp_right, inp_left};

  localparam [3:0] GLYPH_NONE = 4'hF;

  // Priority encoder: lowest-numbered set bit wins (only matters if two
  // buttons are pressed on the same clock edge).
  function [4:0] first_set;
    input [11:0] v;
    integer i;
    reg found;
    begin
      first_set = {1'b0, GLYPH_NONE};
      found = 1'b0;
      for (i = 0; i < 12; i = i + 1) begin
        if (!found && v[i]) begin
          first_set = {1'b1, i[3:0]};
          found = 1'b1;
        end
      end
    end
  endfunction

  wire [4:0] pix_glyph = first_set(plate_vec);
  wire pix_glyph_valid = pix_glyph[4];
  wire [3:0] pix_glyph_id = pix_glyph[3:0];

  // ---------------------------------------------------------------------
  // Random number generation
  // ---------------------------------------------------------------------
  // `noise_lfsr` free-runs every clock (23-bit maximal LFSR) and is used
  // both for the boot-static visual/audio effect and as jitter that gets
  // folded into `rng_lfsr` so the game sequence isn't identical every
  // power-up. `rng_lfsr` (16-bit maximal LFSR) advances once per frame and
  // is sampled whenever a new sequence step is needed.
  reg [22:0] noise_lfsr;
  wire noise_fb = noise_lfsr[22] ^ noise_lfsr[17];

  reg [15:0] rng_lfsr;
  wire rng_fb = rng_lfsr[15] ^ rng_lfsr[13] ^ rng_lfsr[12] ^ rng_lfsr[10];

  wire frame_tick = (pix_x == 0) && (pix_y == 0);

  // Reduce an 8-bit sum down to the range 0..11 (mod 12) with plain
  // conditional subtraction -- small, fast, and fully synthesizable.
  function [3:0] mod12;
    input [7:0] v;
    reg [7:0] t;
    begin
      t = v;
      if (t >= 8'd96) t = t - 8'd96;
      if (t >= 8'd48) t = t - 8'd48;
      if (t >= 8'd24) t = t - 8'd24;
      if (t >= 8'd12) t = t - 8'd12;
      mod12 = t[3:0];
    end
  endfunction

  wire [3:0] next_glyph = mod12(rng_lfsr[3:0] + rng_lfsr[7:4] + rng_lfsr[11:8] + rng_lfsr[15:12]);

  // ---------------------------------------------------------------------
  // Chiptune tone table: one musical note per glyph (C major scale over
  // two octaves), plus a low "miss" buzzer. Values are half-period counts
  // at the 25.175 MHz pixel clock.
  // ---------------------------------------------------------------------
  function [16:0] note_of;
    input [3:0] id;
    begin
      case (id)
        4'd0:  note_of = 17'd48108;  // LEFT   - C4
        4'd1:  note_of = 17'd42862;  // RIGHT  - D4
        4'd2:  note_of = 17'd38186;  // UP     - E4
        4'd3:  note_of = 17'd36043;  // DOWN   - F4
        4'd4:  note_of = 17'd32112;  // A      - G4
        4'd5:  note_of = 17'd28608;  // B      - A4
        4'd6:  note_of = 17'd25489;  // X      - B4
        4'd7:  note_of = 17'd24059;  // Y      - C5
        4'd8:  note_of = 17'd21433;  // L      - D5
        4'd9:  note_of = 17'd19094;  // R      - E5
        4'd10: note_of = 17'd18022;  // SELECT - F5
        4'd11: note_of = 17'd16056;  // START  - G5
        default: note_of = 17'd48108;
      endcase
    end
  endfunction

  localparam [16:0] NOTE_BUZZ = 17'd114432;  // ~110 Hz miss buzzer

  localparam [23:0] SHORT_TONE_CYCLES = 24'd3_000_000;   // ~120 ms
  localparam [23:0] BUZZ_TONE_CYCLES  = 24'd12_500_000;  // ~500 ms

  // ---------------------------------------------------------------------
  // Game FSM
  // ---------------------------------------------------------------------
  localparam [3:0] ST_BOOT       = 4'd0;
  localparam [3:0] ST_IDLE       = 4'd1;
  localparam [3:0] ST_ADD_STEP   = 4'd2;
  localparam [3:0] ST_SHOW_ON    = 4'd3;
  localparam [3:0] ST_SHOW_OFF   = 4'd4;
  localparam [3:0] ST_WAIT_INPUT = 4'd5;
  localparam [3:0] ST_FEEDBACK   = 4'd6;
  localparam [3:0] ST_ROUND_OK   = 4'd7;
  localparam [3:0] ST_MISS_FLASH = 4'd8;
  localparam [3:0] ST_GAME_OVER  = 4'd9;

  localparam [1:0] LIT_IDLE  = 2'd0;
  localparam [1:0] LIT_GREEN = 2'd1;
  localparam [1:0] LIT_RED   = 2'd2;

  reg [3:0] state;
  reg [15:0] frame_cnt;

  reg [3:0] seq[0:31];
  reg [5:0] seq_len;
  reg [5:0] step_idx;
  reg [5:0] round;
  reg [5:0] high_score;
  reg [5:0] last_score;
  reg new_high_flag;

  reg [3:0] lit_id;
  reg [1:0] lit_color;
  reg [5:0] blink_cnt;   // free-running frame counter, bit 5 = ~1 Hz blink

  reg [11:0] btn_prev;
  wire [11:0] btn_edge = btn_now & ~btn_prev;
  wire [4:0] pressed = first_set(btn_edge);
  wire pressed_valid = pressed[4];
  wire [3:0] pressed_id = pressed[3:0];

  // Reveal speed for the current round: gets shorter (faster) each round,
  // clamped at MIN_SHOW_FRAMES.
  wire [15:0] round_dec = {10'b0, round} * 16'd2;
  wire [15:0] show_frames = (BASE_SHOW_FRAMES > (MIN_SHOW_FRAMES + round_dec))
                              ? (BASE_SHOW_FRAMES - round_dec)
                              : MIN_SHOW_FRAMES;

  // Tone generator state
  reg [16:0] tone_period;
  reg [16:0] tone_cnt;
  reg tone_square;
  reg [23:0] tone_dur_cnt;

  wire boot_hiss = noise_lfsr[2] & noise_lfsr[9];
  assign audio_pwm = (tone_dur_cnt != 0) ? tone_square
                    : (state == ST_BOOT) ? boot_hiss
                    : 1'b0;

  integer k;

  always @(posedge clk) begin
    if (~rst_n) begin
      state          <= ST_BOOT;
      frame_cnt      <= 16'd0;
      noise_lfsr     <= 23'h2AF19;  // any nonzero seed
      rng_lfsr       <= 16'hACE1;   // any nonzero seed
      seq_len        <= 6'd0;
      step_idx       <= 6'd0;
      round          <= 6'd0;
      high_score     <= 6'd0;
      last_score     <= 6'd0;
      new_high_flag  <= 1'b0;
      lit_id         <= GLYPH_NONE;
      lit_color      <= LIT_IDLE;
      blink_cnt      <= 6'd0;
      btn_prev       <= 12'd0;
      tone_period    <= 17'd0;
      tone_cnt       <= 17'd0;
      tone_square    <= 1'b0;
      tone_dur_cnt   <= 24'd0;
      for (k = 0; k < 32; k = k + 1) seq[k] <= 4'd0;
    end else begin
      // Free-running noise LFSR, every clock.
      noise_lfsr <= {noise_lfsr[21:0], noise_fb};

      // Remember button state for edge detection.
      btn_prev <= btn_now;

      // Tone generator: counts down regardless of game state; a new
      // trigger (set below, inside the FSM) overrides it immediately.
      if (tone_dur_cnt != 0) begin
        tone_dur_cnt <= tone_dur_cnt - 24'd1;
        if (tone_cnt >= tone_period) begin
          tone_cnt <= 17'd0;
          tone_square <= ~tone_square;
        end else begin
          tone_cnt <= tone_cnt + 17'd1;
        end
      end else begin
        tone_square <= 1'b0;
      end

      // Advance the game RNG once per frame, folding in live jitter from
      // the free-running noise LFSR.
      if (frame_tick) begin
        rng_lfsr  <= {rng_lfsr[14:0], rng_fb ^ noise_lfsr[3]};
        blink_cnt <= blink_cnt + 6'd1;
      end

      case (state)

        // -------------------------------------------------------------
        ST_BOOT: begin
          // Intro: light the 12 glyphs one after another (2 frames each).
          lit_id    <= mod12({1'b0, frame_cnt[7:1]});
          lit_color <= LIT_GREEN;
          if (frame_tick) begin
            if (frame_cnt >= BOOT_FRAMES) begin
              frame_cnt <= 16'd0;
              state     <= ST_IDLE;
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_IDLE: begin
          lit_id    <= GLYPH_NONE;
          lit_color <= LIT_IDLE;
          if (pressed_valid && pressed_id == 4'd11) begin  // Start
            round         <= 6'd0;
            seq_len       <= 6'd0;
            step_idx      <= 6'd0;
            new_high_flag <= 1'b0;
            frame_cnt     <= 16'd0;
            state         <= ST_ADD_STEP;
          end
        end

        // -------------------------------------------------------------
        ST_ADD_STEP: begin
          seq[seq_len] <= next_glyph;
          seq_len      <= seq_len + 6'd1;
          round        <= round + 6'd1;
          step_idx     <= 6'd0;
          frame_cnt    <= 16'd0;
          lit_id       <= next_glyph;
          lit_color    <= LIT_GREEN;
          state        <= ST_SHOW_ON;
          // Beep the newly-revealed glyph's note.
          tone_period  <= note_of(next_glyph);
          tone_dur_cnt <= SHORT_TONE_CYCLES;
          tone_cnt     <= 17'd0;
        end

        // -------------------------------------------------------------
        ST_SHOW_ON: begin
          lit_id    <= seq[step_idx];
          lit_color <= LIT_GREEN;
          if (frame_tick) begin
            if (frame_cnt >= show_frames) begin
              frame_cnt <= 16'd0;
              state     <= ST_SHOW_OFF;
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_SHOW_OFF: begin
          lit_id    <= GLYPH_NONE;
          lit_color <= LIT_IDLE;
          if (frame_tick) begin
            if (frame_cnt >= SHOW_GAP_FRAMES) begin
              frame_cnt <= 16'd0;
              if (step_idx + 6'd1 < seq_len) begin
                step_idx <= step_idx + 6'd1;
                state    <= ST_SHOW_ON;
              end else begin
                step_idx <= 6'd0;
                state    <= ST_WAIT_INPUT;
              end
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_WAIT_INPUT: begin
          if (pressed_valid) begin
            frame_cnt <= 16'd0;
            lit_id    <= pressed_id;
            if (pressed_id == seq[step_idx]) begin
              lit_color    <= LIT_GREEN;
              tone_period  <= note_of(pressed_id);
              tone_dur_cnt <= SHORT_TONE_CYCLES;
              tone_cnt     <= 17'd0;
              if (step_idx + 6'd1 == seq_len) begin
                state <= ST_ROUND_OK;
              end else begin
                step_idx <= step_idx + 6'd1;
                state    <= ST_FEEDBACK;
              end
            end else begin
              lit_color    <= LIT_RED;
              tone_period  <= NOTE_BUZZ;
              tone_dur_cnt <= BUZZ_TONE_CYCLES;
              tone_cnt     <= 17'd0;
              last_score   <= round - 6'd1;
              state        <= ST_MISS_FLASH;
            end
          end else if (frame_tick) begin
            if (frame_cnt >= INPUT_TIMEOUT_FRAMES) begin
              // Gave up waiting -- counts as a miss.
              lit_id       <= GLYPH_NONE;
              lit_color    <= LIT_RED;
              tone_period  <= NOTE_BUZZ;
              tone_dur_cnt <= BUZZ_TONE_CYCLES;
              tone_cnt     <= 17'd0;
              last_score   <= round - 6'd1;
              state        <= ST_MISS_FLASH;
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_FEEDBACK: begin
          if (frame_tick) begin
            if (frame_cnt >= FEEDBACK_FRAMES) begin
              frame_cnt <= 16'd0;
              lit_id    <= GLYPH_NONE;
              lit_color <= LIT_IDLE;
              state     <= ST_WAIT_INPUT;
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_ROUND_OK: begin
          lit_id    <= GLYPH_NONE;
          lit_color <= LIT_IDLE;
          if (frame_tick) begin
            if (frame_cnt >= ROUND_OK_FRAMES) begin
              frame_cnt <= 16'd0;
              state     <= ST_ADD_STEP;
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_MISS_FLASH: begin
          if (frame_tick) begin
            if (frame_cnt >= MISS_FLASH_FRAMES) begin
              frame_cnt <= 16'd0;
              if (last_score > high_score) begin
                high_score    <= last_score;
                new_high_flag <= 1'b1;
              end else begin
                new_high_flag <= 1'b0;
              end
              state <= ST_GAME_OVER;
            end else begin
              frame_cnt <= frame_cnt + 16'd1;
            end
          end
        end

        // -------------------------------------------------------------
        ST_GAME_OVER: begin
          // lit_id/lit_color hold the last (wrong) glyph in red.
          if (pressed_valid && pressed_id == 4'd11) begin  // Start
            frame_cnt <= 16'd0;
            lit_id    <= GLYPH_NONE;
            lit_color <= LIT_IDLE;
            state     <= ST_IDLE;
          end
        end

        default: state <= ST_BOOT;
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------
  // ---- pads -----------------------------------------------------------
  wire [15:0] ink16  = {4'b0, ink_vec};
  wire [15:0] ring16 = {4'b0, ring_vec};
  wire pix_ink  = pix_glyph_valid && ink16[pix_glyph_id];
  wire pix_ring = pix_glyph_valid && ring16[pix_glyph_id];

  // "Press START" hint: the START pad blinks yellow on the title / game-over screens.
  wire wait_start = (state == ST_IDLE) || (state == ST_GAME_OVER);

  // A pad lights up when the game highlights it (green = ok, red = miss),
  // when the round is complete (all pads green), or as the START hint.
  wire pad_lit  = pix_glyph_valid && (pix_glyph_id == lit_id) && (lit_color != LIT_IDLE);
  wire pad_ok   = pix_glyph_valid && (state == ST_ROUND_OK);
  wire pad_hint = pix_glyph_valid && wait_start && blink_cnt[5] && (pix_glyph_id == 4'd11);
  wire pad_on   = pad_lit || pad_ok || pad_hint;
  wire pad_red  = pad_lit && (lit_color == LIT_RED);
  wire [5:0] on_fill = pad_lit ? (pad_red ? RED : GREEN)
                     : pad_ok  ? GREEN
                     :           YELLOW;

  wire [5:0] pad_color = pix_ink  ? (pad_on ? (pad_red ? WHITE : BLACK) : WHITE)
                       : pix_ring ? (pad_on ? WHITE : pad_ring_color(pix_glyph_id))
                       :            (pad_on ? on_fill : pad_fill_color(pix_glyph_id));

  // ---- d-pad hub (decoration) ----------------------------------------
  wire [5:0] hub_color = p_hub[2] ? WHITE : (p_hub[1] ? LTGRAY : DKGRAY);

  // ---- which message to show (0 = none) --------------------------------
  //   1 NICE / 2 GOOD JOB / 3 EXCELLENT  - round complete, praise grows with the round
  //   4 HIGH SCORE REACHED!              - beat your best (live, or on the game-over screen)
  //   5 NOPE! / 6 BOBO KA!               - you missed
  wire high_hit = new_high_flag || ((state == ST_MISS_FLASH) && (last_score > high_score));
  wire live_high = (high_score != 6'd0) && (round > high_score);
  wire [2:0] msg_id = (state == ST_ROUND_OK)
                        ? (live_high         ? 3'd4
                         : (round < 6'd3)    ? 3'd1
                         : (round < 6'd6)    ? 3'd2
                         :                     3'd3)
                    : (state == ST_MISS_FLASH || state == ST_GAME_OVER)
                        ? (high_hit          ? 3'd4
                         : last_score[0]     ? 3'd6
                         :                     3'd5)
                    : 3'd0;

  // ---- text layout: title + up to two message lines (4x scale, 32 px cells,
  // each block 32 px tall incl. the 4 px drop shadow), messages centred ------
  wire [3:0] len1 = msg_len(msg_id, 1'b0);
  wire [3:0] len2 = msg_len(msg_id, 1'b1);
  wire [9:0] tx_t = pix_x - TITLE_X;
  wire [9:0] ty_t = pix_y - TITLE_Y;
  wire [9:0] tx1  = pix_x - (10'd320 - {2'b00, len1, 4'b0000});
  wire [9:0] ty1  = pix_y - 10'd104;
  wire [9:0] tx2  = pix_x - (10'd320 - {2'b00, len2, 4'b0000});
  wire [9:0] ty2  = pix_y - 10'd144;
  wire in_title = (tx_t < 10'd160) && (ty_t < 10'd32);
  wire in_l1    = (len1 != 4'd0) && (tx1 < {1'b0, len1, 5'b00000}) && (ty1 < 10'd32);
  wire in_l2    = (len2 != 4'd0) && (tx2 < {1'b0, len2, 5'b00000}) && (ty2 < 10'd32);
  wire in_text  = in_title || in_l1 || in_l2;

  // Only one glyph lookup per pixel: pick the block first, then decode.
  wire [4:0] tcode = in_title ? title_code(tx_t[7:5])
                   : in_l1    ? msg_code(msg_word(msg_id, 1'b0), tx1[8:5])
                   :            msg_code(msg_word(msg_id, 1'b1), tx2[8:5]);
  wire [9:0] tcx = in_title ? tx_t : (in_l1 ? tx1 : tx2);
  wire [9:0] tcy = in_title ? ty_t : (in_l1 ? ty1 : ty2);
  wire [1:0] tpx = text_px(font_word(tcode), tcx[4:2], tcy[4:2]);  // {shadow, ink}
  wire text_on     = in_text && tpx[0];
  wire text_shadow = in_text && tpx[1];

  // Colours: title and HIGH SCORE cycle through a rainbow; the rest are fixed.
  wire [1:0] rb_ci = (in_title ? blink_cnt[5:4] : blink_cnt[4:3]) + tcx[6:5];
  wire [5:0] rainbow = (rb_ci == 2'd0) ? RED
                     : (rb_ci == 2'd1) ? YELLOW
                     : (rb_ci == 2'd2) ? GREEN
                     :                   CYAN;
  wire [5:0] msg_fixed = (msg_id == 3'd1) ? GREEN
                       : (msg_id == 3'd2) ? CYAN
                       : (msg_id == 3'd3) ? YELLOW
                       :                    RED;
  wire [5:0] text_color = (in_title || msg_id == 3'd4) ? rainbow : msg_fixed;

  // ---- score bars: 32 LED cells (12 px lit + 4 px gap) per bar -----------
  // cyan = current round, yellow = best run since power-up (green when the
  // run that just ended set a new best). Unlit cells stay visible as dim slots.
  wire [9:0] bar_x    = pix_x - 10'd64;
  wire       bar_seg  = ~bar_x[9] && (bar_x[3:0] < 4'd12);
  wire [5:0] bar_cell = {1'b0, bar_x[8:4]};
  wire round_track = bar_seg && (pix_y >= 10'd392) && (pix_y < 10'd400);
  wire high_track  = bar_seg && (pix_y >= 10'd408) && (pix_y < 10'd416);
  wire [5:0] round_color = (bar_cell < round)      ? CYAN : DKCYAN;
  wire [5:0] high_color  = (bar_cell < high_score) ? (new_high_flag ? GREEN : YELLOW) : DKYELL;

  // ---- screen border: whose turn / result -------------------------------
  //   blue = your turn, green = round complete, red = miss / game over.
  wire in_border = (pix_x < 10'd8) || (pix_x >= 10'd632) ||
                   (pix_y < 10'd8) || (pix_y >= 10'd472);
  wire [5:0] border_color = (state == ST_WAIT_INPUT || state == ST_FEEDBACK)   ? BLUE
                          : (state == ST_ROUND_OK)                             ? GREEN
                          : (state == ST_MISS_FLASH || state == ST_GAME_OVER)  ? RED
                          :                                                      DKGRAY;

  // ---- background: subtle 8 px navy checkerboard -------------------------
  wire [5:0] bg_color = (pix_x[3] ^ pix_y[3]) ? NAVY : BLACK;

  wire [5:0] color6 = pix_glyph_valid ? pad_color
                     : p_hub[0]       ? hub_color
                     : text_on        ? text_color
                     : text_shadow    ? {2'b00, 2'b00, 2'b10}
                     : round_track    ? round_color
                     : high_track     ? high_color
                     : in_border      ? border_color
                     :                  bg_color;

  // CRT-style scanline dim on the game-over screen: clear the LSB of each
  // 2-bit channel on every other raster line (a genuine 2-bit-DAC-safe
  // brightness step, not a fake overlay).
  wire scanlines_on = (state == ST_GAME_OVER) && pix_y[0];
  wire [5:0] color6_scanned = scanlines_on ? (color6 & 6'b101010) : color6;

  always @(posedge clk) begin
    if (~rst_n) begin
      R <= 2'b0;
      G <= 2'b0;
      B <= 2'b0;
    end else begin
      if (video_active) begin
        {R, G, B} <= color6_scanned;
      end else begin
        {R, G, B} <= 6'b0;
      end
    end
  end

  // Select one 8-bit row out of a packed 64-bit glyph constant (row 0 = the
  // top row, stored in the most-significant byte).
  function [7:0] glyph_row;
    input [63:0] glyph;
    input [2:0] row_idx;
    begin
      case (row_idx)
        3'd0: glyph_row = glyph[63:56];
        3'd1: glyph_row = glyph[55:48];
        3'd2: glyph_row = glyph[47:40];
        3'd3: glyph_row = glyph[39:32];
        3'd4: glyph_row = glyph[31:24];
        3'd5: glyph_row = glyph[23:16];
        3'd6: glyph_row = glyph[15:8];
        3'd7: glyph_row = glyph[7:0];
      endcase
    end
  endfunction

  // Pad + icon pixel test. Returns {ink, ring, plate} for the pad whose 32x32
  // icon area starts at (x0,y0): a 40x40 chamfered-corner plate that extends 4 px
  // beyond the icon on every side, with a 2 px outline ("ring").
  function [2:0] glyph_pix;
    input [9:0] x0, y0;
    input [63:0] glyph;
    reg [9:0] xo, yo, xr, yr;
    reg [5:0] dx, dy, sum;
    reg [7:0] row;
    reg plate, inner, ink;
    begin
      xo = pix_x - (x0 - 10'd4);
      yo = pix_y - (y0 - 10'd4);
      plate = 1'b0;
      inner = 1'b0;
      ink   = 1'b0;
      if (xo < 10'd40 && yo < 10'd40) begin
        // distance to the nearest edge of the 40x40 plate, per axis (0..19)
        dx  = (xo < 10'd20) ? {1'b0, xo[4:0]} : (6'd39 - xo[5:0]);
        dy  = (yo < 10'd20) ? {1'b0, yo[4:0]} : (6'd39 - yo[5:0]);
        sum = dx + dy;
        plate = (sum >= 6'd6);                                  // chamfered corners
        inner = (dx >= 6'd2) && (dy >= 6'd2) && (sum >= 6'd8);  // inside the outline
        if (xo >= 10'd4 && xo < 10'd36 && yo >= 10'd4 && yo < 10'd36) begin
          xr  = xo - 10'd4;
          yr  = yo - 10'd4;
          row = glyph_row(glyph, yr[4:2]);
          ink = row[~xr[4:2]];  // 4x scale: 8 icon columns, column 0 = MSB
        end
      end
      glyph_pix = {ink, plate & ~inner, plate};
    end
  endfunction

  // Idle pad colours by glyph id: d-pad / shoulder / select / start are grey,
  // the four face buttons get their classic colours.
  function [5:0] pad_fill_color;
    input [3:0] id;
    begin
      case (id)
        4'd4:    pad_fill_color = {2'b10, 2'b00, 2'b00};  // A - red
        4'd5:    pad_fill_color = {2'b10, 2'b10, 2'b00};  // B - yellow
        4'd6:    pad_fill_color = {2'b00, 2'b00, 2'b10};  // X - blue
        4'd7:    pad_fill_color = {2'b00, 2'b10, 2'b00};  // Y - green
        default: pad_fill_color = {2'b01, 2'b01, 2'b01};
      endcase
    end
  endfunction

  function [5:0] pad_ring_color;
    input [3:0] id;
    begin
      case (id)
        4'd4:    pad_ring_color = {2'b11, 2'b01, 2'b01};
        4'd5:    pad_ring_color = {2'b11, 2'b11, 2'b01};
        4'd6:    pad_ring_color = {2'b01, 2'b01, 2'b11};
        4'd7:    pad_ring_color = {2'b01, 2'b11, 2'b01};
        default: pad_ring_color = {2'b10, 2'b10, 2'b10};
      endcase
    end
  endfunction

  // Character code -> 35-bit letter bitmap.
  function [34:0] font_word;
    input [4:0] code;
    begin
      case (code)
        CH_A:    font_word = F_A;
        CH_B:    font_word = F_B;
        CH_C:    font_word = F_C;
        CH_D:    font_word = F_D;
        CH_E:    font_word = F_E;
        CH_G:    font_word = F_G;
        CH_H:    font_word = F_H;
        CH_I:    font_word = F_I;
        CH_J:    font_word = F_J;
        CH_K:    font_word = F_K;
        CH_L:    font_word = F_L;
        CH_M:    font_word = F_M;
        CH_N:    font_word = F_N;
        CH_O:    font_word = F_O;
        CH_P:    font_word = F_P;
        CH_R:    font_word = F_R;
        CH_S:    font_word = F_S;
        CH_T:    font_word = F_T;
        CH_X:    font_word = F_X;
        CH_EX:   font_word = F_EX;
        default: font_word = 35'd0;
      endcase
    end
  endfunction

  // One row (5 bits, MSB = leftmost column) of a letter bitmap; rows 0..6.
  function [4:0] font_row;
    input [34:0] w;
    input [2:0] row;
    begin
      case (row)
        3'd0:    font_row = w[34:30];
        3'd1:    font_row = w[29:25];
        3'd2:    font_row = w[24:20];
        3'd3:    font_row = w[19:15];
        3'd4:    font_row = w[14:10];
        3'd5:    font_row = w[9:5];
        3'd6:    font_row = w[4:0];
        default: font_row = 5'b00000;
      endcase
    end
  endfunction

  // Pixel of a letter drawn at 4x scale in an 8x8-cell box (32x32 px): the
  // letter uses cell columns 1..5 and rows 0..6. Returns {shadow, ink}; the
  // drop shadow is the same bitmap one cell (4 px) right and down.
  function [1:0] text_px;
    input [34:0] w;
    input [2:0] cc, rr;   // cell column / row inside the 32x32 box
    reg [4:0] r_ink, r_shd;
    reg ink, shd;
    begin
      ink   = 1'b0;
      shd   = 1'b0;
      r_ink = font_row(w, rr);
      r_shd = font_row(w, rr - 3'd1);
      if (rr <= 3'd6 && cc >= 3'd1 && cc <= 3'd5) ink = r_ink[3'd5 - cc];
      if (rr >= 3'd1 && cc >= 3'd2 && cc <= 3'd6) shd = r_shd[3'd6 - cc];
      text_px = {shd, ink};
    end
  endfunction

  // Title "SIMON".
  function [4:0] title_code;
    input [2:0] idx;
    begin
      case (idx)
        3'd0:    title_code = CH_S;
        3'd1:    title_code = CH_I;
        3'd2:    title_code = CH_M;
        3'd3:    title_code = CH_O;
        3'd4:    title_code = CH_N;
        default: title_code = CH_SP;
      endcase
    end
  endfunction

  // Message text (line 0 / line 1) and its length in characters.
  function [49:0] msg_word;
    input [2:0] id;
    input line;
    begin
      case (id)
        3'd1:    msg_word = line ? 50'd0 : M_NICE;
        3'd2:    msg_word = line ? 50'd0 : M_GOOD;
        3'd3:    msg_word = line ? 50'd0 : M_EXCEL;
        3'd4:    msg_word = line ? M_REACHED : M_HIGH;
        3'd5:    msg_word = line ? 50'd0 : M_NOPE;
        3'd6:    msg_word = line ? 50'd0 : M_BOBO;
        default: msg_word = 50'd0;
      endcase
    end
  endfunction

  function [3:0] msg_len;
    input [2:0] id;
    input line;
    begin
      case (id)
        3'd1:    msg_len = line ? 4'd0 : 4'd4;   // NICE
        3'd2:    msg_len = line ? 4'd0 : 4'd8;   // GOOD JOB
        3'd3:    msg_len = line ? 4'd0 : 4'd9;   // EXCELLENT
        3'd4:    msg_len = line ? 4'd8 : 4'd10;  // HIGH SCORE / REACHED!
        3'd5:    msg_len = line ? 4'd0 : 4'd5;   // NOPE!
        default: msg_len = 4'd0;
      endcase
    end
  endfunction

  // Character `idx` (0 = first) of a 10-character message word.
  function [4:0] msg_code;
    input [49:0] w;
    input [3:0] idx;
    begin
      case (idx)
        4'd0:    msg_code = w[49:45];
        4'd1:    msg_code = w[44:40];
        4'd2:    msg_code = w[39:35];
        4'd3:    msg_code = w[34:30];
        4'd4:    msg_code = w[29:25];
        4'd5:    msg_code = w[24:20];
        4'd6:    msg_code = w[19:15];
        4'd7:    msg_code = w[14:10];
        4'd8:    msg_code = w[9:5];
        4'd9:    msg_code = w[4:0];
        default: msg_code = 5'd0;
      endcase
    end
  endfunction

endmodule
