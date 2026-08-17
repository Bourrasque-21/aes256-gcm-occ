import gcm_packet_pkg::*;

module gcm_rx_engine (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         cmd_valid,
    output logic         cmd_ready,
    input  logic [255:0] cmd_key,
    input  logic [95:0]  cmd_iv,
    input  logic [127:0] cmd_aad,
    input  logic [31:0]  cmd_payload_blocks,

    input  logic [127:0] ciphertext_data,
    input  logic         ciphertext_valid,
    output logic         ciphertext_ready,

    // Plaintext is untrusted until auth_valid && auth_ok. The integration
    // layer must quarantine these blocks before exposing them downstream.
    output logic [127:0] plaintext_data,
    output logic         plaintext_valid,
    output logic         plaintext_last,
    input  logic         plaintext_ready,

    input  logic [127:0] received_tag,
    input  logic         received_tag_valid,
    output logic         received_tag_ready,
    output logic         auth_valid,
    output logic         auth_ok,
    input  logic         auth_ready,

    input  logic         abort,
    output logic         busy
);
    typedef enum logic [3:0] {
        E_IDLE,
        E_H_START,
        E_H_WAIT,
        E_INIT_START,
        E_INIT_WAIT,
        E_WAIT_CIPHERTEXT,
        E_PARALLEL_START,
        E_PARALLEL_WAIT,
        E_PLAINTEXT_OUT,
        E_LEN_START,
        E_LEN_WAIT,
        E_TAG_WAIT,
        E_AUTH_OUT,
        E_ABORT
    } engine_state_t;

    engine_state_t state;

    logic [255:0] key_reg;
    logic [95:0]  iv_reg;
    logic [127:0] aad_reg;
    logic [31:0]  payload_blocks_reg;
    logic [63:0]  payload_bits_reg;

    logic [127:0] h_reg;
    logic [255:0] h_key_reg;
    logic         h_valid;

    logic [127:0] tag_mask_reg;
    logic [127:0] ghash_y_reg;
    logic [127:0] ciphertext_reg;
    logic [127:0] keystream_reg;
    logic [127:0] plaintext_reg;
    logic         plaintext_last_reg;
    logic [127:0] computed_tag_reg;
    logic         auth_ok_reg;
    logic [31:0]  block_ctr;
    logic [31:0]  block_index;
    logic         current_block_last_reg;

    logic aes_complete_reg;
    logic ghash_complete_reg;

    logic [127:0] aes_plaintext;
    logic [127:0] aes_ciphertext;
    logic         aes_start;
    logic         aes_busy;
    logic         aes_done;

    logic [127:0] ghash_data_in;
    logic [127:0] ghash_y_in;
    logic [127:0] ghash_y_out;
    logic         ghash_start;
    logic         ghash_busy;
    logic         ghash_done;

    aes256_core u_aes256_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (aes_start),
        .plaintext  (aes_plaintext),
        .key        (key_reg),
        .ciphertext (aes_ciphertext),
        .busy       (aes_busy),
        .done       (aes_done)
    );

    ghash_engine_seq u_ghash_engine (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (ghash_start),
        .h       (h_reg),
        .data_in (ghash_data_in),
        .y_in    (ghash_y_in),
        .y_out   (ghash_y_out),
        .busy    (ghash_busy),
        .done    (ghash_done)
    );

    assign cmd_ready          = (state == E_IDLE) && !abort;
    assign busy               = (state != E_IDLE);
    assign ciphertext_ready   = (state == E_WAIT_CIPHERTEXT);
    assign plaintext_data     = plaintext_reg;
    assign plaintext_valid    = (state == E_PLAINTEXT_OUT);
    assign plaintext_last     = plaintext_last_reg;
    assign received_tag_ready = (state == E_TAG_WAIT);
    assign auth_valid         = (state == E_AUTH_OUT);
    assign auth_ok            = auth_ok_reg;

    always_comb begin
        aes_plaintext = 128'h0;
        aes_start     = 1'b0;

        unique case (state)
            E_H_START: begin
                aes_plaintext = 128'h0;
                aes_start     = 1'b1;
            end
            E_INIT_START: begin
                aes_plaintext = {iv_reg, 32'd1};
                aes_start     = 1'b1;
            end
            E_PARALLEL_START: begin
                aes_plaintext = {iv_reg, block_ctr};
                aes_start     = 1'b1;
            end
            default: ;
        endcase
    end

    always_comb begin
        ghash_data_in = 128'h0;
        ghash_y_in    = 128'h0;
        ghash_start   = 1'b0;

        unique case (state)
            E_INIT_START: begin
                ghash_data_in = aad_reg;
                ghash_y_in    = 128'h0;
                ghash_start   = 1'b1;
            end
            E_PARALLEL_START: begin
                ghash_data_in = ciphertext_reg;
                ghash_y_in    = ghash_y_reg;
                ghash_start   = 1'b1;
            end
            E_LEN_START: begin
                ghash_data_in = build_len_block(64'd128,
                                                payload_bits_reg);
                ghash_y_in    = ghash_y_reg;
                ghash_start   = 1'b1;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= E_IDLE;
            key_reg                <= 256'h0;
            iv_reg                 <= 96'h0;
            aad_reg                <= 128'h0;
            payload_blocks_reg     <= 32'h0;
            payload_bits_reg       <= 64'h0;
            h_reg                  <= 128'h0;
            h_key_reg              <= 256'h0;
            h_valid                <= 1'b0;
            tag_mask_reg           <= 128'h0;
            ghash_y_reg            <= 128'h0;
            ciphertext_reg         <= 128'h0;
            keystream_reg          <= 128'h0;
            plaintext_reg          <= 128'h0;
            plaintext_last_reg     <= 1'b0;
            computed_tag_reg       <= 128'h0;
            auth_ok_reg            <= 1'b0;
            block_ctr              <= 32'd2;
            block_index            <= 32'd0;
            current_block_last_reg <= 1'b0;
            aes_complete_reg       <= 1'b0;
            ghash_complete_reg     <= 1'b0;
        end else if (abort && (state != E_IDLE)) begin
            state                  <= E_ABORT;
            aes_complete_reg       <= 1'b0;
            ghash_complete_reg     <= 1'b0;
            auth_ok_reg            <= 1'b0;
            current_block_last_reg <= 1'b0;
        end else begin
            unique case (state)
                E_IDLE: begin
                    aes_complete_reg   <= 1'b0;
                    ghash_complete_reg <= 1'b0;
                    auth_ok_reg        <= 1'b0;

                    if (cmd_valid && cmd_ready) begin
                        key_reg            <= cmd_key;
                        iv_reg             <= cmd_iv;
                        aad_reg            <= cmd_aad;
                        payload_blocks_reg <= cmd_payload_blocks;
                        payload_bits_reg   <=
                            {32'h0, cmd_payload_blocks} << 7;
                        block_ctr          <= 32'd2;
                        block_index        <= 32'd0;
                        current_block_last_reg <= 1'b0;
                        ghash_y_reg        <= 128'h0;

                        if (h_valid && (cmd_key == h_key_reg)) begin
                            state <= E_INIT_START;
                        end else begin
                            state <= E_H_START;
                        end
                    end
                end

                E_H_START: state <= E_H_WAIT;

                E_H_WAIT: begin
                    if (aes_done) begin
                        h_reg     <= aes_ciphertext;
                        h_key_reg <= key_reg;
                        h_valid   <= 1'b1;
                        state     <= E_INIT_START;
                    end
                end

                E_INIT_START: begin
                    aes_complete_reg   <= 1'b0;
                    ghash_complete_reg <= 1'b0;
                    state              <= E_INIT_WAIT;
                end

                E_INIT_WAIT: begin
                    if (aes_done) begin
                        tag_mask_reg     <= aes_ciphertext;
                        aes_complete_reg <= 1'b1;
                    end
                    if (ghash_done) begin
                        ghash_y_reg        <= ghash_y_out;
                        ghash_complete_reg <= 1'b1;
                    end
                    if ((aes_done || aes_complete_reg) &&
                        (ghash_done || ghash_complete_reg)) begin
                        aes_complete_reg   <= 1'b0;
                        ghash_complete_reg <= 1'b0;
                        if (payload_blocks_reg == 32'd0)
                            state <= E_LEN_START;
                        else
                            state <= E_WAIT_CIPHERTEXT;
                    end
                end

                E_WAIT_CIPHERTEXT: begin
                    if (ciphertext_valid && ciphertext_ready) begin
                        ciphertext_reg <= ciphertext_data;
                        current_block_last_reg <=
                            ((block_index + 32'd1) >=
                             payload_blocks_reg);
                        aes_complete_reg   <= 1'b0;
                        ghash_complete_reg <= 1'b0;
                        state              <= E_PARALLEL_START;
                    end
                end

                E_PARALLEL_START: state <= E_PARALLEL_WAIT;

                E_PARALLEL_WAIT: begin
                    if (aes_done) begin
                        keystream_reg    <= aes_ciphertext;
                        aes_complete_reg <= 1'b1;
                    end
                    if (ghash_done) begin
                        ghash_y_reg        <= ghash_y_out;
                        ghash_complete_reg <= 1'b1;
                    end
                    if ((aes_done || aes_complete_reg) &&
                        (ghash_done || ghash_complete_reg)) begin
                        plaintext_reg <= ciphertext_reg ^
                            (aes_done ? aes_ciphertext : keystream_reg);
                        plaintext_last_reg <= current_block_last_reg;
                        aes_complete_reg   <= 1'b0;
                        ghash_complete_reg <= 1'b0;
                        state              <= E_PLAINTEXT_OUT;
                    end
                end

                E_PLAINTEXT_OUT: begin
                    if (plaintext_valid && plaintext_ready) begin
                        block_ctr <= block_ctr + 32'd1;
                        if (current_block_last_reg) begin
                            state <= E_LEN_START;
                        end else begin
                            block_index <= block_index + 32'd1;
                            state       <= E_WAIT_CIPHERTEXT;
                        end
                    end
                end

                E_LEN_START: state <= E_LEN_WAIT;

                E_LEN_WAIT: begin
                    if (ghash_done) begin
                        computed_tag_reg <= tag_mask_reg ^ ghash_y_out;
                        state            <= E_TAG_WAIT;
                    end
                end

                E_TAG_WAIT: begin
                    if (received_tag_valid && received_tag_ready) begin
                        auth_ok_reg <= (received_tag == computed_tag_reg);
                        state       <= E_AUTH_OUT;
                    end
                end

                E_AUTH_OUT: begin
                    if (auth_valid && auth_ready)
                        state <= E_IDLE;
                end

                E_ABORT: begin
                    if (!aes_busy && !ghash_busy)
                        state <= E_IDLE;
                end

                default: state <= E_IDLE;
            endcase
        end
    end
endmodule
