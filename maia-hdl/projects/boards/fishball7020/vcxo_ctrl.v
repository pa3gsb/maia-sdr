module vctcxo_pll_core (
    input  wire clk_10mhz,    // 10MHz from VCTCXO (Feedback)
    input  wire sig_100khz,   // 100kHz from GPS/External (Reference)
    input  wire reset,        // System Reset
    output wire phase_out,    // XOR phase detector output → RC filter → Vc
    output wire lock_ind,     // Lock Indicator (low = locked)
    output wire clk_100khz    // 100kHz derived from 10MHz input
);

    // --- 1. Internal Signals ---
    reg [6:0]  div_count;     // Divider for 10MHz/100
    reg        ref_100khz;    // Internal 100kHz reference
    reg [2:0]  sync_reg;      // Synchronizer for external signal

    // --- 2. Frequency Divider (10MHz to 100kHz) ---
    // Generates a local 100kHz reference from the VCTCXO
    // 10MHz / 100 = 100kHz (toggle every 50 cycles)
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            div_count  <= 7'd0;
            ref_100khz <= 1'b0;
        end else begin
            if (div_count == 7'd49) begin
                div_count  <= 7'd0;
                ref_100khz <= ~ref_100khz;
            end else begin
                div_count  <= div_count + 1'b1;
            end
        end
    end

    // Output the divided clock
    assign clk_100khz = ref_100khz;

    // --- 3. Synchronizer ---
    // Prevents metastability from the asynchronous external 100kHz signal
    always @(posedge clk_10mhz) begin
        sync_reg <= {sync_reg[1:0], sig_100khz};
    end

    // --- 4. XOR Phase Detector ---
    // Same principle as the 74HC86 in the reference design.
    // Output duty cycle is proportional to phase difference:
    //   - 0° phase diff   → 0% duty   → Vc low
    //   - 90° phase diff  → 50% duty  → Vc mid (~1.65V)
    //   - 180° phase diff → 100% duty → Vc high
    // PLL locks at 90° phase offset (mid-scale voltage).
    assign phase_out = ref_100khz ^ sync_reg[2];

    // --- 5. Lock Indicator ---
    // XOR phase detector locks at 90° → duty cycle = 50%.
    // Simple lock detect: compare rising edges proximity.
    // When locked, both signals are 90° apart and stable.
    //
    // Use a filtered version: count consecutive cycles where
    // the phase_out duty stays near 50%.
    reg [3:0] lock_count;
    reg       phase_out_r;
    reg [6:0] high_cnt;
    reg [6:0] period_cnt;
    reg       cycle_ok;

    // Measure duty cycle of phase_out over each ref_100khz period
    // At 10MHz sampling a 100kHz signal: 100 samples per period
    // Locked at 90° → ~50 high samples per period
    always @(posedge clk_10mhz or posedge reset) begin
        if (reset) begin
            high_cnt   <= 7'd0;
            period_cnt <= 7'd0;
            cycle_ok   <= 1'b0;
            lock_count <= 4'd0;
        end else begin
            if (period_cnt == 7'd99) begin
                // End of measurement window
                // Locked if duty is between 40% and 60% (40-60 high counts)
                cycle_ok   <= (high_cnt >= 7'd40) && (high_cnt <= 7'd60);
                high_cnt   <= phase_out ? 7'd1 : 7'd0;
                period_cnt <= 7'd0;

                // Filter: require 8 consecutive good cycles
                if ((high_cnt >= 7'd40) && (high_cnt <= 7'd60)) begin
                    if (lock_count < 4'd8)
                        lock_count <= lock_count + 1'b1;
                end else begin
                    lock_count <= 4'd0;
                end
            end else begin
                period_cnt <= period_cnt + 1'b1;
                if (phase_out)
                    high_cnt <= high_cnt + 1'b1;
            end
        end
    end

    assign lock_ind = (lock_count == 4'd8);

endmodule