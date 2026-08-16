import aes_pkg::*;

module aes_mixcolumns (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);
    logic [7:0] b [0:15];
    logic [7:0] y [0:15];
    integer i;
    integer c;

    always_comb begin
        for (i = 0; i < 16; i = i + 1) begin
            b[i] = state_in[127 - (i * 8) -: 8];
            y[i] = 8'h00;
        end

        for (c = 0; c < 4; c = c + 1) begin
            y[(4 * c) + 0] = aes_gf_mul2(b[(4 * c) + 0]) ^ aes_gf_mul3(b[(4 * c) + 1]) ^ b[(4 * c) + 2] ^ b[(4 * c) + 3];
            y[(4 * c) + 1] = b[(4 * c) + 0] ^ aes_gf_mul2(b[(4 * c) + 1]) ^ aes_gf_mul3(b[(4 * c) + 2]) ^ b[(4 * c) + 3];
            y[(4 * c) + 2] = b[(4 * c) + 0] ^ b[(4 * c) + 1] ^ aes_gf_mul2(b[(4 * c) + 2]) ^ aes_gf_mul3(b[(4 * c) + 3]);
            y[(4 * c) + 3] = aes_gf_mul3(b[(4 * c) + 0]) ^ b[(4 * c) + 1] ^ b[(4 * c) + 2] ^ aes_gf_mul2(b[(4 * c) + 3]);
        end

        for (i = 0; i < 16; i = i + 1) begin
            state_out[127 - (i * 8) -: 8] = y[i];
        end
    end
endmodule
