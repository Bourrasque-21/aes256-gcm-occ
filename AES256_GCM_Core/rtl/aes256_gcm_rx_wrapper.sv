module aes256_gcm_rx_wrapper (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [255:0] key,
    
    input  logic [31:0]  expected_session_id,
    
    // AXI-Stream Input (1312B = 82 blocks)
    input  logic [127:0] s_axis_tdata,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic         s_axis_tlast,
    
    // AXI-Stream Output (one authenticated 720p line: 2560B = 160 blocks)
    output logic [127:0] m_axis_tdata,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic         m_axis_tlast,
    
    // Errors
    output logic         anti_replay_err,
    output logic         packet_loss_err,
    output logic         auth_fail_err,
    output logic         length_err,
    output logic         session_err,
    output logic         timeout_err,
    
    output logic         busy
);
    typedef enum logic [4:0] {
        R_IDLE,
        R_H_START,
        R_H_WAIT,
        R_INIT_START,
        R_INIT_WAIT,
        R_PAYLOAD_WAIT_DATA,
        R_PAYLOAD_WAIT_PARALLEL,
        R_GHASH_LEN_START,
        R_GHASH_LEN_WAIT,
        R_TAG_VERIFY,
        R_LINE_OUT_PREP,
        R_LINE_OUT
    } rx_state_t;

    rx_state_t state;

    logic [127:0] aad_block;
    logic [127:0] tag_mask_reg;
    logic [127:0] ghash_y_reg;
    logic [127:0] ciphertext_reg;
    logic [127:0] h_reg;
    logic [31:0]  block_ctr;
    logic [6:0]   payload_cnt;
    
    logic [31:0]  stored_frame;
    logic [31:0]  stored_packet;
    logic         history_valid;
    
    // Two authenticated packets form one 720p line.
    // The array is intentionally not reset so synthesis can infer RAM.
    logic [127:0] plaintext_line_buffer [0:159];
    logic         first_packet_valid;
    logic [31:0]  line_frame_reg;
    logic [31:0]  line_first_packet_reg;
    logic [7:0]   line_out_cnt;
    logic [127:0] line_out_data_reg;
    
    logic [15:0]  timeout_cnt;

    // Error latches for this packet
    logic         cur_replay_err;
    logic         cur_loss_err;
    logic         cur_session_err;

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
    
    assign busy = (state != R_IDLE) || first_packet_valid;

    always_comb begin
        aes_plaintext = 128'h0;
        aes_start     = 1'b0;
        unique case (state)
            R_H_START: begin
                aes_plaintext = 128'h0;
                aes_start     = 1'b1;
            end
            R_INIT_START: begin
                aes_plaintext = {aad_block[127:32], 32'd1}; // J0 = {IV, 1}
                aes_start     = 1'b1;
            end
            R_PAYLOAD_WAIT_DATA: begin
                if (s_axis_tvalid) begin
                    aes_plaintext = {aad_block[127:32], block_ctr};
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
            R_INIT_START: begin
                ghash_data_in = aad_block;
                ghash_y_in    = 128'h0;
                ghash_start   = 1'b1;
            end
            R_PAYLOAD_WAIT_DATA: begin
                if (s_axis_tvalid) begin
                    ghash_data_in = s_axis_tdata;
                    ghash_y_in    = ghash_y_reg;
                    ghash_start   = 1'b1;
                end
            end
            R_GHASH_LEN_START: begin
                ghash_data_in = {64'd128, 64'd10240}; // AAD 16B, Payload 1280B
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
            R_IDLE: begin
                s_axis_tready = 1'b1; // consume AAD
            end
            R_PAYLOAD_WAIT_DATA: begin
                s_axis_tready = 1'b1; // consume one ciphertext block
            end
            R_TAG_VERIFY: begin
                s_axis_tready = 1'b1; // consume TAG
            end
            R_LINE_OUT: begin
                m_axis_tdata  = line_out_data_reg;
                m_axis_tvalid = 1'b1;
                m_axis_tlast  = (line_out_cnt == 8'd159);
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= R_IDLE;
            aad_block       <= 128'h0;
            tag_mask_reg    <= 128'h0;
            ghash_y_reg     <= 128'h0;
            ciphertext_reg  <= 128'h0;
            h_reg           <= 128'h0;
            block_ctr       <= 32'd2;
            payload_cnt     <= 7'd0;
            timeout_cnt     <= 16'd0;
            
            stored_frame    <= 32'h0;
            stored_packet   <= 32'h0;
            history_valid   <= 1'b0;
            
            first_packet_valid   <= 1'b0;
            line_frame_reg       <= 32'h0;
            line_first_packet_reg <= 32'h0;
            line_out_cnt         <= 8'd0;
            line_out_data_reg    <= 128'h0;
            
            anti_replay_err <= 1'b0;
            packet_loss_err <= 1'b0;
            auth_fail_err   <= 1'b0;
            length_err      <= 1'b0;
            session_err     <= 1'b0;
            timeout_err     <= 1'b0;
            
            cur_replay_err  <= 1'b0;
            cur_loss_err    <= 1'b0;
            cur_session_err <= 1'b0;
            
            init_aes_done_reg   <= 1'b0;
            init_ghash_done_reg <= 1'b0;
        end else begin
            // Default pulse clear for errors
            anti_replay_err <= 1'b0;
            packet_loss_err <= 1'b0;
            auth_fail_err   <= 1'b0;
            length_err      <= 1'b0;
            session_err     <= 1'b0;
            timeout_err     <= 1'b0;
            
            // Timeout while waiting for the second packet, payload data, or TAG.
            if ((state == R_IDLE && first_packet_valid) ||
                state == R_PAYLOAD_WAIT_DATA ||
                state == R_TAG_VERIFY) begin
                if (!s_axis_tvalid) begin
                    timeout_cnt <= timeout_cnt + 16'd1;
                    if (timeout_cnt > 16'd1000) begin
                        timeout_err        <= 1'b1;
                        first_packet_valid <= 1'b0;
                        state              <= R_IDLE;
                    end
                end else begin
                    timeout_cnt <= 16'd0;
                end
            end else begin
                timeout_cnt <= 16'd0;
            end

            unique case (state)
                R_IDLE: begin
                    init_aes_done_reg   <= 1'b0;
                    init_ghash_done_reg <= 1'b0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        aad_block <= s_axis_tdata;
                        
                        // Check Anti-Replay
                        if (history_valid &&
                            {s_axis_tdata[95:64], s_axis_tdata[63:32]} <=
                            {stored_frame, stored_packet}) begin
                            cur_replay_err <= 1'b1;
                        end else begin
                            cur_replay_err <= 1'b0;
                        end
                        
                        // Check Packet Loss
                        if (history_valid &&
                            s_axis_tdata[63:32] > stored_packet + 32'd1) begin
                            cur_loss_err <= 1'b1;
                        end else begin
                            cur_loss_err <= 1'b0;
                        end
                        
                        // Check Session
                        if (s_axis_tdata[127:96] != expected_session_id) begin
                            cur_session_err <= 1'b1;
                        end else begin
                            cur_session_err <= 1'b0;
                        end
                        
                        if (s_axis_tlast) begin
                            length_err        <= 1'b1; // AAD cannot be the last block.
                            first_packet_valid <= 1'b0;
                            state              <= R_IDLE;
                        end else begin
                            state <= R_H_START;
                        end
                        block_ctr <= 32'd2;
                        payload_cnt <= 7'd0;
                    end
                end
                
                R_H_START: state <= R_H_WAIT;
                
                R_H_WAIT: begin
                    if (aes_done) begin
                        h_reg <= aes_ciphertext;
                        state <= R_INIT_START;
                    end
                end
                
                R_INIT_START: state <= R_INIT_WAIT;
                
                R_INIT_WAIT: begin
                    if (aes_done) begin
                        tag_mask_reg      <= aes_ciphertext;
                        init_aes_done_reg <= 1'b1;
                    end
                    if (ghash_done) begin
                        ghash_y_reg         <= ghash_y_out;
                        init_ghash_done_reg <= 1'b1;
                    end
                    if ((aes_done || init_aes_done_reg) &&
                        (ghash_done || init_ghash_done_reg)) begin
                        init_aes_done_reg   <= 1'b0;
                        init_ghash_done_reg <= 1'b0;
                        state               <= R_PAYLOAD_WAIT_DATA;
                    end
                end
                
                R_PAYLOAD_WAIT_DATA: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        ciphertext_reg <= s_axis_tdata;
                        if (s_axis_tlast) begin
                            length_err        <= 1'b1; // Only TAG may assert TLAST.
                            first_packet_valid <= 1'b0;
                            state              <= R_IDLE;
                        end else begin
                            init_aes_done_reg   <= 1'b0;
                            init_ghash_done_reg <= 1'b0;
                            state <= R_PAYLOAD_WAIT_PARALLEL;
                        end
                    end
                end
                
                R_PAYLOAD_WAIT_PARALLEL: begin
                    if (aes_done) begin
                        plaintext_line_buffer[
                            (aad_block[32] ? 8'd80 : 8'd0) +
                            {1'b0, payload_cnt}
                        ] <= ciphertext_reg ^ aes_ciphertext;
                        init_aes_done_reg <= 1'b1;
                    end
                    if (ghash_done) begin
                        ghash_y_reg <= ghash_y_out;
                        init_ghash_done_reg <= 1'b1;
                    end
                    
                    if ((aes_done || init_aes_done_reg) && (ghash_done || init_ghash_done_reg)) begin
                        block_ctr <= block_ctr + 32'd1;
                        if (payload_cnt == 7'd79) begin
                            // Start the LEN GHASH operation only after the
                            // GHASH engine has returned to H_IDLE. This keeps
                            // correctness independent of whether AES or GHASH
                            // finishes the final payload block first.
                            init_aes_done_reg   <= 1'b0;
                            init_ghash_done_reg <= 1'b0;
                            state <= R_GHASH_LEN_START;
                        end else begin
                            payload_cnt <= payload_cnt + 7'd1;
                            init_aes_done_reg   <= 1'b0;
                            init_ghash_done_reg <= 1'b0;
                            state <= R_PAYLOAD_WAIT_DATA;
                        end
                    end
                end
                
                R_GHASH_LEN_START: state <= R_GHASH_LEN_WAIT;
                
                R_GHASH_LEN_WAIT: begin
                    if (ghash_done) state <= R_TAG_VERIFY;
                end
                
                R_TAG_VERIFY: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (!s_axis_tlast) begin
                            length_err        <= 1'b1;
                            first_packet_valid <= 1'b0;
                            state              <= R_IDLE;
                        end else if (s_axis_tdata !=
                                     (tag_mask_reg ^ ghash_y_out)) begin
                            auth_fail_err      <= 1'b1;
                            first_packet_valid <= 1'b0;
                            state              <= R_IDLE;
                        end else begin
                            anti_replay_err <= cur_replay_err;
                            packet_loss_err <= cur_loss_err;
                            session_err     <= cur_session_err;
                            
                            if (cur_replay_err || cur_session_err) begin
                                first_packet_valid <= 1'b0;
                                state              <= R_IDLE;
                            end else begin
                                // Commit every authenticated packet. Packet loss
                                // is reported, but the receiver can resynchronize
                                // on the next even-numbered first-half packet.
                                stored_frame          <= aad_block[95:64];
                                stored_packet         <= aad_block[63:32];
                                history_valid         <= 1'b1;
                                
                                if (aad_block[32] == 1'b0) begin
                                    // Protocol rule: even packet counter is the
                                    // first half of a 720p line.
                                    line_frame_reg <= aad_block[95:64];
                                    line_first_packet_reg <=
                                        aad_block[63:32];
                                    first_packet_valid <= 1'b1;
                                    state              <= R_IDLE;
                                end else if (!first_packet_valid ||
                                             (aad_block[95:64] !=
                                              line_frame_reg) ||
                                             (aad_block[63:32] !=
                                              line_first_packet_reg +
                                              32'd1)) begin
                                    // An odd packet is released only when its
                                    // authenticated even-numbered first half is
                                    // already present in the line buffer.
                                    packet_loss_err       <= 1'b1;
                                    first_packet_valid    <= 1'b0;
                                    state                 <= R_IDLE;
                                end else begin
                                    // Authenticated odd-numbered second half:
                                    // release the complete 160-beat line.
                                    state <= R_LINE_OUT_PREP;
                                end
                            end
                        end
                    end
                end
                
                R_LINE_OUT_PREP: begin
                    line_out_cnt      <= 8'd0;
                    line_out_data_reg <= plaintext_line_buffer[0];
                    state             <= R_LINE_OUT;
                end
                
                R_LINE_OUT: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (line_out_cnt == 8'd159) begin
                            first_packet_valid <= 1'b0;
                            state              <= R_IDLE;
                        end else begin
                            line_out_cnt <= line_out_cnt + 8'd1;
                            line_out_data_reg <=
                                plaintext_line_buffer[line_out_cnt + 8'd1];
                        end
                    end
                end
                
                default: state <= R_IDLE;
            endcase
        end
    end
endmodule
