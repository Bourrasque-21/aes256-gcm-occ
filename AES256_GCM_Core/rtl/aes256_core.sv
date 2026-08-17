import aes_pkg::*;

module aes256_core (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [127:0] plaintext,
    input  logic [255:0] key,
    output logic [127:0] ciphertext,
    output logic         busy,
    output logic         done
);
    typedef enum logic [2:0] {
        S_IDLE,
        S_KEY_EXPAND,
        S_KEY_STORE,
        S_INIT,
        S_ROUND,
        S_FINAL,
        S_DONE
    } aes_state_t;

    aes_state_t state;

    // Cached session key and expanded round keys. The key schedule is rebuilt
    // only when the input key changes; all blocks in the same key session
    // reuse round_keys.
    logic [255:0]  key_reg;
    logic          round_keys_valid;
    logic [127:0]  block_reg;
    logic [127:0]  state_reg;
    logic [3:0]    round_ctr;
    logic [3:0]    expand_step;
    logic [1919:0] round_keys;
    logic [127:0]  current_round_key;
    logic [127:0]  round_key_reg;
    logic [127:0]  round_out;
    logic          final_round;
    
    // Key expansion registers
    logic [31:0]   w_minus_8 [0:3];
    logic [31:0]   w_minus_4 [0:3];
    logic [31:0]   exp_out   [0:3];
    logic [31:0]   exp_out_reg [0:3];
    logic [31:0]   exp_tmp;
    logic [31:0]   w_minus_1;
    logic [3:0]    rcon_idx;
    
    aes_round u_round (
        .state_in    (state_reg),
        .round_key   (current_round_key),
        .final_round (final_round),
        .state_out   (round_out)
    );

    function automatic logic [127:0] round_key_at(
        input logic [1919:0] keys,
        input logic [3:0]    round
    );
        unique case (round)
            4'd0:  round_key_at = keys[1919:1792];
            4'd1:  round_key_at = keys[1791:1664];
            4'd2:  round_key_at = keys[1663:1536];
            4'd3:  round_key_at = keys[1535:1408];
            4'd4:  round_key_at = keys[1407:1280];
            4'd5:  round_key_at = keys[1279:1152];
            4'd6:  round_key_at = keys[1151:1024];
            4'd7:  round_key_at = keys[1023:896];
            4'd8:  round_key_at = keys[895:768];
            4'd9:  round_key_at = keys[767:640];
            4'd10: round_key_at = keys[639:512];
            4'd11: round_key_at = keys[511:384];
            4'd12: round_key_at = keys[383:256];
            4'd13: round_key_at = keys[255:128];
            4'd14: round_key_at = keys[127:0];
            default: round_key_at = 128'h0;
        endcase
    endfunction

    function automatic logic [31:0] rot_word(input logic [31:0] word_in);
        rot_word = {word_in[23:0], word_in[31:24]};
    endfunction

    function automatic logic [31:0] sub_word(input logic [31:0] word_in);
        sub_word = {
            aes_sbox_byte(word_in[31:24]),
            aes_sbox_byte(word_in[23:16]),
            aes_sbox_byte(word_in[15:8]),
            aes_sbox_byte(word_in[7:0])
        };
    endfunction

    function automatic logic [7:0] rcon(input logic [3:0] round);
        unique case (round)
            4'd1:  rcon = 8'h01;
            4'd2:  rcon = 8'h02;
            4'd3:  rcon = 8'h04;
            4'd4:  rcon = 8'h08;
            4'd5:  rcon = 8'h10;
            4'd6:  rcon = 8'h20;
            4'd7:  rcon = 8'h40;
            4'd8:  rcon = 8'h80;
            4'd9:  rcon = 8'h1b;
            4'd10: rcon = 8'h36;
            default: rcon = 8'h00;
        endcase
    endfunction

    // Keep busy asserted through S_DONE. A new request is accepted only after
    // the core returns to S_IDLE.
    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);
    assign final_round = (state == S_FINAL);
    // Prefetch the next round key so the AES round datapath does not contain a
    // 15:1, 128-bit variable round-key mux.
    assign current_round_key = round_key_reg;

    assign w_minus_1 = w_minus_4[3];
    assign rcon_idx  = (expand_step[3:1] + 4'd1); // step 1,2->rcon(1); step 3,4->rcon(2); etc.

    always_comb begin
        if (expand_step[0] == 1'b1) begin
            // Odd step (1, 3, 5...): Type A (RotWord + SubWord + Rcon)
            exp_tmp = sub_word(rot_word(w_minus_1)) ^ {rcon(rcon_idx), 24'h000000};
        end else begin
            // Even step (2, 4, 6...): Type B (SubWord only)
            exp_tmp = sub_word(w_minus_1);
        end
        
        exp_out[0] = w_minus_8[0] ^ exp_tmp;
        exp_out[1] = w_minus_8[1] ^ exp_out[0];
        exp_out[2] = w_minus_8[2] ^ exp_out[1];
        exp_out[3] = w_minus_8[3] ^ exp_out[2];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            key_reg     <= 256'h0;
            round_keys_valid <= 1'b0;
            block_reg   <= 128'h0;
            state_reg   <= 128'h0;
            round_ctr   <= 4'h0;
            expand_step <= 4'h0;
            round_keys  <= 1920'h0;
            round_key_reg <= 128'h0;
            ciphertext  <= 128'h0;
            for (int i = 0; i < 4; i++) begin
                w_minus_8[i] <= 32'h0;
                w_minus_4[i] <= 32'h0;
                exp_out_reg[i] <= 32'h0;
            end
        end else begin
            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        block_reg <= plaintext;
                        round_ctr <= 4'h0;

                        if (round_keys_valid && (key == key_reg)) begin
                            // Same session key: skip the pipelined 26-cycle
                            // expansion.
                            state <= S_INIT;
                        end else begin
                            // First use or a new key: rebuild the complete
                            // AES-256 round-key schedule before encryption.
                            key_reg         <= key;
                            round_keys_valid <= 1'b0;
                            expand_step     <= 4'd1;
                            round_keys[1919:1792] <= key[255:128]; // RK0
                            round_keys[1791:1664] <= key[127:0];   // RK1
                            
                            w_minus_8[0] <= key[255:224];
                            w_minus_8[1] <= key[223:192];
                            w_minus_8[2] <= key[191:160];
                            w_minus_8[3] <= key[159:128];
                            
                            w_minus_4[0] <= key[127:96];
                            w_minus_4[1] <= key[95:64];
                            w_minus_4[2] <= key[63:32];
                            w_minus_4[3] <= key[31:0];
                            
                            state <= S_KEY_EXPAND;
                        end
                    end
                end

                S_KEY_EXPAND: begin
                    // Pipeline the SubWord/XOR result before selecting the
                    // destination round-key register bank.
                    exp_out_reg[0] <= exp_out[0];
                    exp_out_reg[1] <= exp_out[1];
                    exp_out_reg[2] <= exp_out[2];
                    exp_out_reg[3] <= exp_out[3];
                    state <= S_KEY_STORE;
                end

                S_KEY_STORE: begin
                    // Fixed destinations avoid a variable part-select decoder
                    // on the round-key register enables.
                    unique case (expand_step)
                        4'd1:  round_keys[1663:1536] <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd2:  round_keys[1535:1408] <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd3:  round_keys[1407:1280] <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd4:  round_keys[1279:1152] <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd5:  round_keys[1151:1024] <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd6:  round_keys[1023:896]  <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd7:  round_keys[895:768]   <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd8:  round_keys[767:640]   <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd9:  round_keys[639:512]   <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd10: round_keys[511:384]   <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd11: round_keys[383:256]   <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd12: round_keys[255:128]   <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        4'd13: round_keys[127:0]     <= {exp_out_reg[0], exp_out_reg[1], exp_out_reg[2], exp_out_reg[3]};
                        default: begin
                        end
                    endcase
                    
                    w_minus_8[0] <= w_minus_4[0];
                    w_minus_8[1] <= w_minus_4[1];
                    w_minus_8[2] <= w_minus_4[2];
                    w_minus_8[3] <= w_minus_4[3];
                    
                    w_minus_4[0] <= exp_out_reg[0];
                    w_minus_4[1] <= exp_out_reg[1];
                    w_minus_4[2] <= exp_out_reg[2];
                    w_minus_4[3] <= exp_out_reg[3];

                    if (expand_step == 4'd13) begin
                        round_keys_valid <= 1'b1;
                        state            <= S_INIT;
                    end else begin
                        expand_step <= expand_step + 4'd1;
                        state       <= S_KEY_EXPAND;
                    end
                end

                S_INIT: begin
                    state_reg <= block_reg ^ round_key_at(round_keys, 4'd0);
                    round_ctr <= 4'd1;
                    round_key_reg <= round_key_at(round_keys, 4'd1);
                    state     <= S_ROUND;
                end

                S_ROUND: begin
                    state_reg <= round_out;
                    if (round_ctr == 4'd13) begin
                        round_ctr <= 4'd14;
                        round_key_reg <= round_key_at(round_keys, 4'd14);
                        state     <= S_FINAL;
                    end else begin
                        round_ctr <= round_ctr + 4'd1;
                        round_key_reg <= round_key_at(
                            round_keys,
                            round_ctr + 4'd1
                        );
                    end
                end

                S_FINAL: begin
                    state_reg  <= round_out;
                    ciphertext <= round_out;
                    state      <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
