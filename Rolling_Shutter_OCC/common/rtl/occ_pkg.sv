package occ_pkg;

    // Packet on the optical link:
    //   SYNC(16) | PASSWORD(16) | CRC8(password)   = 40 bits
    //
    // 40 bits at four camera rows per bit is 160 rows out of the 240 a QVGA frame
    // delivers, which leaves an 80-row window for the packet to land in. With the
    // tag transmitting back to back that is roughly a one-in-two chance per frame,
    // so a tap lands about fifteen decodes a second. A wider password would shrink
    // that window fast: 24 bits of password costs 32 more rows and halves it again.
    localparam logic [15:0] SYNC_WORD   = 16'hAAD3;
    localparam int unsigned HEADER_BITS = 16;
    localparam int unsigned PW_BITS     = 16;
    localparam int unsigned CRC_BITS    = 8;
    localparam int unsigned PACKET_BITS = HEADER_BITS + PW_BITS + CRC_BITS;

    // Sixteen demo credentials. The tag picks one with SW3:SW0 and the reader picks
    // the one it will accept the same way, so a match and a mismatch can both be
    // shown without rebuilding either board.
    function automatic logic [15:0] password(input logic [3:0] slot);
        case (slot)
            4'h0:    password = 16'h1234;
            4'h1:    password = 16'hA1B2;
            4'h2:    password = 16'hC0DE;
            4'h3:    password = 16'hBEEF;
            4'h4:    password = 16'h0FF1;
            4'h5:    password = 16'h5A5A;
            4'h6:    password = 16'hCAFE;
            4'h7:    password = 16'h7E57;
            4'h8:    password = 16'hFACE;
            4'h9:    password = 16'h9001;
            4'hA:    password = 16'hD00D;
            4'hB:    password = 16'hB105;
            4'hC:    password = 16'h1CE1;
            4'hD:    password = 16'hDEAD;
            4'hE:    password = 16'hE1EC;
            default: password = 16'hF00D;
        endcase
    endfunction

    function automatic logic [7:0] crc8_byte(
        input logic [7:0] crc_in,
        input logic [7:0] data_in
    );
        logic [7:0] crc;
        integer i;
        begin
            crc = crc_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[7] ^ data_in[7-i])
                    crc = {crc[6:0], 1'b0} ^ 8'h07;
                else
                    crc = {crc[6:0], 1'b0};
            end
            return crc;
        end
    endfunction

    function automatic logic [7:0] password_crc(input logic [15:0] value);
        logic [7:0] crc;
        begin
            crc = crc8_byte(8'h00, value[15:8]);
            crc = crc8_byte(crc, value[7:0]);
            return crc;
        end
    endfunction

    // Common-anode segments, active low: bit0 = a, bit1 = b ... bit6 = g, bit7 = dp.
    function automatic logic [7:0] seg_hex(input logic [3:0] nibble);
        case (nibble)
            4'h0:    seg_hex = 8'hC0;
            4'h1:    seg_hex = 8'hF9;
            4'h2:    seg_hex = 8'hA4;
            4'h3:    seg_hex = 8'hB0;
            4'h4:    seg_hex = 8'h99;
            4'h5:    seg_hex = 8'h92;
            4'h6:    seg_hex = 8'h82;
            4'h7:    seg_hex = 8'hF8;
            4'h8:    seg_hex = 8'h80;
            4'h9:    seg_hex = 8'h90;
            4'hA:    seg_hex = 8'h88;
            4'hB:    seg_hex = 8'h83;
            4'hC:    seg_hex = 8'hC6;
            4'hD:    seg_hex = 8'hA1;
            4'hE:    seg_hex = 8'h86;
            default: seg_hex = 8'h8E;
        endcase
    endfunction

    function automatic logic [7:0] hex_ascii(input logic [3:0] nibble);
        hex_ascii = (nibble < 4'd10) ? (8'h30 + 8'(nibble))
                                     : (8'h41 + 8'(nibble) - 8'd10);
    endfunction

    localparam logic [7:0] SEG_BLANK = 8'hFF;
    localparam logic [7:0] SEG_DASH  = 8'hBF;

    function automatic logic [31:0] seg_word(input logic [15:0] value);
        seg_word = {seg_hex(value[15:12]), seg_hex(value[11:8]),
                    seg_hex(value[7:4]),   seg_hex(value[3:0])};
    endfunction

endpackage
