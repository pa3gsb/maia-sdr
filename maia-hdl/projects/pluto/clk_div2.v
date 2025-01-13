module ClockDividerBy2 (
    input wire clk_in,   // Entrée d'horloge
    input wire rst,      // Signal de réinitialisation
    output reg clk_out   // Sortie d'horloge divisée par 2
);

always @(posedge clk_in or posedge rst) begin
    if (rst) begin
        clk_out <= 1'b0;
    end else begin
        clk_out <= ~clk_out;  // Inverse l'état de la sortie à chaque front montant de l'horloge d'entrée
    end
end

endmodule

