// =============================================================================
// Module  : vctcxo_pll_core
// Purpose : GPSDO with support for Inverse Slope VCTCXO (Higher V = Lower Freq)
// =============================================================================

module vctcxo_pll_core (
    input  wire        clk_10mhz,
    input  wire        sig_pps,
    input  wire        reset,
    output wire        phase_out,
    output wire        lock_ind,

    // Debug
    output wire [1:0]        dbg_state,
    output wire signed [24:0] dbg_freq_error,
    output wire [15:0]       dbg_setpoint,
    output wire              dbg_valid_pps,
    output wire signed [23:0] dbg_integrator
);

    // -------------------------------------------------------------------------
    // Configuration & Tuning
    // -------------------------------------------------------------------------
    localparam EXPECTED = 25'd10_000_000;

    // Set this to 1 if Higher Voltage = Lower Frequency
    localparam VCXO_REVERSED = 1'b1; 

    parameter COARSE_SHIFT   = 4'd5;  // gain=32, rapide avec RC 8ms  
    parameter COARSE_TOL     = 20'd100;  // 100 ticks = 10ppm
    parameter COARSE_CONFIRM = 3'd5;     // 5 secondes

    parameter FINE_SHIFT_FAST = 4'd5;  // gain=32 
    parameter FINE_SHIFT_HOLD = 4'd2;  // gain=4, maintien 

    parameter LOCK_TOL       = 20'd15; // 15 ticks = 1.5ppm
    parameter LOCK_CONFIRM   = 4'd8; 

    parameter TEST_MODE      = 1'b0;
    parameter TEST_DUTY      = 8'd128;
    parameter MIN_PULSE      = 5'd20;

    // 1. PPS INPUT SYNC + GLITCH FILTER
    reg [2:0] sync_r;
    always @(posedge clk_10mhz or posedge reset)
        if (reset) sync_r <= 3'd0;
        else       sync_r <= {sync_r[1:0], sig_pps};

    reg [4:0] gcnt;
    reg       pps_clean;
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin gcnt <= 5'd0; pps_clean <= 1'b0; end
        else begin
            if (sync_r[2]) begin
                if (gcnt < MIN_PULSE) gcnt <= gcnt + 1'b1;
                if (gcnt == MIN_PULSE - 1) pps_clean <= 1'b1;
            end else begin gcnt <= 5'd0; pps_clean <= 1'b0; end
        end
    end

    reg pps_prev;
    always @(posedge clk_10mhz or posedge reset)
        if (reset) pps_prev <= 1'b0;
        else       pps_prev <= pps_clean;

    wire pps_rise = pps_clean & ~pps_prev;

    // 2. TICK COUNTER
    reg [23:0]        tcnt;
    reg               pps_seen;
    reg signed [24:0] freq_error;
    reg               meas_rdy;
    reg               valid_pps;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            tcnt <= 24'd0; pps_seen <= 1'b0; freq_error <= 25'd0;
            meas_rdy <= 1'b0; valid_pps <= 1'b0;
        end else begin
            meas_rdy <= 1'b0;
            if (pps_rise) begin
                tcnt <= 24'd0;
                if (pps_seen) begin
                    freq_error <= $signed({1'b0, tcnt}) - $signed(EXPECTED);
                    meas_rdy   <= 1'b1;
                    valid_pps  <= (tcnt > 24'd9_990_000) & (tcnt < 24'd10_010_000);
                end
                pps_seen <= 1'b1;
            end else begin
                tcnt <= tcnt + 1'b1;
                if (tcnt > 24'd15_000_000) begin pps_seen <= 1'b0; valid_pps <= 1'b0; end
            end
        end
    end

    wire [23:0] freq_abs = freq_error[24] ? (~freq_error[23:0] + 1'b1) : freq_error[23:0];

    // 3. STATE MACHINE
    localparam WAIT_REF = 2'd0;
    localparam COARSE   = 2'd1;
    localparam FINE     = 2'd2;

    reg [1:0] state;
    reg [2:0] coarse_cnt;
    reg [3:0] lock_cnt;
    reg       locked;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            state <= WAIT_REF; coarse_cnt <= 3'd0; lock_cnt <= 4'd0; locked <= 1'b0;
        end else if (~valid_pps & pps_seen) begin
            state <= WAIT_REF; coarse_cnt <= 3'd0; lock_cnt <= 4'd0; locked <= 1'b0;
        end else if (meas_rdy) begin
            case (state)
                WAIT_REF : if (valid_pps) state <= COARSE;
                COARSE   : begin
                    if (freq_abs < COARSE_TOL) begin
                        if (coarse_cnt < COARSE_CONFIRM) coarse_cnt <= coarse_cnt + 1'b1;
                        if (coarse_cnt == COARSE_CONFIRM - 1) state <= FINE;
                    end else coarse_cnt <= 3'd0;
                end
                FINE     : begin
                    if (freq_abs < LOCK_TOL) begin
                        if (lock_cnt < LOCK_CONFIRM) lock_cnt <= lock_cnt + 1'b1;
                        if (lock_cnt == LOCK_CONFIRM - 1) locked <= 1'b1;
                    end else begin
                        if (lock_cnt > 4'd0) lock_cnt <= lock_cnt - 1'b1;
                        else locked <= 1'b0;
                        if (freq_abs > COARSE_TOL) state <= COARSE;
                    end
                end
            endcase
        end
    end

    // 4. INTEGRATOR (INVERSION LOGIC HERE)
    localparam INTEG_MAX = 24'hFFFFFF;
    localparam INTEG_MID = 24'h800000;
    reg signed [24:0] integrator;

    wire [3:0] active_fine_shift = locked ? FINE_SHIFT_HOLD : FINE_SHIFT_FAST;

    // We calculate the Magnitude of the correction
    wire signed [24:0] coarse_step_val = $signed(freq_error) <<< COARSE_SHIFT;
    wire signed [24:0] fine_step_val   = $signed(freq_error) <<< active_fine_shift;

    // Apply the correction based on VCXO polarity
    // If Normal: freq_err > 0 (too slow) -> Increase Integrator (Higher V)
    // If Invert: freq_err > 0 (too slow) -> Decrease Integrator (Lower V)
    wire signed [24:0] step = (state == COARSE) ? coarse_step_val : fine_step_val;
    wire signed [24:0] corrected_step = VCXO_REVERSED ? -step : step;

    reg meas_rdy_d;
    always @(posedge clk_10mhz) meas_rdy_d <= meas_rdy;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) integrator <= $signed({1'b0, INTEG_MID});
        else if (meas_rdy_d & valid_pps && state != WAIT_REF) begin
            if (integrator + corrected_step < 0) 
                integrator <= 25'sd0;
            else if (integrator + corrected_step > $signed({1'b0, INTEG_MAX})) 
                integrator <= $signed({1'b0, INTEG_MAX});
            else 
                integrator <= integrator + corrected_step;
        end
    end

    wire [15:0] sd_setpoint = integrator[23:8];

    // 5. PWM + DITHER
    reg [7:0] pwm_cnt;
    reg [8:0] dither_acc;
    reg [7:0] pwm_duty_r;
    reg       dither_bit;

    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin pwm_cnt <= 8'd0; dither_acc <= 9'd0; pwm_duty_r <= 8'd128; dither_bit <= 1'b0; end
        else begin
            pwm_cnt <= pwm_cnt + 1'b1;
            if (pwm_cnt == 8'd255) begin
                {dither_bit, dither_acc[7:0]} <= {1'b0, dither_acc[7:0]} + {1'b0, sd_setpoint[7:0]};
                pwm_duty_r <= sd_setpoint[15:8];
            end
        end
    end

    assign phase_out = TEST_MODE ? ({1'b0, pwm_cnt} < {1'b0, TEST_DUTY}) : 
                                   ({1'b0, pwm_cnt} < ({1'b0, pwm_duty_r} + {8'd0, dither_bit}));

    // 6. BLINK LOGIC
    reg [22:0] blink_cnt;
    reg        blink_tog;
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin blink_cnt <= 23'd0; blink_tog <= 1'b0; end
        else begin
            blink_cnt <= blink_cnt + 1'b1;
            if (state == COARSE) begin
                if (blink_cnt >= 23'd4_999_999) begin blink_cnt <= 23'd0; blink_tog <= ~blink_tog; end
            end else if (state == FINE && !locked) begin
                if (blink_cnt >= 23'd1_249_999) begin blink_cnt <= 23'd0; blink_tog <= ~blink_tog; end
            end
        end
    end

    assign lock_ind = locked ? 1'b1 : (state == WAIT_REF ? 1'b0 : blink_tog);

    // DEBUG
    assign dbg_state      = state;
    assign dbg_freq_error = freq_error;
    assign dbg_setpoint   = sd_setpoint;
    assign dbg_valid_pps  = valid_pps;
    assign dbg_integrator = integrator[23:0];

endmodule