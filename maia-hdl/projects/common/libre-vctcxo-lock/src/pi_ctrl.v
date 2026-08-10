//
// Generic PI Controller
//
// ctrl_out = saturate( P_term(error) + I_term(acc) )
// acc     += error   (each valid cycle, when freeze=0 and integration
//                      wouldn't push the output further into saturation
//                      in the same direction)
//
// Modeled on ocpi.osp.libresdr's pi_ctrl.vhd (ref-clk-support-2 branch),
// ported to Verilog, with deliberate additions beyond the reference:
//
// 1. Bidirectional (signed) shift, not right-shift-only - see
//    SHIFT_MID below and the freq_meas.v header for why.
//
// 2. Conditional-integration anti-windup - see the comment further down.
//
// 3. Multi-cycle pipeline, not a single combinational cycle. The first
//    version of this module computed everything (two 48-bit variable
//    barrel shifts, several 48-bit adds, the anti-windup comparison, and
//    final saturation) combinationally in one clock edge, on the theory
//    that keeping latency low was free. It wasn't: timing analysis on
//    real hardware showed 37 logic levels / ~12.4ns on the path from
//    i_acc_reg through this datapath, against a 10ns (100MHz)
//    s00_axi_aclk period - a real, failing setup violation, not a
//    cosmetic one. There is no reason to optimize this module's latency
//    in the first place: a new result is only needed once per completed
//    measurement window (100ms = 10,000,000 clk cycles for the 10 MHz
//    path), so spreading the same arithmetic across a handful of extra
//    clock cycles costs nothing in practice while giving each pipeline
//    stage a full clock period to settle. valid/valid_out are still a
//    single-cycle pulse interface; valid_out now simply arrives several
//    cycles after valid instead of one, and no combinational path spans
//    more than one arithmetic operation.
//
`timescale 1ns / 1ps

module pi_ctrl #(
    parameter integer ERROR_W  = 32,  // error input width (signed)
    parameter integer ACC_W    = 48,  // integrator accumulator width (signed)
    parameter integer SHIFT_W  = 8,   // shift-amount field width
    parameter integer SHIFT_MID = 128, // field value meaning "no shift" (unity)
    parameter integer OUTPUT_W = 16   // correction output width (signed)
)(
    input  wire                        clk,
    input  wire                        init,
    input  wire                        freeze,   // hold integrator when 1
    input  wire signed [ERROR_W-1:0]   error_in,
    input  wire                        valid,
    input  wire [SHIFT_W-1:0]          p_shift,  // SHIFT_MID = unity; above = amplify, below = attenuate
    input  wire [SHIFT_W-1:0]          i_shift,  // same convention
    output reg  signed [OUTPUT_W-1:0]  ctrl_out,
    output reg                         valid_out
);

    reg signed [ACC_W-1:0] i_acc = {ACC_W{1'b0}};

    localparam signed [ACC_W-1:0] O_MAX = ({{(ACC_W-1){1'b0}}, 1'b1} <<< (OUTPUT_W-1)) - 1'sb1;
    localparam signed [ACC_W-1:0] O_MIN = -({{(ACC_W-1){1'b0}}, 1'b1} <<< (OUTPUT_W-1));

    function automatic signed [ACC_W-1:0] apply_shift;
        input signed [ACC_W-1:0]   val;
        input signed [SHIFT_W:0]   shift_amt;
        begin
            if (shift_amt >= 0)
                apply_shift = val <<< shift_amt;
            else
                apply_shift = val >>> (-shift_amt);
        end
    endfunction

    // Pipeline registers - one arithmetic operation's worth of logic
    // between each pair of stages.
    reg signed [ACC_W-1:0] err_r;
    reg signed [SHIFT_W:0] p_shift_s_r, i_shift_s_r;
    reg                    freeze_r;
    reg signed [ACC_W-1:0] p_term_r;
    reg signed [ACC_W-1:0] acc_candidate_r;
    reg signed [ACC_W-1:0] i_term_hold_r;
    reg signed [ACC_W-1:0] i_term_integrate_r;
    reg signed [ACC_W-1:0] sum_hold_r;
    reg signed [ACC_W-1:0] sum_integrate_r;

    localparam [2:0]
        S_IDLE           = 3'd0,
        S_SHIFT_P        = 3'd1,
        S_SHIFT_I_HOLD   = 3'd2,
        S_SHIFT_I_ACC    = 3'd3,
        S_SUM_HOLD       = 3'd4,
        S_SUM_INTEGRATE  = 3'd5,
        S_DECIDE         = 3'd6;
    reg [2:0] state = S_IDLE;

    always @(posedge clk) begin
        valid_out <= 1'b0;
        if (init) begin
            state     <= S_IDLE;
            i_acc     <= {ACC_W{1'b0}};
            ctrl_out  <= {OUTPUT_W{1'b0}};
        end
        else begin
            case (state)
                S_IDLE: begin
                    if (valid) begin
                        err_r       <= {{(ACC_W-ERROR_W){error_in[ERROR_W-1]}}, error_in};
                        p_shift_s_r <= $signed({1'b0, p_shift}) - SHIFT_MID;
                        i_shift_s_r <= $signed({1'b0, i_shift}) - SHIFT_MID;
                        freeze_r    <= freeze;
                        state       <= S_SHIFT_P;
                    end
                end
                // One shift and one add - independent, share a stage.
                S_SHIFT_P: begin
                    p_term_r        <= apply_shift(err_r, p_shift_s_r);
                    acc_candidate_r <= i_acc + err_r;
                    state           <= S_SHIFT_I_HOLD;
                end
                S_SHIFT_I_HOLD: begin
                    i_term_hold_r <= apply_shift(i_acc, i_shift_s_r);
                    state         <= S_SHIFT_I_ACC;
                end
                S_SHIFT_I_ACC: begin
                    i_term_integrate_r <= apply_shift(acc_candidate_r, i_shift_s_r);
                    state              <= S_SUM_HOLD;
                end
                S_SUM_HOLD: begin
                    sum_hold_r <= p_term_r + i_term_hold_r;
                    state      <= S_SUM_INTEGRATE;
                end
                S_SUM_INTEGRATE: begin
                    sum_integrate_r <= p_term_r + i_term_integrate_r;
                    state           <= S_DECIDE;
                end
                S_DECIDE: begin
                    // Conditional-integration anti-windup: don't grow the
                    // integrator further once the combined output is
                    // already saturated in the same direction the new
                    // error would push it.
                    if (freeze_r ||
                        (sum_integrate_r > O_MAX && err_r > 0) ||
                        (sum_integrate_r < O_MIN && err_r < 0)) begin
                        if (sum_hold_r > O_MAX)
                            ctrl_out <= O_MAX[OUTPUT_W-1:0];
                        else if (sum_hold_r < O_MIN)
                            ctrl_out <= O_MIN[OUTPUT_W-1:0];
                        else
                            ctrl_out <= sum_hold_r[OUTPUT_W-1:0];
                        // i_acc left unchanged
                    end
                    else begin
                        i_acc <= acc_candidate_r;
                        if (sum_integrate_r > O_MAX)
                            ctrl_out <= O_MAX[OUTPUT_W-1:0];
                        else if (sum_integrate_r < O_MIN)
                            ctrl_out <= O_MIN[OUTPUT_W-1:0];
                        else
                            ctrl_out <= sum_integrate_r[OUTPUT_W-1:0];
                    end
                    valid_out <= 1'b1;
                    state     <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
