module mux_enable (
    input wire ps_i0,
    input wire ps_q0,
    input wire ps_i1,
    input wire ps_q1,
    input wire sync_master,
    input wire sync_slave,
    input wire is_slave,
    output wire out_i0,
    output wire out_q0,
    output wire out_i1,
    output wire out_q1
);

    // If is_slave is 0, outputs are gated with sync_master.
    // If is_slave is 1, outputs are gated with sync_slave.
    assign out_i0 = is_slave ? sync_slave & ps_i0 : sync_master & ps_i0;
    assign out_q0 = is_slave ? sync_slave & ps_q0 : sync_master & ps_q0;
    assign out_i1 = is_slave ? sync_slave & ps_i1 : sync_master & ps_i1;
    assign out_q1 = is_slave ? sync_slave & ps_q1 : sync_master & ps_q1;

endmodule