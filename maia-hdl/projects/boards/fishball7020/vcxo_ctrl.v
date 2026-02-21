// =============================================================================
// Module  : vctcxo_pll_core
// Purpose : GPS-disciplined VCTCXO PLL with adaptive gain correction.
//
// Inspired by Ettus Research b205_ref_pll adaptive gain approach :
//   Small error → small correction step → stable, no oscillation
//   Large error → large correction step → fast acquisition
//
// Architecture :
//   UNLOCKED : phase_out = raw XOR (fast analog pull-in)
//   LOCKED   : phase_out = PWM at duty_frozen
//              duty_frozen updated with adaptive step based on drift magnitude
//
// Adaptive gain :
//   drift = duty_avg - duty_frozen  (signed, 0.1% units at 10kHz)
//   step  = adaptive : large when |drift| big, small when |drift| small
//   duty_frozen += step * sign(drift)  every AVG window
//
//   This prevents oscillation : large corrections only when genuinely needed,
//   tiny corrections when near lock → equivalent to Ettus shift-based gain.
//
// Reference : 10kHz (NEO-M8N UBX-CFG-TP5, 48MHz/4800 = exact integer)
//   10MHz / 10kHz = 1000 ticks per period → duty resolution = 0.1%
// =============================================================================

module vctcxo_pll_core (
    input  wire clk_10mhz,
    input  wire sig_10khz,
    input  wire reset,
    output wire phase_out,
    output wire lock_ind,
    output wire clk_10khz
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter GATE_PERIODS    = 16'd1000;
    parameter EXPECTED_COUNT  = 20'd1_000_000;
    parameter LOCK_FREQ_TOL   = 20'd2;
    parameter LOCK_COUNT_MAX  = 7'd100;
    parameter ALIGN_OFFSET    = 10'd0;
    parameter MIN_PULSE_TICKS = 5'd20;

    // Averaging window : 2^AVG_SHIFT periods × 100µs
    // AVG_SHIFT=8 : 256 × 100µs = 25.6ms  ← good balance
    parameter AVG_SHIFT = 8;
    localparam ACC_BITS = 10 + AVG_SHIFT;  // 18 bits

    // Adaptive gain thresholds (in 0.1% duty units, scale 0..1000)
    // |drift| > GAIN_HIGH : step = STEP_HIGH (fast correction)
    // |drift| > GAIN_MID  : step = STEP_MID
    // |drift| > GAIN_LOW  : step = STEP_LOW
    // |drift| <= GAIN_LOW : step = STEP_MIN (sub-LSB, very slow)
    parameter GAIN_HIGH = 10'd50;   // >5%   drift → step=20
    parameter GAIN_MID  = 10'd20;   // >2%   drift → step=8
    parameter GAIN_LOW  = 10'd5;    // >0.5% drift → step=2
                                    // <=0.5% drift → step=1

    parameter STEP_HIGH = 10'd20;
    parameter STEP_MID  = 10'd8;
    parameter STEP_LOW  = 10'd2;
    parameter STEP_MIN  = 10'd1;

    // =========================================================================
    // 1. INPUT SYNCHRONISER
    // =========================================================================
    reg [2:0] sync_reg;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset)
            sync_reg <= 3'd0;
        else
            sync_reg <= {sync_reg[1:0], sig_10khz};
    end

    wire sig_sync = sync_reg[2];

    // =========================================================================
    // 2. GLITCH FILTER
    // =========================================================================
    reg [4:0] pulse_cnt;
    reg       ref_gps;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            pulse_cnt <= 5'd0;
            ref_gps   <= 1'b0;
        end else begin
            if (sig_sync) begin
                if (pulse_cnt < MIN_PULSE_TICKS)
                    pulse_cnt <= pulse_cnt + 1'b1;
                if (pulse_cnt == MIN_PULSE_TICKS - 1)
                    ref_gps <= 1'b1;
            end else begin
                pulse_cnt <= 5'd0;
                ref_gps   <= 1'b0;
            end
        end
    end

    reg ref_gps_prev;
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) ref_gps_prev <= 1'b0;
        else       ref_gps_prev <= ref_gps;
    end

    wire gps_rise = ref_gps && !ref_gps_prev;

    // =========================================================================
    // 3. PHASE-ALIGNED FREQUENCY DIVIDER : 10MHz → 10kHz
    // =========================================================================
    reg [9:0] div_count;
    reg       ref_10khz;
    reg       aligned;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            div_count <= 10'd0;
            ref_10khz <= 1'b0;
            aligned   <= 1'b0;
        end else begin
            if (!aligned && gps_rise) begin
                div_count <= ALIGN_OFFSET;
                ref_10khz <= 1'b0;
                aligned   <= 1'b1;
            end else if (aligned) begin
                if (div_count == 10'd999) begin
                    div_count <= 10'd0;
                    ref_10khz <= ~ref_10khz;
                end else begin
                    if (div_count == 10'd499)
                        ref_10khz <= ~ref_10khz;
                    div_count <= div_count + 1'b1;
                end
            end
        end
    end

    assign clk_10khz = ref_10khz;

    // =========================================================================
    // 4. XOR PHASE DETECTOR
    // =========================================================================
    wire phase_xor = ref_10khz ^ ref_gps;

    // =========================================================================
    // 5. DUTY AVERAGER
    //    Accumulates XOR high ticks over 2^AVG_SHIFT periods.
    //    duty_avg = 0..1000, target at lock = 500 (50% duty = 90° phase).
    // =========================================================================
    reg [9:0]           per_high_cnt;
    reg [AVG_SHIFT-1:0] win_cnt;
    reg [ACC_BITS-1:0]  duty_acc;
    reg [9:0]           duty_avg;
    reg                 new_avg;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            per_high_cnt <= 10'd0;
            win_cnt      <= {AVG_SHIFT{1'b0}};
            duty_acc     <= {ACC_BITS{1'b0}};
            duty_avg     <= 10'd500;
            new_avg      <= 1'b0;
        end else if (aligned) begin
            new_avg <= 1'b0;

            if (div_count == 10'd999) begin
                duty_acc     <= duty_acc
                              + {{(ACC_BITS-10){1'b0}}, per_high_cnt}
                              + (phase_xor ? {{(ACC_BITS-1){1'b0}}, 1'b1}
                                           : {ACC_BITS{1'b0}});
                per_high_cnt <= 10'd0;
                win_cnt      <= win_cnt + 1'b1;

                if (win_cnt == {AVG_SHIFT{1'b1}}) begin
                    duty_avg <= duty_acc[ACC_BITS-1:AVG_SHIFT];
                    duty_acc <= {ACC_BITS{1'b0}};
                    new_avg  <= 1'b1;
                end
            end else if (phase_xor) begin
                per_high_cnt <= per_high_cnt + 1'b1;
            end
        end
    end

    // =========================================================================
    // 6. ADAPTIVE GAIN CORRECTION OF duty_frozen
    //
    //    Inspired by Ettus b205 shift-based adaptive gain :
    //      Large error → large step → fast correction, no prolonged oscillation
    //      Small error → small step → fine trimming near lock point
    //
    //    drift     = duty_avg - duty_frozen  (signed 11 bits)
    //    drift_abs = |drift|
    //    step      = f(drift_abs) : lookup table with 4 levels
    //    duty_frozen += step * sign(drift)
    //
    //    Correction applied every new_avg pulse (every 2^AVG_SHIFT periods).
    //    AVG_SHIFT=8 : every 256 × 100µs = 25.6ms
    //
    //    duty_frozen clamped to 1..999 to avoid 0% or 100% duty
    //    (which would produce DC on VCXO_TUNE with no AC component for RC).
    // =========================================================================
    reg [9:0]  duty_frozen;
    reg        use_frozen;

    // Signed drift
    wire signed [10:0] drift     = $signed({1'b0, duty_avg})
                                 - $signed({1'b0, duty_frozen});
    wire               drift_neg = drift[10];
    wire [9:0]         drift_abs = drift_neg ? (~drift[9:0] + 1'b1)
                                             : drift[9:0];

    // Adaptive step : 4 levels matching Ettus gain table concept
    reg [9:0] step;
    always @(*) begin
        if      (drift_abs > GAIN_HIGH) step = STEP_HIGH;
        else if (drift_abs > GAIN_MID)  step = STEP_MID;
        else if (drift_abs > GAIN_LOW)  step = STEP_LOW;
        else                            step = STEP_MIN;
    end

    // Apply correction with clamp
    reg [10:0] duty_next;  // One extra bit for overflow detection

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            duty_frozen <= 10'd500;
            use_frozen  <= 1'b0;
        end else begin
            if (!use_frozen && locked) begin
                // Capture at lock moment
                duty_frozen <= duty_avg;
                use_frozen  <= 1'b1;
            end else if (!locked) begin
                use_frozen  <= 1'b0;
            end else if (use_frozen && new_avg) begin
                // Apply adaptive step in direction of drift
                if (drift_neg) begin
                    // duty_avg < duty_frozen → decrease duty_frozen
                    duty_next = {1'b0, duty_frozen} - {1'b0, step};
                    duty_frozen <= (duty_next[10] || duty_next[9:0] == 10'd0)
                                   ? 10'd1
                                   : duty_next[9:0];
                end else begin
                    // duty_avg > duty_frozen → increase duty_frozen
                    duty_next = {1'b0, duty_frozen} + {1'b0, step};
                    duty_frozen <= (duty_next > 11'd999)
                                   ? 10'd999
                                   : duty_next[9:0];
                end
            end
        end
    end

    // =========================================================================
    // 7. OUTPUT
    //    Unlocked : raw XOR → fast analog correction
    //    Locked   : PWM at duty_frozen/1000 rate, 10kHz frequency
    // =========================================================================
    wire pwm_out = (div_count < {1'b0, duty_frozen});

    assign phase_out = !aligned   ? 1'b0
                     : use_frozen ? pwm_out
                     :              phase_xor;

    // =========================================================================
    // 8. FREQUENCY DIFFERENCE COUNTER
    // =========================================================================
    reg [19:0] tick_acc;
    reg [15:0] gps_edge_cnt;
    reg signed [20:0] freq_error;
    reg        gate_done;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            tick_acc     <= 20'd0;
            gps_edge_cnt <= 16'd0;
            freq_error   <= 21'd0;
            gate_done    <= 1'b0;
        end else begin
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
    // 9. LOCK DETECTOR
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