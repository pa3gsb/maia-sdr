// =============================================================================
// Module  : vctcxo_pll_core
// Purpose : GPS-disciplined VCTCXO PLL - clean minimal implementation.
//
// Design philosophy : simple, traceable, no hidden state interactions.
//
// Signal flow :
//   GPS 1PPS → tick counter → freq_error (once per second)
//                ↓
//   State : WAIT_REF → COARSE → FINE
//                ↓
//   COARSE : integrator += freq_error × COARSE_GAIN  (direct freq correction)
//   FINE   : integrator += freq_error × FINE_GAIN    (slow fine correction)
//                ↓
//   integrator[23:8] = sd_setpoint (16 bits, 0..65535)
//                ↓
//   PWM 8-bit + dither → phase_out → RC → VCXO_TUNE
//
// No phase detector in this version - pure frequency loop.
// Frequency loop is sufficient for GPSDO - phase aligns naturally.
//
// Debug : all key signals exposed on dbg_ ports.
// =============================================================================

module vctcxo_pll_core (
    input  wire        clk_10mhz,
    input  wire        sig_pps,
    input  wire        reset,
    output wire        phase_out,
    output wire        lock_ind,

    // Debug
    output wire [1:0]             dbg_state,
    output wire signed [24:0]     dbg_freq_error,
    output wire [15:0]            dbg_setpoint,
    output wire                   dbg_valid_pps,
    output wire signed [23:0]     dbg_integrator
);

    // -------------------------------------------------------------------------
    // Parameters - tune these for your hardware
    // -------------------------------------------------------------------------

    // Expected ticks per PPS period at 10MHz
    localparam EXPECTED = 25'd10_000_000;

    // COARSE : fast correction, large gain
    // Each PPS : integrator += freq_error << COARSE_SHIFT
    // COARSE_SHIFT=4 : gain=16. At 115 ticks error → step=1840 on integrator
    // integrator is 24 bits, sd_setpoint = integrator[23:8]
    // step on sd_setpoint = 1840>>8 = 7 → noticeable PWM change ✅
    parameter COARSE_SHIFT = 4'd6;

    // Exit COARSE when |freq_error| < COARSE_TOL for COARSE_CONFIRM pulses
    parameter COARSE_TOL     = 20'd500;  // 500 ticks = 50ppm
    parameter COARSE_CONFIRM = 3'd3;     // 3 consecutive seconds

    // FINE : slow correction, small gain
    // FINE_SHIFT=1 : gain=2. Tracks slow thermal drift without overshoot.
    parameter FINE_SHIFT = 4'd0;  // gain=1, very slow

    // Lock : |freq_error| < LOCK_TOL for LOCK_CONFIRM pulses
    parameter LOCK_TOL     = 20'd10;    // 10 ticks = 1ppm
    parameter LOCK_CONFIRM = 4'd5;      // 5 seconds

    // Glitch filter on PPS input
    parameter MIN_PULSE = 5'd20;        // 20 ticks = 2µs minimum pulse

    // =========================================================================
    // 1. PPS INPUT SYNC + GLITCH FILTER
    // =========================================================================
    reg [2:0] sync_r;
    always @(posedge clk_10mhz or posedge reset)
        if (reset) sync_r <= 3'd0;
        else       sync_r <= {sync_r[1:0], sig_pps};

    reg [4:0] gcnt;
    reg       pps_clean;
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            gcnt      <= 5'd0;
            pps_clean <= 1'b0;
        end else begin
            if (sync_r[2]) begin
                if (gcnt < MIN_PULSE) gcnt <= gcnt + 1'b1;
                if (gcnt == MIN_PULSE - 1) pps_clean <= 1'b1;
            end else begin
                gcnt      <= 5'd0;
                pps_clean <= 1'b0;
            end
        end
    end

    reg pps_prev;
    always @(posedge clk_10mhz or posedge reset)
        if (reset) pps_prev <= 1'b0;
        else       pps_prev <= pps_clean;

    wire pps_rise = pps_clean & ~pps_prev;

    // =========================================================================
    // 2. TICK COUNTER + FREQUENCY ERROR
    //    Counts 10MHz ticks between PPS rising edges.
    //    freq_error = count - 10,000,000
    //    meas_rdy pulses for one cycle when new measurement available.
    // =========================================================================
    reg [23:0]        tcnt;
    reg [23:0]        tcnt_cap;    // Captured at PPS edge (avoids reset race)
    reg               pps_seen;
    reg signed [24:0] freq_error;
    reg               meas_rdy;
    reg               valid_pps;  // PPS period within ±1000ppm

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            tcnt      <= 24'd0;
            tcnt_cap  <= 24'd0;
            pps_seen  <= 1'b0;
            freq_error<= 25'd0;
            meas_rdy  <= 1'b0;
            valid_pps <= 1'b0;
        end else begin
            meas_rdy <= 1'b0;

            if (pps_rise) begin
                tcnt_cap <= tcnt;   // Capture BEFORE reset (avoids race)
                tcnt     <= 24'd0;
                if (pps_seen) begin
                    freq_error <= $signed({1'b0, tcnt})
                                - $signed(EXPECTED);
                    meas_rdy   <= 1'b1;
                    // Valid if within ±10000 ticks (1000ppm) of expected
                    valid_pps  <= (tcnt > 24'd9_990_000)
                                & (tcnt < 24'd10_010_000);
                end
                pps_seen <= 1'b1;
            end else begin
                tcnt <= tcnt + 1'b1;
                // Lost PPS if counter exceeds 1.5× expected
                if (tcnt > 24'd15_000_000) begin
                    pps_seen  <= 1'b0;
                    valid_pps <= 1'b0;
                end
            end
        end
    end

    wire [23:0] freq_abs = freq_error[24]
                         ? (~freq_error[23:0] + 1'b1)
                         : freq_error[23:0];

    // =========================================================================
    // 3. STATE MACHINE
    //    WAIT_REF : wait for valid PPS
    //    COARSE   : fast frequency correction
    //    FINE     : slow fine correction + lock detection
    // =========================================================================
    localparam WAIT_REF = 2'd0;
    localparam COARSE   = 2'd1;
    localparam FINE     = 2'd2;

    reg [1:0] state;
    reg [2:0] coarse_cnt;   // Consecutive measurements within COARSE_TOL
    reg [3:0] lock_cnt;     // Consecutive measurements within LOCK_TOL
    reg       locked;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            state      <= WAIT_REF;
            coarse_cnt <= 3'd0;
            lock_cnt   <= 4'd0;
            locked     <= 1'b0;
        end else begin
            if (~valid_pps & pps_seen) begin
                // PPS lost or invalid → back to start
                state      <= WAIT_REF;
                coarse_cnt <= 3'd0;
                lock_cnt   <= 4'd0;
                locked     <= 1'b0;
            end else if (meas_rdy) begin
                case (state)
                    WAIT_REF : begin
                        if (valid_pps) state <= COARSE;
                    end
                    COARSE : begin
                        if (freq_abs < COARSE_TOL) begin
                            if (coarse_cnt < COARSE_CONFIRM)
                                coarse_cnt <= coarse_cnt + 1'b1;
                            if (coarse_cnt == COARSE_CONFIRM - 1)
                                state <= FINE;
                        end else begin
                            coarse_cnt <= 3'd0;
                        end
                    end
                    FINE : begin
                        // Lock : freq_abs < LOCK_TOL OR
                        // integrator barely moving (setpoint stable)
                        // Use generous tolerance - GPS jitter can cause
                        // single-second spikes that should not reset lock
                        if (freq_abs < LOCK_TOL) begin
                            if (lock_cnt < LOCK_CONFIRM)
                                lock_cnt <= lock_cnt + 1'b1;
                            if (lock_cnt == LOCK_CONFIRM - 1)
                                locked <= 1'b1;
                        end else begin
                            // Only reset lock_cnt on 2 consecutive bad measurements
                            // Single GPS jitter spike ignored
                            if (lock_cnt > 4'd0)
                                lock_cnt <= lock_cnt - 1'b1;
                            else
                                locked <= 1'b0;
                            // Large error → back to COARSE
                            if (freq_abs > COARSE_TOL)
                                state <= COARSE;
                        end
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // 4. INTEGRATOR
    //    Updated once per second on meas_rdy.
    //    COARSE : large step to pull frequency in
    //    FINE   : small step to trim and hold
    //
    //    integrator is 24 bits with SD_FRAC=8 fractional bits.
    //    sd_setpoint = integrator[23:8] = upper 16 bits.
    //
    //    Sign convention :
    //    freq_error > 0 → VCXO running fast → need lower VCXO_TUNE
    //                   → decrease integrator
    //    freq_error < 0 → VCXO running slow → need higher VCXO_TUNE
    //                   → increase integrator
    //    Therefore : integrator -= freq_error << SHIFT
    // =========================================================================
    localparam SD_FRAC = 8;
    localparam INTEG_MAX = 24'hFFFFFF;
    localparam INTEG_MID = 24'h800000; // Mid-scale = sd_setpoint=32768

    reg signed [24:0] integrator; // 25 bits to detect overflow

    wire signed [24:0] coarse_step = $signed(freq_error) <<< COARSE_SHIFT;
    wire signed [24:0] fine_step   = $signed(freq_error) <<< FINE_SHIFT;

    wire signed [24:0] integ_next_coarse = $signed({1'b0, integrator[23:0]})
                                         - coarse_step;
    wire signed [24:0] integ_next_fine   = $signed({1'b0, integrator[23:0]})
                                         - fine_step;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            integrator <= $signed({1'b0, INTEG_MID});
        end else if (meas_rdy & valid_pps) begin
            case (state)
                COARSE : begin
                    // Clamp to [0 .. INTEG_MAX]
                    if (integ_next_coarse < 0)
                        integrator <= 25'sd0;
                    else if (integ_next_coarse > $signed({1'b0, INTEG_MAX}))
                        integrator <= $signed({1'b0, INTEG_MAX});
                    else
                        integrator <= integ_next_coarse;
                end
                FINE : begin
                    if (integ_next_fine < 0)
                        integrator <= 25'sd0;
                    else if (integ_next_fine > $signed({1'b0, INTEG_MAX}))
                        integrator <= $signed({1'b0, INTEG_MAX});
                    else
                        integrator <= integ_next_fine;
                end
            endcase
        end
    end

    wire [15:0] sd_setpoint = integrator[23:8];

    // =========================================================================
    // 5. PWM OUTPUT WITH DITHERING
    //    8-bit PWM at 10MHz/256 = 39kHz.
    //    Dithering on lower 8 bits of sd_setpoint → effective 16-bit resolution.
    // =========================================================================
    reg [7:0] pwm_cnt;
    reg [8:0] dither_acc;
    reg [7:0] pwm_duty_r;
    reg       dither_bit;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            pwm_cnt    <= 8'd0;
            dither_acc <= 9'd0;
            pwm_duty_r <= 8'd128;
            dither_bit <= 1'b0;
        end else begin
            pwm_cnt <= pwm_cnt + 1'b1;
            if (pwm_cnt == 8'd255) begin
                {dither_bit, dither_acc[7:0]} <= {1'b0, dither_acc[7:0]}
                                               + {1'b0, sd_setpoint[7:0]};
                pwm_duty_r <= sd_setpoint[15:8];
            end
        end
    end

    wire [8:0] pwm_thr = {1'b0, pwm_duty_r} + {8'd0, dither_bit};
    assign phase_out = ({1'b0, pwm_cnt} < pwm_thr);

    // =========================================================================
    // 6. OUTPUTS
    // =========================================================================
    assign lock_ind = locked;

    assign dbg_state      = state;
    assign dbg_freq_error = freq_error;
    assign dbg_setpoint   = sd_setpoint;
    assign dbg_valid_pps  = valid_pps;
    assign dbg_integrator = integrator[23:0];

endmodule