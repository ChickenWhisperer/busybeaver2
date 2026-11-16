/*
 * tt_um_chickenwhisperer_bb5 - the 5-state Busy Beaver champion as a Tiny Tapeout tile.
 *
 * Machine: 1RB1LC_1RC1RB_1RD0LE_1LA1LD_1RZ0LA
 * Halts after exactly 47,176,870 steps with 4,098 ones on the tape.
 *
 * The tape lives in an external asynchronous SRAM (16K x 1 bit used; the
 * 14-bit address wraps, so the tape is a ring and the start position does
 * not matter).
 *
 * The input clock runs at twice the step rate. A divide-by-two flop plus
 * flops on the opposite clock edge split every step into four half-periods,
 * so every bus event has a full half-period of margin on both sides:
 *
 *   H0  clk high  address = head, SRAM drives the data pin (read)
 *       -> falling edge: chip latches the symbol while the SRAM still drives
 *   H1  clk low   WE# goes low, SRAM releases the data pin, chip not driving yet
 *   H2  clk high  chip drives the new symbol, WE# still low
 *       -> falling edge: WE# goes high, SRAM latches the symbol
 *   H3  clk low   address and data held (write hold time)
 *       -> rising edge: chip releases the data pin, head moves, state changes
 *
 * WE# comes straight from a flop (glitch-free) and pulses exactly once per
 * step, then stops for good when the machine halts.
 *
 * Wiring
 *   uo_out[7:0]  -> SRAM A7..A0
 *   uio[5:0]     -> SRAM A13..A8
 *   uio[6]      <-> SRAM I/O0   (tape data, bidirectional)
 *   uio[7]       -> SRAM WE#    (also the step counter output)
 *   ui_in[0]     <- CLEAR       (raise to zero the tape; the run starts when it goes low)
 *   ui_in[1]     <- SCAN        (after halt: walk the head right to read out the tape)
 *   SRAM CE# = OE# = GND, unused address pins = GND
 *
 * CLEAR and SCAN go through two-flop synchronizers, so they may change at any
 * time. Raising CLEAR starts a self-timed wipe of all 16,384 cells (32,768
 * clocks). The chip then waits, with WE# quiet, until CLEAR is low, and runs.
 * After reset the machine sits halted until the first CLEAR.
 *
 * Hold CLEAR high for at least 33,000 clocks, then count WE# pulses after it
 * goes low: exactly 47,176,870, then it stops. (If CLEAR is released early the
 * wipe still completes and the run is still correct, but the leftover wipe
 * pulses land after the release.)
 */

`default_nettype none

module tt_um_chickenwhisperer_bb5 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam [2:0] A = 3'd0, B = 3'd1, C = 3'd2, D = 3'd3, E = 3'd4;

    // ---- rising-edge state --------------------------------------------------
    reg        ph;      // divide-by-two: 0 during H0/H1, 1 during H2/H3
    reg [13:0] head;
    reg [2:0]  state;
    reg        halted;
    reg [1:0]  clr_s;   // CLEAR synchronizer
    reg [1:0]  scan_s;  // SCAN synchronizer
    reg        clearing;// wiping the tape
    reg        idle;    // wipe done, waiting for CLEAR to go low
    reg        oe;      // chip drives the data pin (H2/H3 of a writing step)

    // ---- falling-edge state -------------------------------------------------
    reg        sym;     // symbol read from the tape (latched at end of H0)
    reg        we;      // write window (H1/H2 of a writing step)

    // A step writes if the machine is running or wiping the tape.
    // Only registered signals feed the WE# flop.
    wire do_write = clearing | (~idle & ~halted);

    always @(negedge clk) begin
        if (!ph) sym <= uio_in[6];
        we <= rst_n & ~ph & do_write;
    end

    // ---- transition table -----------------------------------------------------
    reg       t_write;
    reg       t_right;
    reg [2:0] t_next;
    reg       t_halt;

    always @(*) begin
        t_write = 1'b1;
        t_right = 1'b1;
        t_next  = A;
        t_halt  = 1'b0;
        case ({state, sym})
            {A, 1'b0}: begin t_write = 1; t_right = 1; t_next = B; end  // 1RB
            {A, 1'b1}: begin t_write = 1; t_right = 0; t_next = C; end  // 1LC
            {B, 1'b0}: begin t_write = 1; t_right = 1; t_next = C; end  // 1RC
            {B, 1'b1}: begin t_write = 1; t_right = 1; t_next = B; end  // 1RB
            {C, 1'b0}: begin t_write = 1; t_right = 1; t_next = D; end  // 1RD
            {C, 1'b1}: begin t_write = 0; t_right = 0; t_next = E; end  // 0LE
            {D, 1'b0}: begin t_write = 1; t_right = 0; t_next = A; end  // 1LA
            {D, 1'b1}: begin t_write = 1; t_right = 0; t_next = D; end  // 1LD
            {E, 1'b0}: begin t_write = 1; t_right = 1; t_next = E; t_halt = 1; end  // 1R HALT
            {E, 1'b1}: begin t_write = 0; t_right = 0; t_next = A; end  // 0LA
            default:   begin t_write = sym; t_next = A; end
        endcase
    end

    // ---- head / state -----------------------------------------------------------
    wire clr = clr_s[1];

    always @(posedge clk) begin
        clr_s  <= {clr_s[0],  ui_in[0]};
        scan_s <= {scan_s[0], ui_in[1]};
        if (!rst_n) begin
            ph       <= 1'b0;
            head     <= 14'd0;
            state    <= A;
            halted   <= 1'b1;         // do nothing until the first CLEAR
            clearing <= 1'b0;
            idle     <= 1'b0;
            oe       <= 1'b0;
        end else begin
            ph <= ~ph;
            oe <= we;                 // on at start of H2, off at end of H3
            if (ph) begin             // end of H3: commit the step
                if (clearing) begin                  // wrote a 0 at head
                    head <= head + 14'd1;
                    if (head == 14'h3FFF) begin
                        clearing <= 1'b0;
                        idle     <= 1'b1;
                    end
                end else if (idle) begin             // wait for CLEAR low, then start in state A
                    state  <= A;
                    halted <= 1'b0;
                    if (!clr) idle <= 1'b0;
                end else if (clr) begin              // start a wipe
                    clearing <= 1'b1;
                    head     <= 14'd0;
                end else if (halted) begin
                    if (scan_s[1]) head <= head + 14'd1;
                end else begin                       // one Turing-machine step
                    head   <= t_right ? head + 14'd1 : head - 14'd1;
                    state  <= t_next;
                    halted <= t_halt;
                end
            end
        end
    end

    // ---- pins -----------------------------------------------------------------------
    wire wdata = clearing ? 1'b0 : t_write;

    assign uo_out  = head[7:0];
    assign uio_out = {~we, wdata, head[13:8]};
    assign uio_oe  = {1'b1, oe, 6'b111111};

    wire _unused = &{ena, ui_in[7:2], uio_in[7], uio_in[5:0], 1'b0};

endmodule
