`default_nettype none
`timescale 1ns / 1ps

/* This testbench instantiates the module together with a behavioural model of
   the external asynchronous SRAM that holds the tape. The cocotb test.py drives
   clk, rst_n and ui_in and watches the SRAM bus.
*/
module tb ();

  // Dump the signals to a FST file. You can view it with gtkwave or surfer.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  wire [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  tt_um_chickenwhisperer_bb5 user_project (

      // Include power ports for the Gate Level test:
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif

      .ui_in  (ui_in),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

  // ---- external SRAM model (16K x 1, CE# = OE# = GND) ----------------------
  // The data bus is X whenever nobody drives it, so the design cannot pass by
  // relying on the wire remembering its last value.
  reg mem[0:16383];
  integer i;
  initial for (i = 0; i < 16384; i = i + 1) mem[i] = $random;  // power-up garbage

  wire [13:0] addr    = {uio_out[5:0], uo_out};
  wire        we_n    = uio_out[7];
  wire        chip_oe = uio_oe[6];
  wire        bus     = chip_oe ? uio_out[6] : (we_n ? mem[addr] : 1'bx);

  assign uio_in = {1'b0, bus, 6'b000000};

  always @(posedge we_n) mem[addr] <= bus;

  // Everything the test needs at the end of a write, in one vector:
  // {chip is driving, data bit, address}
  wire [15:0] mon = {chip_oe, uio_out[6], addr};

  // Chip must never drive the bus while the SRAM is being read into it:
  // flag any moment the chip drives before WE# has gone low in this step.
  reg we_seen;
  reg contention;
  initial begin we_seen = 0; contention = 0; end
  always @(negedge we_n) we_seen <= 1;
  always @(negedge chip_oe) we_seen <= 0;
  always @(posedge chip_oe) if (!we_seen && rst_n === 1'b1) contention <= 1;

endmodule
