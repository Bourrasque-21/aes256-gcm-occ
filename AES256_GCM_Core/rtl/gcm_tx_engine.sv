import gcm_packet_pkg::*;

module gcm_tx_engine (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         cmd_valid,
    output logic         cmd_ready,
    input  logic [255:0] cmd_key,
    input  logic [95:0]  cmd_iv,
    input  logic [127:0] cmd_aad,
    input  logic [31:0]  cmd_payload_blocks,

    input  logic [127:0] plaintext_data,
    input  logic         plaintext_valid,
    output logic         plaintext_ready,

    output logic [127:0] ciphertext_data,
    output logic         ciphertext_valid,
    input  logic         ciphertext_ready,

    output logic [127:0] tag_data,
    output logic         tag_valid,
    input  logic         tag_ready,

    input  logic         abort,
    output logic         busy
);
    typedef enum logic [3:0] {
        E_IDLE,
        E_H_START,
        E_H_WAIT,
        E_INIT_START,
        E_INIT_WAIT,
        E_PRECOMPUTE_START,
        E_PRECOMPUTE_WAIT,
        E_WAIT_PLAINTEXT,
        E_CIPHERTEXT_OUT,
        E_PARALLEL_START,
        E_PARALLEL_WAIT,
        E_LEN_START,
        E_LEN_WAIT,
        E_TAG_OUT,
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
    logic [127:0] keystream_reg;
    logic [127:0] ciphertext_reg;
    logic [127:0] tag_reg;
    logic [31:0]  block_ctr;
    logic [31:0]  block_index;

    logic aes_complete_reg;
    logic ghash_complete_reg;
    logic next_block_exists_reg;

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

    assign cmd_ready        = (state == E_IDLE) && !abort;
    assign busy             = (state != E_IDLE);
    assign plaintext_ready  = (state == E_WAIT_PLAINTEXT);
    assign ciphertext_data  = ciphertext_reg;
    assign ciphertext_valid = (state == E_CIPHERTEXT_OUT);
    assign tag_data         = tag_reg;
    assign tag_valid        = (state == E_TAG_OUT);

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

            E_PRECOMPUTE_START: begin
                aes_plaintext = {iv_reg, block_ctr};
                aes_start     = 1'b1;
            end

            E_PARALLEL_START: begin
                if (next_block_exists_reg) begin
                    aes_plaintext = {iv_reg, block_ctr + 32'd1};
                    aes_start     = 1'b1;
                end
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
            state                 <= E_IDLE;
            key_reg               <= 256'h0;
            iv_reg                <= 96'h0;
            aad_reg               <= 128'h0;
            payload_blocks_reg    <= 32'h0;
            payload_bits_reg      <= 64'h0;
            h_reg                 <= 128'h0;
            h_key_reg             <= 256'h0;
            h_valid               <= 1'b0;
            tag_mask_reg          <= 128'h0;
            ghash_y_reg           <= 128'h0;
            keystream_reg         <= 128'h0;
            ciphertext_reg        <= 128'h0;
            tag_reg               <= 128'h0;
            block_ctr             <= 32'd2;
            block_index           <= 32'd0;
            aes_complete_reg      <= 1'b0;
            ghash_complete_reg    <= 1'b0;
            next_block_exists_reg <= 1'b0;
        end else if (abort && (state != E_IDLE)) begin
            state                 <= E_ABORT;
            aes_complete_reg      <= 1'b0;
            ghash_complete_reg    <= 1'b0;
            next_block_exists_reg <= 1'b0;
        end else begin
            unique case (state)
                E_IDLE: begin
                    aes_complete_reg   <= 1'b0;
                    ghash_complete_reg <= 1'b0;

                    if (cmd_valid && cmd_ready) begin
                        key_reg            <= cmd_key;
                        iv_reg             <= cmd_iv;
                        aad_reg            <= cmd_aad;
                        payload_blocks_reg <= cmd_payload_blocks;
                        payload_bits_reg   <=
                            {32'h0, cmd_payload_blocks} << 7;
                        block_ctr          <= 32'd2;
                        block_index        <= 32'd0;
                        ghash_y_reg        <= 128'h0;
                        next_block_exists_reg <= 1'b0;

                        if (h_valid && (cmd_key == h_key_reg))
                            state <= E_INIT_START;
                        else
                            state <= E_H_START;
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
                            state <= E_PRECOMPUTE_START;
                    end
                end

                E_PRECOMPUTE_START: state <= E_PRECOMPUTE_WAIT;

                E_PRECOMPUTE_WAIT: begin
                    if (aes_done) begin
                        keystream_reg <= aes_ciphertext;
                        state         <= E_WAIT_PLAINTEXT;
                    end
                end

                E_WAIT_PLAINTEXT: begin
                    if (plaintext_valid && plaintext_ready) begin
                        ciphertext_reg <= plaintext_data ^ keystream_reg;
                        state          <= E_CIPHERTEXT_OUT;
                    end
                end

                E_CIPHERTEXT_OUT: begin
                    if (ciphertext_valid && ciphertext_ready) begin
                        if ((block_index + 32'd1) < payload_blocks_reg) begin
                            next_block_exists_reg <= 1'b1;
                            aes_complete_reg      <= 1'b0;
                        end else begin
                            next_block_exists_reg <= 1'b0;
                            aes_complete_reg      <= 1'b1;
                        end
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
                        aes_complete_reg   <= 1'b0;
                        ghash_complete_reg <= 1'b0;
                        block_ctr          <= block_ctr + 32'd1;
                        if (!next_block_exists_reg) begin
                            state <= E_LEN_START;
                        end else begin
                            block_index <= block_index + 32'd1;
                            state       <= E_WAIT_PLAINTEXT;
                        end
                    end
                end

                E_LEN_START: state <= E_LEN_WAIT;

                E_LEN_WAIT: begin
                    if (ghash_done) begin
                        tag_reg <= tag_mask_reg ^ ghash_y_out;
                        state   <= E_TAG_OUT;
                    end
                end

                E_TAG_OUT: begin
                    if (tag_valid && tag_ready)
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
