module aes256_gcm_tx_wrapper (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [255:0] key,
    
    // Control signals
    input  logic [31:0]  session_id,
    input  logic [31:0]  frame_counter,
    input  logic [31:0]  packet_counter,
    input  logic         flag_eof,
    input  logic         flag_sof,
    input  logic         flag_frame1,
    input  logic         flag_frame0,
    
    // AXI-Stream Input (Payload: 1280B = 80 blocks)
    input  logic [127:0] s_axis_tdata,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic         s_axis_tlast,
    
    // AXI-Stream Output (AAD + Ciphertext + TAG: 1312B = 82 blocks)
    output logic [127:0] m_axis_tdata,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic         m_axis_tlast,
    
    output logic         busy
);
    typedef enum logic [4:0] {
        T_IDLE,
        T_H_START,
        T_H_WAIT,
        T_OUT_AAD,
        T_INIT_START,
        T_INIT_WAIT,
        T_PAYLOAD_PRECOMPUTE_START,
        T_PAYLOAD_PRECOMPUTE_WAIT,
        T_PAYLOAD_WAIT_DATA,
        T_PAYLOAD_OUT,
        T_PAYLOAD_PARALLEL_START,
        T_PAYLOAD_PARALLEL_WAIT,
        T_GHASH_LEN_START,
        T_GHASH_LEN_WAIT,
        T_OUT_TAG
    } tx_state_t;

    tx_state_t state;

    logic [127:0] aad_block;
    logic [127:0] tag_mask_reg;
    logic [127:0] ghash_y_reg;
    logic [127:0] ciphertext_reg;
    logic [127:0] keystream_reg;
    logic [127:0] h_reg;
    logic [31:0]  block_ctr;
    logic [6:0]   payload_cnt; // up to 80

    // AES Core signals
    logic [127:0] aes_plaintext;
    logic [127:0] aes_ciphertext;
    logic         aes_start;
    logic         aes_busy;
    logic         aes_done;

    // GHASH Core signals
    logic [127:0] ghash_data_in;
    logic [127:0] ghash_y_in;
    logic [127:0] ghash_y_out;
    logic         ghash_start;
    logic         ghash_busy;
    logic         ghash_done;
    
    logic         init_aes_done_reg;
    logic         init_ghash_done_reg;

    aes256_core u_aes256_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (aes_start),
        .plaintext  (aes_plaintext),
        .key        (key),
        .ciphertext (aes_ciphertext),
        .busy       (aes_busy),
        .done       (aes_done)
    );

    ghash_engine_seq u_ghash_engine_seq (
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
    
    assign busy = (state != T_IDLE);

    always_comb begin
        aes_plaintext = 128'h0;
        aes_start     = 1'b0;
        
        unique case (state)
            T_H_START: begin
                aes_plaintext = 128'h0;
                aes_start     = 1'b1;
            end
            T_INIT_START: begin
                aes_plaintext = {aad_block[127:32], 32'd1}; // J0 = {IV, 1}
                aes_start     = 1'b1;
            end
            T_PAYLOAD_PRECOMPUTE_START: begin
                aes_plaintext = {aad_block[127:32], block_ctr};
                aes_start     = 1'b1;
            end
            T_PAYLOAD_PARALLEL_START: begin
                if (payload_cnt < 7'd79) begin
                    aes_plaintext = {aad_block[127:32], block_ctr + 32'd1};
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
            T_INIT_START: begin
                ghash_data_in = aad_block;
                ghash_y_in    = 128'h0;
                ghash_start   = 1'b1;
            end
            T_PAYLOAD_PARALLEL_START: begin
                ghash_data_in = ciphertext_reg;
                ghash_y_in    = ghash_y_reg;
                ghash_start   = 1'b1;
            end
            T_GHASH_LEN_START: begin
                ghash_data_in = {64'd128, 64'd10240}; // AAD 16B(128b), Payload 1280B(10240b)
                ghash_y_in    = ghash_y_reg;
                ghash_start   = 1'b1;
            end
            default: ;
        endcase
    end

    always_comb begin
        m_axis_tdata  = 128'h0;
        m_axis_tvalid = 1'b0;
        m_axis_tlast  = 1'b0;
        s_axis_tready = 1'b0;
        
        unique case (state)
            T_OUT_AAD: begin
                m_axis_tdata  = aad_block;
                m_axis_tvalid = 1'b1;
            end
            T_PAYLOAD_WAIT_DATA: begin
                s_axis_tready = 1'b1; // Consume plaintext block
            end
            T_PAYLOAD_OUT: begin
                m_axis_tdata  = ciphertext_reg;
                m_axis_tvalid = 1'b1;
                // Removed combinational dependency: s_axis_tready = m_axis_tready
            end
            T_OUT_TAG: begin
                m_axis_tdata  = tag_mask_reg ^ ghash_y_out; // final tag
                m_axis_tvalid = 1'b1;
                m_axis_tlast  = 1'b1;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= T_IDLE;
            aad_block           <= 128'h0;
            tag_mask_reg        <= 128'h0;
            ghash_y_reg         <= 128'h0;
            ciphertext_reg      <= 128'h0;
            keystream_reg       <= 128'h0;
            h_reg               <= 128'h0;
            block_ctr           <= 32'd2;
            payload_cnt         <= 7'd0;
            init_aes_done_reg   <= 1'b0;
            init_ghash_done_reg <= 1'b0;
        end else begin
            unique case (state)
                T_IDLE: begin
                    if (s_axis_tvalid) begin
                        // AAD = [Session ID || Frame || Packet || Reserve]
                        aad_block <= {session_id, frame_counter, packet_counter, 28'd0, flag_eof, flag_sof, flag_frame1, flag_frame0};
                        block_ctr <= 32'd2;
                        payload_cnt <= 7'd0;
                        state <= T_H_START;
                    end
                end
                
                T_H_START: begin
                    state <= T_H_WAIT;
                end
                
                T_H_WAIT: begin
                    if (aes_done) begin
                        h_reg <= aes_ciphertext;
                        state <= T_OUT_AAD;
                    end
                end
                
                T_OUT_AAD: begin
                    if (m_axis_tready) begin
                        init_aes_done_reg <= 1'b0;
                        init_ghash_done_reg <= 1'b0;
                        state <= T_INIT_START;
                    end
                end
                
                T_INIT_START: begin
                    state <= T_INIT_WAIT;
                end
                
                T_INIT_WAIT: begin
                    if (aes_done) begin
                        tag_mask_reg <= aes_ciphertext;
                        init_aes_done_reg <= 1'b1;
                    end
                    if (ghash_done) begin
                        ghash_y_reg <= ghash_y_out;
                        init_ghash_done_reg <= 1'b1;
                    end
                    if ((aes_done || init_aes_done_reg) && (ghash_done || init_ghash_done_reg)) begin
                        init_aes_done_reg <= 1'b0;
                        init_ghash_done_reg <= 1'b0;
                        state <= T_PAYLOAD_PRECOMPUTE_START;
                    end
                end
                
                T_PAYLOAD_PRECOMPUTE_START: begin
                    state <= T_PAYLOAD_PRECOMPUTE_WAIT;
                end
                
                T_PAYLOAD_PRECOMPUTE_WAIT: begin
                    if (aes_done) begin
                        keystream_reg <= aes_ciphertext;
                        state <= T_PAYLOAD_WAIT_DATA;
                    end
                end
                
                T_PAYLOAD_WAIT_DATA: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        ciphertext_reg <= s_axis_tdata ^ keystream_reg;
                        state <= T_PAYLOAD_OUT;
                    end
                end
                
                T_PAYLOAD_OUT: begin
                    if (m_axis_tready) begin
                        init_aes_done_reg   <= (payload_cnt == 7'd79) ? 1'b1 : 1'b0; // No AES on last block
                        init_ghash_done_reg <= 1'b0;
                        state <= T_PAYLOAD_PARALLEL_START;
                    end
                end
                
                T_PAYLOAD_PARALLEL_START: begin
                    state <= T_PAYLOAD_PARALLEL_WAIT;
                end
                
                T_PAYLOAD_PARALLEL_WAIT: begin
                    if (aes_done) begin
                        keystream_reg <= aes_ciphertext;
                        init_aes_done_reg <= 1'b1;
                    end
                    if (ghash_done) begin
                        ghash_y_reg <= ghash_y_out;
                        init_ghash_done_reg <= 1'b1;
                    end
                    
                    if ((aes_done || init_aes_done_reg) && (ghash_done || init_ghash_done_reg)) begin
                        block_ctr <= block_ctr + 32'd1;
                        if (payload_cnt == 7'd79) begin
                            state <= T_GHASH_LEN_START;
                        end else begin
                            payload_cnt <= payload_cnt + 7'd1;
                            state <= T_PAYLOAD_WAIT_DATA;
                        end
                    end
                end
                
                T_GHASH_LEN_START: begin
                    state <= T_GHASH_LEN_WAIT;
                end
                
                T_GHASH_LEN_WAIT: begin
                    if (ghash_done) begin
                        state <= T_OUT_TAG;
                    end
                end
                
                T_OUT_TAG: begin
                    if (m_axis_tready) begin
                        state <= T_IDLE;
                    end
                end
                
                default: state <= T_IDLE;
            endcase
        end
    end
endmodule
