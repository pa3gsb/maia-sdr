`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// Self-checking regression testbench for cs12_8mux CS12 (12-bit) packing.
//
// Run:
//   iverilog -g2012 -o /tmp/cs12_tb \
//       maia-hdl/projects/common/tb/cs12_cs8mux_tb.v \
//       maia-hdl/projects/common/cs12_cs8mux.v
//   vvp /tmp/cs12_tb        # prints "CS12 PACKING TEST: PASS" / "... FAIL"
//
// Drives a 12-bit ramp into CS12 mode (Enable0=0, Enable1=1), reconstructs the
// samples from the packed output and asserts the stream is a clean, in-order
// ramp. Bytes within each 16-bit word are swapped before reconstruction to match
// the little-endian AD9361/DMA byte order (the same convention as the 3-byte
// Python unpacker used to validate captures).
//
// Guards against the burst_pending mid-pack regression: clearing burst_pending
// at out_count==0 (instead of ==5) lets valid_out drop mid-burst, flips the
// ping-pong active_buffer while a pack is still draining, and scrambles every
// sample. That failure shows up here as 100% sample mismatches.
// -----------------------------------------------------------------------------
module cs12_cs8mux_tb;
  reg clk = 0, rst_n = 0;
  reg [15:0] I0 = 0, Q0 = 0;
  reg valid_in = 0, Enable0 = 0, Enable1 = 0, zero_count = 0, streaming = 0;
  wire [15:0] data_out0, data_out1;
  wire valid_out, burst_sync, frame_start, Enable_O1, Enable_O2;

  cs12_8mux #(.DATA_WIDTH(16)) dut (
    .clk(clk), .rst_n(rst_n), .I0(I0), .Q0(Q0), .valid_in(valid_in),
    .Enable0(Enable0), .Enable1(Enable1), .zero_count(zero_count),
    .data_out0(data_out0), .data_out1(data_out1), .valid_out(valid_out),
    .burst_sync(burst_sync), .frame_start(frame_start),
    .Enable_O1(Enable_O1), .Enable_O2(Enable_O2));

  always #5 clk = ~clk;

  function [15:0] bswap(input [15:0] x); bswap = {x[7:0], x[15:8]}; endfunction

  integer kcount = 0;
  always @(negedge clk) if (streaming) begin
    I0 = {4'h0, kcount[11:0]}; Q0 = {4'h0, kcount[11:0]}; kcount = kcount + 1;
  end

  reg [95:0] acc = 0;
  integer wc = 0, pack_no = -1, checked = 0, errors = 0, prev = 0, j;
  reg started = 0;
  reg [11:0] sample;

  always @(posedge clk) if (rst_n && valid_out) begin
    if (frame_start) begin pack_no = pack_no + 1; wc = 0; acc = 0; end
    acc = (acc << 16) | bswap(data_out0);
    wc  = wc + 1;
    if (wc == 6) begin
      for (j = 0; j < 8; j = j + 1) begin
        sample = acc[12*(7-j) +: 12];
        if (pack_no >= 1) begin                 // skip first pack (sync edge)
          if (!started) started = 1;
          else begin
            checked = checked + 1;
            if (sample != ((prev + 1) & 12'hFFF)) begin
              errors = errors + 1;
              $display("  MISMATCH pack=%0d sample#%0d got=%0d expected=%0d",
                       pack_no, j, sample, (prev + 1) & 12'hFFF);
            end
          end
          prev = sample;
        end
      end
    end
  end

  initial begin
    rst_n = 0; repeat (4) @(posedge clk);
    rst_n = 1;          @(posedge clk);
    Enable1 = 1;
    zero_count = 1;     @(posedge clk);
    zero_count = 0; streaming = 1; valid_in = 1;
    repeat (200) @(posedge clk);
    $display("CS12 self-check: %0d samples checked, %0d errors", checked, errors);
    if (errors == 0 && checked >= 64) $display("CS12 PACKING TEST: PASS");
    else begin $display("CS12 PACKING TEST: FAIL"); $fatal(1, "CS12 regression detected"); end
    $finish;
  end
endmodule
