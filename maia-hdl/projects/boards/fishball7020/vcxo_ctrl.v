// =============================================================================
// Module  : vctcxo_pll_core  (GPS glitch filter)
// Purpose : GPS-disciplined VCTCXO PLL.
//
// Problem fixed :
//   Scope showed one rogue narrow pulse on XOR output per ~100ms → 10Hz wobble.
//   Root cause : NEO-M8N 100kHz timepulse occasionally emits a very short
//   spurious glitch pulse (known hardware behaviour). This glitch propagates
//   through the synchroniser, causes one false XOR toggle, which produces
//   a voltage spike on VCXO_TUNE through the RC filter → 10Hz frequency jump.
//
// Fix : minimum pulse width filter on sig_100khz input.
//   A GPS edge is only accepted if the signal stays high for at least
//   MIN_PULSE_TICKS consecutive 10MHz clock cycles.
//   Genuine 100kHz pulses : high for 50 ticks (5µs) → accepted
//   Rogue glitch pulses   : high for 1-3 ticks    → rejected
//
//   MIN_PULSE_TICKS = 20 : rejects pulses shorter than 2µs
//   This is safe : genuine 100kHz has 5µs high time, glitches are <200ns.
// =============================================================================

module vctcxo_pll_core (
    input  wire clk_10mhz,
    input  wire sig_100khz,
    input  wire reset,
    output wire phase_out,
    output wire lock_ind,
    output wire clk_100khz
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter GATE_PERIODS    = 16'd1000;
    parameter EXPECTED_COUNT  = 20'd100_000;
    parameter LOCK_FREQ_TOL   = 20'd2;
    parameter LOCK_COUNT_MAX  = 7'd100;
    parameter ALIGN_OFFSET    = 7'd0;

    // Minimum pulse width to accept a GPS edge (in 10MHz ticks)
    // Genuine 100kHz pulse : 50 ticks high (5µs)
    // Glitch pulse         : 1-3 ticks    (<300ns)
    // MIN_PULSE_TICKS=40   : rejects anything below 2µs → wider margin
    parameter MIN_PULSE_TICKS = 5'd20;

    // =========================================================================
    // 1. INPUT SYNCHRONISER (3-stage)
    // =========================================================================
    reg [2:0] sync_reg;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset)
            sync_reg <= 3'd0;
        else
            sync_reg <= {sync_reg[1:0], sig_100khz};
    end

    wire sig_sync = sync_reg[2];  // Synchronised but unfiltered GPS signal

    // =========================================================================
    // 2. GLITCH FILTER
    //    Counts consecutive high ticks on sig_sync.
    //    ref_gps only goes high after MIN_PULSE_TICKS consecutive high ticks.
    //    ref_gps goes low immediately when sig_sync goes low.
    //    This rejects short glitch pulses while passing genuine 100kHz edges.
    // =========================================================================
    reg [4:0]  pulse_cnt;    // Counts consecutive high ticks (0..MIN_PULSE_TICKS)
    reg        ref_gps;      // Filtered GPS signal

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            pulse_cnt <= 5'd0;
            ref_gps   <= 1'b0;
        end else begin
            if (sig_sync) begin
                // Signal high : count up to threshold
                if (pulse_cnt < MIN_PULSE_TICKS)
                    pulse_cnt <= pulse_cnt + 1'b1;
                // Assert ref_gps once threshold reached
                if (pulse_cnt == MIN_PULSE_TICKS - 1)
                    ref_gps <= 1'b1;
            end else begin
                // Signal low : reset counter and deassert immediately
                pulse_cnt <= 5'd0;
                ref_gps   <= 1'b0;
            end
        end
    end

    // Delayed ref_gps for edge detection
    reg ref_gps_prev;
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset)
            ref_gps_prev <= 1'b0;
        else
            ref_gps_prev <= ref_gps;
    end

    wire gps_rise = ref_gps && !ref_gps_prev;

    // =========================================================================
    // 3. PHASE-ALIGNED FREQUENCY DIVIDER : 10MHz → 100kHz
    // =========================================================================
    reg [6:0] div_count;
    reg       ref_100khz;
    reg       aligned;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            div_count  <= 7'd0;
            ref_100khz <= 1'b0;
            aligned    <= 1'b0;
        end else begin
            if (!aligned && gps_rise) begin
                div_count  <= ALIGN_OFFSET;
                ref_100khz <= 1'b0;
                aligned    <= 1'b1;
            end else if (aligned) begin
                if (div_count == 7'd99) begin
                    div_count  <= 7'd0;
                    ref_100khz <= ~ref_100khz;
                end else begin
                    if (div_count == 7'd49)
                        ref_100khz <= ~ref_100khz;
                    div_count <= div_count + 1'b1;
                end
            end
        end
    end

    assign clk_100khz = ref_100khz;

    // =========================================================================
    // 4. XOR PHASE DETECTOR - DIRECT OUTPUT
    //    ref_gps is now glitch-filtered → no rogue pulses → no XOR spikes
    //    → no VCXO_TUNE voltage spikes → no 10Hz wobble.
    // =========================================================================
    assign phase_out = aligned ? (ref_100khz ^ ref_gps) : 1'b0;

    // =========================================================================
    // 5. FREQUENCY DIFFERENCE COUNTER
    // =========================================================================
    reg        gps_prev2;
    reg [19:0] tick_acc;
    reg [15:0] gps_edge_cnt;
    reg signed [20:0] freq_error;
    reg        gate_done;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            gps_prev2    <= 1'b0;
            tick_acc     <= 20'd0;
            gps_edge_cnt <= 16'd0;
            freq_error   <= 21'd0;
            gate_done    <= 1'b0;
        end else begin
            gps_prev2 <= ref_gps;
            gate_done <= 1'b0;
            tick_acc  <= tick_acc + 1'b1;

            if (gps_rise) begin
                if (gps_edge_cnt == GATE_PERIODS - 1) begin
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

    wire [19:0] freq_abs = freq_error[20]
                           ? (~freq_error[19:0] + 1'b1)
                           : freq_error[19:0];

    // =========================================================================
    // 6. LOCK DETECTOR
    // =========================================================================
    reg [6:0] lock_count;
    reg       locked;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            lock_count <= 7'd0;
            locked     <= 1'b0;
        end else if (gate_done) begin
            if (freq_abs <= LOCK_FREQ_TOL) begin
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

    assign lock_ind = locked;

endmodule