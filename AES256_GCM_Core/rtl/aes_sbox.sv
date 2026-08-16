import aes_pkg::*;

module aes_sbox (
    input  logic [7:0] byte_in,
    output logic [7:0] byte_out
);
    assign byte_out = aes_sbox_byte(byte_in);
endmodule
