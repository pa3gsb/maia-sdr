`timescale 1ns/100ps

module cs12_8mux #(
    parameter DATA_WIDTH = 16
) (
    input                     clk,
    input                     rst_n,
    
    // Inputs
    input      [DATA_WIDTH-1:0] I0,        
    input      [DATA_WIDTH-1:0] Q0,
    input                       valid_in,
    
    input                       Enable0,
    input                       Enable1,
    
    // Outputs
    output reg [DATA_WIDTH-1:0] data_out0, 
    output reg [DATA_WIDTH-1:0] data_out1,
    output reg                  valid_out,
    output                      Enable_O1,
    output                      Enable_O2
);

    // Ping-pong buffers for 12-bit packing (8 IQ pairs = 192 bits)
    reg [191:0] buffer_a, buffer_b;
    reg         active_buffer; 
    reg [3:0]   in_count;
    reg [2:0]   out_count;
    reg         burst_pending;

    // Rounding logic for 8-bit mode
    wire [7:0] rnd_I = I0[3] ? (I0[11:4] + 1'b1) : I0[11:4];
    wire [7:0] rnd_Q = Q0[3] ? (Q0[11:4] + 1'b1) : Q0[11:4];

    // --- UPDATED ENABLE LOGIC ---
    // Enable_O1 is high for all modes except Idle
    assign Enable_O1 = (Enable0 | Enable1);
    
    // Enable_O2 is high for Bypass and Pack 12-bit, but LOW for Pack 8-bit (1,0)
    assign Enable_O2 = Enable1; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {buffer_a, buffer_b} <= 384'h0;
            {in_count, out_count} <= 7'h0;
            {active_buffer, burst_pending} <= 2'b0;
            {data_out0, data_out1, valid_out} <= 33'h0;
        end else begin
            valid_out <= 1'b0; // Default

            case ({Enable0, Enable1})
                // --- MODE 11: BYPASS ---
                2'b11: if (valid_in) begin
                    data_out0 <= I0;
                    data_out1 <= Q0;
                    valid_out <= 1'b1;
                end

                // --- MODE 10: PACK 8-BIT ---
                // Enable_O1=1, Enable_O2=0
                2'b10: if (valid_in) begin
                    data_out0 <= {rnd_Q, rnd_I};
                    data_out1 <= 16'h0;
                    valid_out <= 1'b1;
                end

                // --- MODE 01: PACK 12-BIT ---
                // Enable_O1=1, Enable_O2=1
                2'b01: begin
                    if (valid_in) begin
                        if (!active_buffer)
                            buffer_a <= {buffer_a[167:0], Q0[11:0], I0[11:0]};
                        else
                            buffer_b <= {buffer_b[167:0], Q0[11:0], I0[11:0]};

                        if (in_count == 4'd7) begin
                            in_count <= 4'd0;
                            active_buffer <= ~active_buffer;
                            burst_pending <= 1'b1;
                        end else begin
                            in_count <= in_count + 1'b1;
                        end
                    end

                    if (burst_pending) begin
                        valid_out <= 1'b1;
                        if (active_buffer) begin 
                            data_out1 <= buffer_a[191:176];
                            data_out0 <= buffer_a[175:160];
                            buffer_a  <= {buffer_a[159:0], 32'h0};
                        end else begin           
                            data_out1 <= buffer_b[191:176];
                            data_out0 <= buffer_b[175:160];
                            buffer_b  <= {buffer_b[159:0], 32'h0};
                        end

                        if (out_count == 3'd5) begin
                            out_count <= 3'd0;
                            burst_pending <= 1'b0;
                        end else begin
                            out_count <= out_count + 1'b1;
                        end
                    end
                end

                default: begin
                    in_count <= 4'd0;
                    burst_pending <= 1'b0;
                    data_out0 <= 16'h0;
                    data_out1 <= 16'h0;
                end
            endcase
        end
    end

endmodule