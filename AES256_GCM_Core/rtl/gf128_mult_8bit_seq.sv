module gf128_mult_8bit_seq (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [127:0] x,
    input  logic [127:0] y,
    output logic [127:0] product,
    output logic         busy,
    output logic         done
);
    typedef enum logic [1:0] {
        M_IDLE,
        M_RUN,
        M_DONE
    } mult_state_t;

    localparam logic [127:0] R_POLY = 128'he1000000000000000000000000000000;

    mult_state_t state;

    logic [127:0] x_reg;
    logic [127:0] z_reg;
    logic [127:0] v_reg;
    logic [127:0] z_next;
    logic [127:0] v_next;
    logic [3:0]   byte_index;
    logic [7:0]   x_byte;
    logic [255:0] step8_next;

    assign busy = (state == M_RUN);
    assign done = (state == M_DONE);

    // Always consume the most-significant byte. Shifting x_reg after each
    // step avoids a byte_index-controlled 16:1 mux on the GHASH critical path.
    assign x_byte     = x_reg[127:120];
    assign step8_next = gf128_step8(z_reg, v_reg, x_byte);
    assign z_next     = step8_next[255:128];
    assign v_next     = step8_next[127:0];

    function automatic [255:0] gf128_step8(
        input logic [127:0] z_in,
        input logic [127:0] v_in,
        input logic [7:0]   x_bits
    );
        logic [127:0] z_tmp;
        logic [127:0] v_tmp;
        begin
            z_tmp = z_in;
            v_tmp = v_in;

            for (int i = 0; i < 8; i++) begin
                if (x_bits[7 - i]) begin
                    z_tmp = z_tmp ^ v_tmp;
                end

                if (v_tmp[0]) begin
                    v_tmp = (v_tmp >> 1) ^ R_POLY;
                end else begin
                    v_tmp = v_tmp >> 1;
                end
            end

            gf128_step8 = {z_tmp, v_tmp};
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= M_IDLE;
            x_reg      <= 128'h0;
            z_reg      <= 128'h0;
            v_reg      <= 128'h0;
            byte_index <= 4'd0;
            product    <= 128'h0;
        end else begin
            unique case (state)
                M_IDLE: begin
                    if (start) begin
                        x_reg      <= x;
                        z_reg      <= 128'h0;
                        v_reg      <= y;
                        byte_index <= 4'd0;
                        product    <= 128'h0;
                        state      <= M_RUN;
                    end
                end

                M_RUN: begin
                    x_reg <= {x_reg[119:0], 8'h00};
                    z_reg <= z_next;
                    v_reg <= v_next;

                    if (byte_index == 4'd15) begin
                        product <= z_next;
                        state   <= M_DONE;
                    end else begin
                        byte_index <= byte_index + 4'd1;
                    end
                end

                M_DONE: begin
                    state <= M_IDLE;
                end

                default: begin
                    state <= M_IDLE;
                end
            endcase
        end
    end
endmodule
