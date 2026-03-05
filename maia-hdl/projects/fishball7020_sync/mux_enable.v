module mux_enable (
    input wire ps_i0,
    input wire ps_q0,
    input wire ps_i1,
    input wire ps_q1,
    input wire sync,
    input wire sel,
    output wire out_i0,
    output wire out_q0,
    output wire out_i1,
    output wire out_q1
);

    // If sel is 1, all outputs reflect the sync signal. 
    // If sel is 0, they pass the original ps signals.
    assign out_i0 = sel ? sync : ps_i0;
    assign out_q0 = sel ? sync : ps_q0;
    assign out_i1 = sel ? sync : ps_i1;
    assign out_q1 = sel ? sync : ps_q1;

endmodule
