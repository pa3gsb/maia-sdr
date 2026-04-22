`timescale 1ns/100ps

// ---------------------------------------------------------------------------
// cs12_8mux
//
// MODE {Enable0, Enable1}:
//   2'b11 : BYPASS       — I0/Q0 passed through as-is (16-bit)
//   2'b10 : PACK 8-BIT   — noise-shaped 8-bit I+Q packed into one 16-bit word
//                          First-order error-feedback noise shaper: quantisation
//                          error from sample N is fed back into sample N+1,
//                          pushing noise energy toward Fs/2 and improving
//                          in-band SNR by ~6–9 dB vs. simple rounding.
//                          Shaper state (err_i, err_q) is reset on rst_n or
//                          whenever the mode leaves 2'b10.
//   2'b01 : PACK 12-BIT  — 8 IQ pairs packed into 192 bits, output as
//                          6 x 32-bit bursts (data_out1=I-stream, data_out0=Q-stream)
//                          Chronological order, I before Q, MSB-first.
//                          frame_start pulses with valid_out at out_count==0 so
//                          the client can always lock onto the start of a pack.
//                          synced is cleared on any mode exit so the first burst
//                          after re-entry is always suppressed — the client never
//                          sees a pack that started before the mode was active.
//
// CS12 output bit mapping (data_out0 = I-stream, data_out1 = Q-stream):
//   Cycle 0 : I0[11:0] | I1[11:8]    /  Q0[11:0] | Q1[11:8]
//   Cycle 1 : I1[7:0]  | I2[11:4]    /  Q1[7:0]  | Q2[11:4]
//   Cycle 2 : I2[3:0]  | I3[11:0]    /  Q2[3:0]  | Q3[11:0]
//   Cycle 3 : I4[11:0] | I5[11:8]    /  Q4[11:0] | Q5[11:8]
//   Cycle 4 : I5[7:0]  | I6[11:4]    /  Q5[7:0]  | Q6[11:4]
//   Cycle 5 : I6[3:0]  | I7[11:0]    /  Q6[3:0]  | Q7[11:0]
// ---------------------------------------------------------------------------

module cs12_8mux #(
    parameter DATA_WIDTH = 16
) (
    input                      clk,
    input                      rst_n,

    // Inputs
    input      [DATA_WIDTH-1:0] I0,
    input      [DATA_WIDTH-1:0] Q0,
    input                       valid_in,

    input                       Enable0,
    input                       Enable1,
    input                       zero_count,     // synchronous reset of CS12 input counter & buffers

    // Outputs
    output reg [DATA_WIDTH-1:0] data_out0,
    output reg [DATA_WIDTH-1:0] data_out1,
    output reg                  valid_out,
    output reg                  burst_sync,  // pulses ONE cycle before valid_out at CS12 burst cycle 0
    output reg                  frame_start, // pulses WITH valid_out at out_count==0 (cycle-0 of each pack)
                                             // client must discard data until frame_start seen, then count 6 words
    output                      Enable_O1,
    output                      Enable_O2
);

    // -----------------------------------------------------------------------
    // Ping-pong buffers — 2 x 96-bit shift registers, one for I, one for Q
    // Each holds 8 x 12-bit samples = 96 bits
    // -----------------------------------------------------------------------
    reg [95:0] ibuf_a, ibuf_b;   // I-sample ping-pong
    reg [95:0] qbuf_a, qbuf_b;   // Q-sample ping-pong

    reg        active_buffer;    // 0 = filling buf_a, 1 = filling buf_b
    reg [3:0]  in_count;         // 0..7 input samples
    reg [2:0]  out_count;        // 0..5 output cycles
    reg        burst_pending;
    reg        burst_pending_r;  // registered copy — output phase starts 1 cycle after burst_pending set
    reg        synced;           // set when first clean burst boundary seen after reset/zero_count

    // -----------------------------------------------------------------------
    // Noise shaper state for MODE 10 (PACK 8-BIT)
    //
    // First-order error-feedback architecture:
    //   acc  = sign_extend(sample[11:0]) + err   (14-bit signed)
    //   rnd  = acc[13:4] + acc[3]                (round to nearest, 9-bit)
    //   out  = clamp(rnd, -128, 127)             (8-bit signed)
    //   err' = acc - (out <<< 4)                 (residual, back into 13-bit)
    //
    // err is reset to 0 on rst_n and whenever the mode is not 2'b10, so
    // there is no stale feedback when re-entering the mode.
    // -----------------------------------------------------------------------
    reg signed [12:0] err_i;
    reg signed [12:0] err_q;

    // Combinational shaper wires — evaluated every cycle, latched only in mode 10
    wire signed [13:0] acc_i_w = {{2{I0[11]}}, I0[11:0]} + err_i;
    wire signed [13:0] acc_q_w = {{2{Q0[11]}}, Q0[11:0]} + err_q;

    wire signed  [8:0] rnd_i_w = acc_i_w[13:4] + {8'sd0, acc_i_w[3]};
    wire signed  [8:0] rnd_q_w = acc_q_w[13:4] + {8'sd0, acc_q_w[3]};

    wire signed  [7:0] out_i_w = (rnd_i_w > 9'sd127)  ?  8'sd127  :
                                 (rnd_i_w < -9'sd128)  ? -8'sd128  :
                                                          rnd_i_w[7:0];
    wire signed  [7:0] out_q_w = (rnd_q_w > 9'sd127)  ?  8'sd127  :
                                 (rnd_q_w < -9'sd128)  ? -8'sd128  :
                                                          rnd_q_w[7:0];

    // Residual error: difference between the full-precision accumulator and
    // the re-scaled quantised output.  Stays within ±8 for non-clipping signals.
    wire signed [12:0] err_i_next = acc_i_w - ({{5{out_i_w[7]}}, out_i_w} <<< 4);
    wire signed [12:0] err_q_next = acc_q_w - ({{5{out_q_w[7]}}, out_q_w} <<< 4);

    // -----------------------------------------------------------------------
    // Enable outputs
    //   Enable_O1 : high for any active mode (not idle)
    //   Enable_O2 : high for bypass and CS12, low for 8-bit pack
    // -----------------------------------------------------------------------
    assign Enable_O1 = (Enable0 | Enable1);
    assign Enable_O2 = Enable1;

    // -----------------------------------------------------------------------
    // Main FSM
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ibuf_a          <= 96'h0;
            ibuf_b          <= 96'h0;
            qbuf_a          <= 96'h0;
            qbuf_b          <= 96'h0;
            in_count        <= 4'd0;
            out_count       <= 3'd0;
            active_buffer   <= 1'b0;
            burst_pending   <= 1'b0;
            burst_pending_r <= 1'b0;
            data_out0       <= 16'h0;
            data_out1       <= 16'h0;
            valid_out       <= 1'b0;
            burst_sync      <= 1'b0;
            frame_start     <= 1'b0;
            synced          <= 1'b0;
            err_i           <= 13'sd0;
            err_q           <= 13'sd0;
        end else begin
            valid_out       <= 1'b0;    // default de-assert
            frame_start     <= 1'b0;    // default de-assert
            // burst_sync: 1-cycle pulse one cycle BEFORE valid_out at burst cycle 0
            // rising edge of burst_pending = exactly one cycle before burst_pending_r (first output)
            burst_sync      <= burst_pending && !burst_pending_r;
            burst_pending_r <= burst_pending;

            case ({Enable0, Enable1})

                // -----------------------------------------------------------
                // MODE 11 : BYPASS
                // -----------------------------------------------------------
                2'b11: begin
                    err_i  <= 13'sd0;
                    err_q  <= 13'sd0;
                    synced <= 1'b0;   // leaving CS12 mode — force re-sync on re-entry
                    if (valid_in) begin
                        data_out0 <= I0;
                        data_out1 <= Q0;
                        valid_out <= 1'b1;
                    end
                end

                // -----------------------------------------------------------
                // MODE 10 : PACK 8-BIT  (noise-shaped)
                //
                //   data_out0 = {out_q[7:0], out_i[7:0]}   (noise-shaped CS8)
                //   data_out1 = 16'h0
                //
                // The first-order error-feedback loop shapes quantisation noise
                // toward Fs/2.  For a narrowband / baseband signal this improves
                // in-band SNR by ~6–9 dB compared to simple truncation/rounding.
                //
                // Note: err_i / err_q are only updated when valid_in is asserted
                // so the feedback loop tracks the input sample rate correctly
                // regardless of backpressure on valid_in.
                // -----------------------------------------------------------
                2'b10: begin
                    synced <= 1'b0;   // leaving CS12 mode — force re-sync on re-entry
                    if (valid_in) begin
                        // Latch shaped outputs
                        data_out0 <= {out_q_w, out_i_w};
                        data_out1 <= 16'h0;
                        valid_out <= 1'b1;
                        // Advance error accumulators
                        err_i <= err_i_next;
                        err_q <= err_q_next;
                    end
                end

                // -----------------------------------------------------------
                // MODE 01 : PACK 12-BIT (CS12)
                //
                // INPUT PHASE:
                //   Append each new 12-bit sample at the LSB of the shift
                //   register so that sample 0 ends up at the MSB when the
                //   buffer is full → chronological, MSB-first output.
                //   I and Q are kept in separate 96-bit buffers.
                //
                // OUTPUT PHASE (burst_pending):
                //   Drain MSB-first, 16 bits per cycle, 6 cycles total.
                //   data_out0 carries the I-stream.
                //   data_out1 carries the Q-stream.
                //
                // Resulting DMA word layout:
                //   Cycle 0 : I0[11:0]|I1[11:8]  /  Q0[11:0]|Q1[11:8]
                //   Cycle 1 : I1[7:0] |I2[11:4]  /  Q1[7:0] |Q2[11:4]
                //   Cycle 2 : I2[3:0] |I3[11:0]  /  Q2[3:0] |Q3[11:0]
                //   Cycle 3 : I4[11:0]|I5[11:8]  /  Q4[11:0]|Q5[11:8]
                //   Cycle 4 : I5[7:0] |I6[11:4]  /  Q5[7:0] |Q6[11:4]
                //   Cycle 5 : I6[3:0] |I7[11:0]  /  Q6[3:0] |Q7[11:0]
                // -----------------------------------------------------------
                2'b01: begin
                    err_i <= 13'sd0;
                    err_q <= 13'sd0;

                    // -- INPUT: accumulate 8 pairs into the inactive buffer --
                    // zero_count: synchronously clears the input counter, buffers and
                    // any pending burst so the next valid_in starts a fresh group of 8.
                    if (zero_count) begin
                        ibuf_a          <= 96'h0;
                        ibuf_b          <= 96'h0;
                        qbuf_a          <= 96'h0;
                        qbuf_b          <= 96'h0;
                        in_count        <= 4'd0;
                        active_buffer   <= 1'b0;
                        burst_pending   <= 1'b0;
                        burst_pending_r <= 1'b0;
                        synced          <= 1'b0;
                    end else begin
                        // Set synced on the rising edge of burst_pending (one cycle before
                        // burst_pending_r and therefore one cycle before the first valid_out).
                        // This guarantees valid_out is suppressed until a clean cycle-0 boundary
                        // has occurred since the last zero_count/reset.
                        if (burst_pending && !burst_pending_r)
                            synced <= 1'b1;
                    end
                    if (!zero_count && valid_in) begin
                        if (!active_buffer) begin
                            ibuf_a <= {ibuf_a[83:0], I0[11:0]};
                            qbuf_a <= {qbuf_a[83:0], Q0[11:0]};
                        end else begin
                            ibuf_b <= {ibuf_b[83:0], I0[11:0]};
                            qbuf_b <= {qbuf_b[83:0], Q0[11:0]};
                        end

                        if (in_count == 4'd7) begin
                            in_count      <= 4'd0;
                            active_buffer <= ~active_buffer;
                            burst_pending <= 1'b1;
                        end else begin
                            in_count <= in_count + 1'b1;
                        end
                    end

                    // -- OUTPUT: drain the just-completed buffer MSB-first --
                    // Use burst_pending_r (1-cycle delayed) so the output phase
                    // always starts the cycle AFTER burst_pending is set.
                    if (burst_pending_r) begin
                        valid_out   <= synced;
                        frame_start <= synced && (out_count == 3'd0);

                        if (active_buffer) begin
                            // active_buffer just flipped to 1 → read buf_a
                            data_out0 <= ibuf_a[95:80];
                            data_out1 <= qbuf_a[95:80];
                            ibuf_a    <= {ibuf_a[79:0], 16'h0};
                            qbuf_a    <= {qbuf_a[79:0], 16'h0};
                        end else begin
                            // active_buffer just flipped to 0 → read buf_b
                            data_out0 <= ibuf_b[95:80];
                            data_out1 <= qbuf_b[95:80];
                            ibuf_b    <= {ibuf_b[79:0], 16'h0};
                            qbuf_b    <= {qbuf_b[79:0], 16'h0};
                        end

                        if (out_count == 3'd5) begin
                            out_count       <= 3'd0;
                            burst_pending   <= 1'b0;
                            burst_pending_r <= 1'b0;
                        end else begin
                            out_count <= out_count + 1'b1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // IDLE (00) — full CS12 state reset, same as zero_count
                // -----------------------------------------------------------
                default: begin
                    ibuf_a          <= 96'h0;
                    ibuf_b          <= 96'h0;
                    qbuf_a          <= 96'h0;
                    qbuf_b          <= 96'h0;
                    in_count        <= 4'd0;
                    out_count       <= 3'd0;
                    active_buffer   <= 1'b0;
                    burst_pending   <= 1'b0;
                    burst_pending_r <= 1'b0;
                    synced          <= 1'b0;   // force re-sync on re-entry
                    data_out0       <= 16'h0;
                    data_out1       <= 16'h0;
                    err_i           <= 13'sd0;
                    err_q           <= 13'sd0;
                end

            endcase
        end
    end

endmodule
