`default_nettype none
`timescale 1ns / 1ps

module tb ();

  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  // Use tiny frame-based game timings in RTL simulation so the game FSM
  // can be exercised without waiting through the real 0.8 s boot/reveal
  // delays. These parameters do not change the silicon defaults.
  tt_um_vga_example #(
      .BOOT_FRAMES(16'd0),
      .SHOW_GAP_FRAMES(16'd0),
      .BASE_SHOW_FRAMES(16'd0),
      .MIN_SHOW_FRAMES(16'd0),
      .ROUND_OK_FRAMES(16'd0),
      .INPUT_TIMEOUT_FRAMES(16'd3),
      .FEEDBACK_FRAMES(16'd0),
      .MISS_FLASH_FRAMES(16'd1)
  ) user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule
