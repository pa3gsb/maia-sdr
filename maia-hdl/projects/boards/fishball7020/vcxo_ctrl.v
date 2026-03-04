// =============================================================================
// Module  : vctcxo_pll_core
// Purpose : GPSDO with support for Inverse Slope VCTCXO (Higher V = Lower Freq)
//           + 25 MHz output synthesized from clk_10mhz via Zynq-7 MMCM
// =============================================================================

module vctcxo_pll_core (
    input  wire        clk_10mhz,
    input  wire        sig_pps,
    input  wire        reset,
    output wire        phase_out,
    output wire        lock_ind,
    output wire        mmcm_clkout,       // 25 MHz derived from clk_10mhz
    output wire        mmcm_locked, // High when internal PLL is locked

    // Debug
    output wire [1:0]        dbg_state,
    output wire signed [24:0] dbg_freq_error,
    output wire [15:0]       dbg_setpoint,
    output wire              dbg_pps_valid,
    output wire signed [23:0] dbg_integrator
);

    // =========================================================================
    // 25 MHz Generation — Zynq-7 MMCM fed from clk_10mhz
    // =========================================================================
    // MMCME2_BASE:  10 MHz × 50 = 500 MHz VCO,  /20 = 25 MHz output
    // Phase-coherent with clk_10mhz, inherits GPSDO-disciplined stability.
    // VCO range for Zynq-7 speed grade -1: 600–1200 MHz
    //                       speed grade -2: 600–1440 MHz
    // If 500 MHz is below your grade's minimum, use MULT_F=62.5 / DIV=25
    // to get VCO=625 MHz (still /25 = 25 MHz).
    // =========================================================================

    wire clk_25mhz_unbuf;
    wire clk_fb;
    wire pll_locked;

    MMCME2_BASE #(
        .BANDWIDTH       ("OPTIMIZED"),
        .CLKIN1_PERIOD   (100.000),      // 10 MHz -> 100 ns
        .CLKFBOUT_MULT_F (62.500),       // VCO = 10 × 62.5 = 625 MHz
        .CLKFBOUT_PHASE  (0.000),
        .CLKOUT0_DIVIDE_F(25.000),       // 625 / 25 = 25 MHz
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE   (0.000),
        .DIVCLK_DIVIDE   (1),            // Input divider = 1
        .REF_JITTER1     (0.010),
        .STARTUP_WAIT    ("FALSE")
    ) u_mmcm (
        .CLKIN1    (clk_10mhz),          // <-- GPSDO-disciplined 10 MHz
        .RST       (reset),
        .CLKFBOUT  (clk_fb),
        .CLKFBIN   (clk_fb),             // Internal feedback
        .CLKOUT0   (clk_25mhz_unbuf),
        .LOCKED    (pll_locked),
        .PWRDWN    (1'b0),
        // Unused outputs
        .CLKOUT0B  (),
        .CLKOUT1   (), .CLKOUT1B (),
        .CLKOUT2   (), .CLKOUT2B (),
        .CLKOUT3   (), .CLKOUT3B (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .CLKFBOUTB ()
    );

    BUFG u_bufg_25 (.I(clk_25mhz_unbuf), .O(mmcm_clkout));

    assign mmcm_locked = pll_locked;

    // =========================================================================
    // Original GPSDO logic below — unchanged
    // =========================================================================

    // -------------------------------------------------------------------------
    // Configuration & Tuning
    // -------------------------------------------------------------------------
    localparam EXPECTED = 25'd10_000_000;

    // Set this to 1 if Higher Voltage = Lower Frequency
    localparam VCXO_REVERSED = 1'b1; 

    parameter COARSE_SHIFT   = 4'd7;
    parameter COARSE_TOL     = 20'd25;
    parameter COARSE_CONFIRM = 3'd3;

    parameter FINE_SHIFT_FAST = 4'd6;
    parameter FINE_SHIFT_HOLD = 4'd3;

    parameter LOCK_TOL       = 20'd5;
    parameter LOCK_CONFIRM   = 4'd4; 

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

    wire signed [24:0] coarse_step_val = $signed(freq_error) <<< COARSE_SHIFT;
    wire signed [24:0] fine_step_val   = $signed(freq_error) <<< active_fine_shift;

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
    assign dbg_pps_valid  = valid_pps;
    assign dbg_integrator = integrator[23:0];

endmodule