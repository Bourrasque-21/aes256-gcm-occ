package gcm_packet_pkg;
    localparam int AES_BLOCK_BITS = 128;
    localparam int AES_KEY_BITS   = 256;
    localparam int GCM_IV_BITS    = 96;
    localparam int GCM_TAG_BITS   = 128;
    localparam int AAD_BITS       = 128;

    function automatic logic [127:0] build_len_block(
        input logic [63:0] aad_bit_length,
        input logic [63:0] payload_bit_length
    );
        build_len_block = {aad_bit_length, payload_bit_length};
    endfunction
endpackage
