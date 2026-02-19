// =============================================================================
// Module  : vctcxo_pll_core
// Purpose : GPS-disciplined VCTCXO PLL, jitter-immune frequency counter method.
//
// Why the XOR duty-cycle method failed :
//   The GPS NEO-M8N 100kHz output has ±100-500ns cycle-to-cycle jitter.
//   At 10MHz sampling this is ±1-5 ticks per period.
//   The XOR duty cycle varies by ±5-10% per period from jitter alone,
//   which is larger than the lock window → permanent hunt/unlock.
//
// Solution : frequency difference counter over a LONG gate time.
//   - Count VCTCXO 10MHz ticks between N GPS edges (gate = N × 10µs).
//   - Expected count = N × 100 ticks exactly when frequencies match.
//   - freq_error = measured_count - (N × 100)
//   - This averages out GPS jitter over N periods : jitter effect = jitter/N.
//   - With N=1000 : ±500ns jitter → ±0.05 tick error → sub-tick resolution.
//
// Phase detector :
//   The XOR is still used as the error signal driving the RC filter.
//   The frequency counter only drives the lock detector.
//   This keeps the analog loop intact while making lock detection robust.
//
// Lock condition :
//   |freq_error| <= LOCK_FREQ_TOL for LOCK_COUNT_MAX consecutive gate windows.
//
// Parameters :
//   GATE_PERIODS    : GPS periods per frequency measurement (default 1000 = 10ms)
//   LOCK_FREQ_TOL   : frequency error tolerance in 10MHz ticks over gate window
//                     default 2 ticks over 1000 periods = 0.2 tick/period = 2ppm
//   LOCK_COUNT_MAX  : consecutive good windows to declare lock (default 100 = 1s)
// =============================================================================

module vctcxo_pll_core (
    input  wire clk_10mhz,    // 10MHz from VCTCXO (feedback)
    input  wire sig_100khz,   // 100kHz from GPS (reference, asynchronous)
    input  wire reset,        // System reset (active high)
    output wire phase_out,    // XOR → RC filter → VCXO_TUNE (unchanged)
    output wire lock_ind,     // Lock indicator (LOW = locked)
    output wire clk_100khz    // 100kHz divided clock
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------

    // Gate time : number of GPS 100kHz periods to count over.
    // 1000 periods = 10ms gate. Jitter ±500ns / 1000 = ±0.0005 tick average.
    parameter GATE_PERIODS   = 16'd1000;

    // Expected tick count per gate = GATE_PERIODS * 100
    // For GATE_PERIODS=1000 : expected = 100,000 ticks
    parameter EXPECTED_COUNT = 20'd100_000;  // Must match GATE_PERIODS * 100

    // Lock frequency tolerance in ticks over full gate window.
    // 2 ticks over 100,000 = 2ppm frequency error tolerance.
    parameter LOCK_FREQ_TOL  = 20'd2;

    // Consecutive good gate windows to declare lock.
    // 100 windows × 10ms = 1s confirmation time.
    parameter LOCK_COUNT_MAX = 7'd100;

    // =========================================================================
    // 1. FREQUENCY DIVIDER : 10MHz → 100kHz
    // =========================================================================
    reg [6:0] div_count;
    reg       ref_100khz;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            div_count  <= 7'd0;
            ref_100khz <= 1'b0;
        end else begin
            if (div_count == 7'd49) begin
                div_count  <= 7'd0;
                ref_100khz <= ~ref_100khz;
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

    assign clk_100khz = ref_100khz;

    // =========================================================================
    // 2. SYNCHRONISER
    // =========================================================================
    reg [2:0] sync_reg;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset)
            sync_reg <= 3'd0;
        else
            sync_reg <= {sync_reg[1:0], sig_100khz};
    end

    wire ref_gps = sync_reg[2];

    // =========================================================================
    // 3. XOR PHASE DETECTOR
    //    Drives RC filter → VCXO_TUNE directly. Unchanged from original.
    //    This is the analog correction path.
    // =========================================================================
    assign phase_out = ref_100khz ^ ref_gps;

    // =========================================================================
    // 4. FREQUENCY DIFFERENCE COUNTER
    //
    //    Counts 10MHz ticks between GPS rising edges.
    //    Accumulates over GATE_PERIODS GPS edges.
    //    At end of gate : compare accumulated count to EXPECTED_COUNT.
    //
    //    tick_acc    : running count of 10MHz ticks in current gate
    //    gps_edge_cnt: number of GPS edges counted in current gate
    //    freq_error  : signed difference from expected at gate end
    //    gate_done   : pulses when a new freq_error is available
    // =========================================================================
    reg        gps_prev;
    reg [19:0] tick_acc;       // Tick accumulator (max 100000+margin, 20 bits)
    reg [15:0] gps_edge_cnt;   // GPS edge counter within gate
    reg signed [20:0] freq_error;  // Signed frequency error (21 bits for sign)
    reg        gate_done;      // Pulses when gate measurement complete

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            gps_prev     <= 1'b0;
            tick_acc     <= 20'd0;
            gps_edge_cnt <= 16'd0;
            freq_error   <= 21'd0;
            gate_done    <= 1'b0;
        end else begin
            gps_prev  <= ref_gps;
            gate_done <= 1'b0;

            // Always count 10MHz ticks
            tick_acc <= tick_acc + 1'b1;

            // GPS rising edge detected
            if (ref_gps && !gps_prev) begin
                if (gps_edge_cnt == GATE_PERIODS - 1) begin
                    // Gate complete : compute signed frequency error
                    // positive = VCTCXO running fast (too many ticks)
                    // negative = VCTCXO running slow (too few ticks)
                    freq_error   <= $signed({1'b0, tick_acc})
                                  - $signed({1'b0, EXPECTED_COUNT});
                    tick_acc     <= 20'd0;
                    gps_edge_cnt <= 16'd0;
                    gate_done    <= 1'b1;
                end else begin
                    gps_edge_cnt <= gps_edge_cnt + 1'b1;
                end
            end
        end
    end

    // Absolute frequency error for lock comparison
    wire [19:0] freq_abs = freq_error[20] ? (~freq_error[19:0] + 1'b1)
                                           : freq_error[19:0];

    // =========================================================================
    // 5. LOCK DETECTOR
    //    Uses frequency counter result, not XOR duty cycle.
    //    Immune to GPS 100kHz jitter because error is averaged over gate.
    //
    //    lock_count increments on each gate window where freq_abs <= tolerance.
    //    Resets immediately on any out-of-tolerance window.
    //    lock_ind asserts (low) after LOCK_COUNT_MAX consecutive good windows.
    // =========================================================================
    reg [6:0] lock_count;
    reg       locked;

    wire freq_ok = (freq_abs <= LOCK_FREQ_TOL);

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            lock_count <= 7'd0;
            locked     <= 1'b0;
        end else if (gate_done) begin
            if (freq_ok) begin
                if (lock_count < LOCK_COUNT_MAX)
                    lock_count <= lock_count + 1'b1;
                if (lock_count == LOCK_COUNT_MAX - 1)
                    locked <= 1'b1;
            end else begin
                lock_count <= 7'd0;
                locked     <= 1'b0;
            end
        end
    end

    // Active low to match original interface
    assign lock_ind = ~locked;

endmodule