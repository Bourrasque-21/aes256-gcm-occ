`timescale 1ns / 1ps

module tb_aes256_gcm;

    localparam integer PAYLOAD_BLOCKS_PER_PACKET = 80;
    localparam integer PACKETS_PER_LINE = 2;
    localparam integer LINE_BLOCKS               =
        PAYLOAD_BLOCKS_PER_PACKET * PACKETS_PER_LINE;
    localparam logic [255:0] FIXED_KEY = {
        128'h000102030405060708090a0b0c0d0e0f,
        128'h101112131415161718191a1b1c1d1e1f
    };

    logic                    clk;
    logic                    rst_n;

    // Deliberately different from FIXED_KEY. These ports are reserved for a
    // future Key Manager and must not affect the current fixed-key build.
    logic            [255:0] external_key_unused;
    logic            [ 31:0] session_id;
    logic            [ 31:0] tx_frame_counter;
    logic            [ 31:0] tx_packet_counter;

    // Tx Inputs
    logic            [127:0] tx_s_tdata;
    logic                    tx_s_tvalid;
    logic                    tx_s_tready;
    logic                    tx_s_tlast;

    // Middle (Tx Output -> Rx Input)
    logic            [127:0] mid_tdata;
    logic                    mid_tvalid;
    logic                    mid_tready;
    logic                    mid_tlast;

    // Rx Outputs
    logic            [127:0] rx_m_tdata;
    logic                    rx_m_tvalid;
    logic                    rx_m_tready;
    logic                    rx_m_tlast;

    // Errors
    logic                    rx_anti_replay_err;
    logic                    rx_packet_loss_err;
    logic                    rx_auth_fail_err;
    logic                    rx_length_err;
    logic                    rx_session_err;
    logic                    rx_timeout_err;

    logic                    tx_busy;
    logic                    rx_busy;

    logic                    rx_line_done;
    logic                    test_failed;
    logic                    protocol_failed;
    integer                  rx_block_count;
    integer                  reference_check_count;
    integer                  tx_key_expand_count;
    integer                  rx_key_expand_count;

    // Runtime controls:
    //   +TRACE_LEVEL=0 : PASS/FAIL summary only
    //   +TRACE_LEVEL=1 : packet/tag and sampled block trace (default)
    //   +TRACE_LEVEL=2 : every AES/GHASH and payload block operation
    //   +TRACE_LEVEL=3 : FSM, AES round, and GHASH 8-bit multiply trace
    //   +NO_VCD        : disable VCD generation
    //   +VCD=<file>    : select VCD filename
    //   +BACKPRESSURE  : periodically stall authenticated line output
    integer                  trace_level;
    string                   vcd_file;
    logic                    vcd_enabled;
    logic                    backpressure_enabled;
    longint unsigned         cycle_count;
    longint unsigned         test_start_cycle;
    longint unsigned         line_done_cycle;

    /*
     * Waveform observation signals
     *
     * Only the TB scope is dumped to VCD. The following aliases bring the
     * useful internal pipeline state into that scope without dumping large
     * memories such as plaintext_line_buffer[] and round_keys[].
     */
    logic            [  4:0] wave_tx_state;
    logic            [  4:0] wave_rx_state;
    logic            [  6:0] wave_tx_payload_cnt;
    logic            [  6:0] wave_rx_payload_cnt;
    logic            [ 31:0] wave_tx_block_ctr;
    logic            [ 31:0] wave_rx_block_ctr;
    logic            [127:0] wave_tx_aad;
    logic            [127:0] wave_rx_aad;
    logic            [127:0] wave_tx_h;
    logic            [127:0] wave_rx_h;
    logic            [127:0] wave_tx_tag_mask;
    logic            [127:0] wave_rx_tag_mask;
    logic            [127:0] wave_tx_ghash_y;
    logic            [127:0] wave_rx_ghash_y;

    logic                    wave_tx_aes_start;
    logic                    wave_tx_aes_done;
    logic                    wave_tx_aes_busy;
    logic                    wave_tx_round_keys_valid;
    logic            [  2:0] wave_tx_aes_state;
    logic            [  3:0] wave_tx_aes_expand_step;
    logic            [  3:0] wave_tx_aes_round;
    logic            [127:0] wave_tx_aes_input;
    logic            [127:0] wave_tx_aes_state_reg;
    logic            [127:0] wave_tx_aes_round_key;
    logic            [127:0] wave_tx_aes_round_out;
    logic            [127:0] wave_tx_aes_output;
    logic            [127:0] wave_tx_expanded_key_block;

    logic                    wave_rx_aes_start;
    logic                    wave_rx_aes_done;
    logic                    wave_rx_aes_busy;
    logic                    wave_rx_round_keys_valid;
    logic            [  2:0] wave_rx_aes_state;
    logic            [  3:0] wave_rx_aes_expand_step;
    logic            [  3:0] wave_rx_aes_round;
    logic            [127:0] wave_rx_aes_input;
    logic            [127:0] wave_rx_aes_state_reg;
    logic            [127:0] wave_rx_aes_round_key;
    logic            [127:0] wave_rx_aes_round_out;
    logic            [127:0] wave_rx_aes_output;
    logic            [127:0] wave_rx_expanded_key_block;

    logic                    wave_tx_ghash_start;
    logic                    wave_tx_ghash_done;
    logic                    wave_tx_ghash_busy;
    logic            [  1:0] wave_tx_ghash_state;
    logic            [127:0] wave_tx_ghash_data;
    logic            [127:0] wave_tx_ghash_y_in;
    logic            [127:0] wave_tx_ghash_y_out;
    logic            [  1:0] wave_tx_mult_state;
    logic            [  3:0] wave_tx_mult_byte;
    logic            [  7:0] wave_tx_mult_x_byte;
    logic            [127:0] wave_tx_mult_z;
    logic            [127:0] wave_tx_mult_v;
    logic            [127:0] wave_tx_mult_z_next;

    logic                    wave_rx_ghash_start;
    logic                    wave_rx_ghash_done;
    logic                    wave_rx_ghash_busy;
    logic            [  1:0] wave_rx_ghash_state;
    logic            [127:0] wave_rx_ghash_data;
    logic            [127:0] wave_rx_ghash_y_in;
    logic            [127:0] wave_rx_ghash_y_out;
    logic            [  1:0] wave_rx_mult_state;
    logic            [  3:0] wave_rx_mult_byte;
    logic            [  7:0] wave_rx_mult_x_byte;
    logic            [127:0] wave_rx_mult_z;
    logic            [127:0] wave_rx_mult_v;
    logic            [127:0] wave_rx_mult_z_next;

    logic                    wave_tx_cipher_commit;
    logic            [127:0] wave_tx_plaintext;
    logic            [127:0] wave_tx_keystream;
    logic            [127:0] wave_tx_ciphertext;
    logic                    wave_rx_plain_commit;
    logic            [  7:0] wave_rx_plain_index;
    logic            [127:0] wave_rx_ciphertext;
    logic            [127:0] wave_rx_keystream;
    logic            [127:0] wave_rx_plaintext;
    logic                    wave_rx_tag_check;
    logic                    wave_rx_tag_match;
    logic            [127:0] wave_rx_expected_tag;
    logic            [127:0] wave_rx_received_tag;

    aes256_gcm_top #(
        .FIXED_KEY(FIXED_KEY)
    ) u_top (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .tx_key                (external_key_unused),
        .rx_key                (external_key_unused),
        .tx_session_id         (session_id),
        .rx_expected_session_id(session_id),

        .tx_frame_counter (tx_frame_counter),
        .tx_packet_counter(tx_packet_counter),
        .tx_flag_eof      (1'b0),
        .tx_flag_sof      (1'b0),
        .tx_flag_frame1   (1'b0),
        .tx_flag_frame0   (1'b0),

        .tx_s_axis_tdata (tx_s_tdata),
        .tx_s_axis_tvalid(tx_s_tvalid),
        .tx_s_axis_tready(tx_s_tready),
        .tx_s_axis_tlast (tx_s_tlast),

        .tx_m_axis_tdata (mid_tdata),
        .tx_m_axis_tvalid(mid_tvalid),
        .tx_m_axis_tready(mid_tready),
        .tx_m_axis_tlast (mid_tlast),
        .tx_busy         (tx_busy),

        .rx_s_axis_tdata (mid_tdata),
        .rx_s_axis_tvalid(mid_tvalid),
        .rx_s_axis_tready(mid_tready),
        .rx_s_axis_tlast (mid_tlast),

        .rx_m_axis_tdata (rx_m_tdata),
        .rx_m_axis_tvalid(rx_m_tvalid),
        .rx_m_axis_tready(rx_m_tready),
        .rx_m_axis_tlast (rx_m_tlast),
        .rx_busy         (rx_busy),

        .rx_anti_replay_err(rx_anti_replay_err),
        .rx_packet_loss_err(rx_packet_loss_err),
        .rx_auth_fail_err  (rx_auth_fail_err),
        .rx_length_err     (rx_length_err),
        .rx_session_err    (rx_session_err),
        .rx_timeout_err    (rx_timeout_err)
    );

    // TX wrapper/core aliases
    assign wave_tx_state = u_top.u_tx_wrapper.state;
    assign wave_tx_payload_cnt = u_top.u_tx_wrapper.payload_cnt;
    assign wave_tx_block_ctr = u_top.u_tx_wrapper.block_ctr;
    assign wave_tx_aad = u_top.u_tx_wrapper.aad_block;
    assign wave_tx_h = u_top.u_tx_wrapper.h_reg;
    assign wave_tx_tag_mask = u_top.u_tx_wrapper.tag_mask_reg;
    assign wave_tx_ghash_y = u_top.u_tx_wrapper.ghash_y_reg;

    assign wave_tx_aes_start = u_top.u_tx_wrapper.aes_start;
    assign wave_tx_aes_done = u_top.u_tx_wrapper.aes_done;
    assign wave_tx_aes_busy = u_top.u_tx_wrapper.aes_busy;
    assign wave_tx_round_keys_valid =
        u_top.u_tx_wrapper.u_aes256_core.round_keys_valid;
    assign wave_tx_aes_state = u_top.u_tx_wrapper.u_aes256_core.state;
    assign wave_tx_aes_expand_step =
        u_top.u_tx_wrapper.u_aes256_core.expand_step;
    assign wave_tx_aes_round = u_top.u_tx_wrapper.u_aes256_core.round_ctr;
    assign wave_tx_aes_input = u_top.u_tx_wrapper.u_aes256_core.block_reg;
    assign wave_tx_aes_state_reg = u_top.u_tx_wrapper.u_aes256_core.state_reg;
    assign wave_tx_aes_round_key   =
        u_top.u_tx_wrapper.u_aes256_core.current_round_key;
    assign wave_tx_aes_round_out = u_top.u_tx_wrapper.u_aes256_core.round_out;
    assign wave_tx_aes_output = u_top.u_tx_wrapper.aes_ciphertext;
    assign wave_tx_expanded_key_block = {
        u_top.u_tx_wrapper.u_aes256_core.exp_out[0],
        u_top.u_tx_wrapper.u_aes256_core.exp_out[1],
        u_top.u_tx_wrapper.u_aes256_core.exp_out[2],
        u_top.u_tx_wrapper.u_aes256_core.exp_out[3]
    };

    assign wave_tx_ghash_start = u_top.u_tx_wrapper.ghash_start;
    assign wave_tx_ghash_done = u_top.u_tx_wrapper.ghash_done;
    assign wave_tx_ghash_busy = u_top.u_tx_wrapper.ghash_busy;
    assign wave_tx_ghash_state = u_top.u_tx_wrapper.u_ghash_engine_seq.state;
    assign wave_tx_ghash_data = u_top.u_tx_wrapper.ghash_data_in;
    assign wave_tx_ghash_y_in = u_top.u_tx_wrapper.ghash_y_in;
    assign wave_tx_ghash_y_out = u_top.u_tx_wrapper.ghash_y_out;
    assign wave_tx_mult_state  =
        u_top.u_tx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.state;
    assign wave_tx_mult_byte   =
        u_top.u_tx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.byte_index;
    assign wave_tx_mult_x_byte =
        u_top.u_tx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.x_byte;
    assign wave_tx_mult_z      =
        u_top.u_tx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.z_reg;
    assign wave_tx_mult_v      =
        u_top.u_tx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.v_reg;
    assign wave_tx_mult_z_next =
        u_top.u_tx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.z_next;

    // RX wrapper/core aliases
    assign wave_rx_state = u_top.u_rx_wrapper.state;
    assign wave_rx_payload_cnt = u_top.u_rx_wrapper.payload_cnt;
    assign wave_rx_block_ctr = u_top.u_rx_wrapper.block_ctr;
    assign wave_rx_aad = u_top.u_rx_wrapper.aad_block;
    assign wave_rx_h = u_top.u_rx_wrapper.h_reg;
    assign wave_rx_tag_mask = u_top.u_rx_wrapper.tag_mask_reg;
    assign wave_rx_ghash_y = u_top.u_rx_wrapper.ghash_y_reg;

    assign wave_rx_aes_start = u_top.u_rx_wrapper.aes_start;
    assign wave_rx_aes_done = u_top.u_rx_wrapper.aes_done;
    assign wave_rx_aes_busy = u_top.u_rx_wrapper.aes_busy;
    assign wave_rx_round_keys_valid =
        u_top.u_rx_wrapper.u_aes256_core.round_keys_valid;
    assign wave_rx_aes_state = u_top.u_rx_wrapper.u_aes256_core.state;
    assign wave_rx_aes_expand_step =
        u_top.u_rx_wrapper.u_aes256_core.expand_step;
    assign wave_rx_aes_round = u_top.u_rx_wrapper.u_aes256_core.round_ctr;
    assign wave_rx_aes_input = u_top.u_rx_wrapper.u_aes256_core.block_reg;
    assign wave_rx_aes_state_reg = u_top.u_rx_wrapper.u_aes256_core.state_reg;
    assign wave_rx_aes_round_key   =
        u_top.u_rx_wrapper.u_aes256_core.current_round_key;
    assign wave_rx_aes_round_out = u_top.u_rx_wrapper.u_aes256_core.round_out;
    assign wave_rx_aes_output = u_top.u_rx_wrapper.aes_ciphertext;
    assign wave_rx_expanded_key_block = {
        u_top.u_rx_wrapper.u_aes256_core.exp_out[0],
        u_top.u_rx_wrapper.u_aes256_core.exp_out[1],
        u_top.u_rx_wrapper.u_aes256_core.exp_out[2],
        u_top.u_rx_wrapper.u_aes256_core.exp_out[3]
    };

    assign wave_rx_ghash_start = u_top.u_rx_wrapper.ghash_start;
    assign wave_rx_ghash_done = u_top.u_rx_wrapper.ghash_done;
    assign wave_rx_ghash_busy = u_top.u_rx_wrapper.ghash_busy;
    assign wave_rx_ghash_state = u_top.u_rx_wrapper.u_ghash_engine_seq.state;
    assign wave_rx_ghash_data = u_top.u_rx_wrapper.ghash_data_in;
    assign wave_rx_ghash_y_in = u_top.u_rx_wrapper.ghash_y_in;
    assign wave_rx_ghash_y_out = u_top.u_rx_wrapper.ghash_y_out;
    assign wave_rx_mult_state  =
        u_top.u_rx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.state;
    assign wave_rx_mult_byte   =
        u_top.u_rx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.byte_index;
    assign wave_rx_mult_x_byte =
        u_top.u_rx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.x_byte;
    assign wave_rx_mult_z      =
        u_top.u_rx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.z_reg;
    assign wave_rx_mult_v      =
        u_top.u_rx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.v_reg;
    assign wave_rx_mult_z_next =
        u_top.u_rx_wrapper.u_ghash_engine_seq.u_gf128_mult_8bit_seq.z_next;

    // Single-cycle commit/check markers make transactions obvious in a wave.
    assign wave_tx_cipher_commit =
        (wave_tx_state == 5'd8) && tx_s_tvalid && tx_s_tready;
    assign wave_tx_plaintext = tx_s_tdata;
    assign wave_tx_keystream = u_top.u_tx_wrapper.keystream_reg;
    assign wave_tx_ciphertext = wave_tx_plaintext ^ wave_tx_keystream;

    assign wave_rx_plain_commit = (wave_rx_state == 5'd6) && wave_rx_aes_done;
    assign wave_rx_plain_index =
        (wave_rx_aad[32] ? 8'd80 : 8'd0) + {1'b0, wave_rx_payload_cnt};
    assign wave_rx_ciphertext = u_top.u_rx_wrapper.ciphertext_reg;
    assign wave_rx_keystream = wave_rx_aes_output;
    assign wave_rx_plaintext = wave_rx_ciphertext ^ wave_rx_keystream;

    assign wave_rx_tag_check =
        (wave_rx_state == 5'd9) &&
        mid_tvalid && mid_tready;
    assign wave_rx_expected_tag = wave_rx_tag_mask ^ wave_rx_ghash_y_out;
    assign wave_rx_received_tag = mid_tdata;
    assign wave_rx_tag_match =
        wave_rx_tag_check &&
        (wave_rx_received_tag == wave_rx_expected_tag);

    function automatic logic sampled_block(input integer block_index);
        begin
            sampled_block =
                (block_index == 0)  ||
                (block_index == 15) ||
                (block_index == 31) ||
                (block_index == 47) ||
                (block_index == 63) ||
                (block_index == 79);
        end
    endfunction

    /*
     * Independent AES-256-GCM reference samples for the fixed test stimulus.
     * These values were generated outside the RTL from:
     *   key = 000102...1f
     *   IV  = Session ID || Frame counter || Packet counter
     *   AAD = IV || 00000000
     *
     * Checking representative ciphertext blocks plus the complete TAG catches
     * errors that a TX-to-RX loopback alone can hide.
     */
    function automatic logic [127:0] expected_cipher_sample(
        input logic [31:0] packet_number, input integer block_index);
        begin
            expected_cipher_sample = 128'hx;
            case (packet_number)
                32'd0: begin
                    case (block_index)
                        0:
                        expected_cipher_sample = 128'h878ffd5b4c5610c5e9746ee1478bd3dd;
                        15:
                        expected_cipher_sample = 128'h3acfd1202726ba65a3552b1ea47606e2;
                        31:
                        expected_cipher_sample = 128'hea51c3b224f788bef454b8ebfff71577;
                        47:
                        expected_cipher_sample = 128'h61a4521fa172673bc5a33a42e38dc78f;
                        63:
                        expected_cipher_sample = 128'h2abafe0ed10a1b6b54ff70043f124db2;
                        79:
                        expected_cipher_sample = 128'h14ebf82dcb3a387ca5a82b3763029cbb;
                        default: expected_cipher_sample = 128'hx;
                    endcase
                end
                32'd1: begin
                    case (block_index)
                        0:
                        expected_cipher_sample = 128'h62ffda79c9674a6cad970ebac59bc722;
                        15:
                        expected_cipher_sample = 128'hc083c6f78eafa4e59617b78a2789b5af;
                        31:
                        expected_cipher_sample = 128'h59d526f18373b9d3c367faf133c40d80;
                        47:
                        expected_cipher_sample = 128'h5bdf737f9c0000b6708734d33bd76d13;
                        63:
                        expected_cipher_sample = 128'h2d1ed7ea153d2858fd5e82a44d91f836;
                        79:
                        expected_cipher_sample = 128'ha62a252c988672f3e6be9e2ff9443eb2;
                        default: expected_cipher_sample = 128'hx;
                    endcase
                end
                default: expected_cipher_sample = 128'hx;
            endcase
        end
    endfunction

    function automatic logic [127:0] expected_packet_tag(
        input logic [31:0] packet_number);
        begin
            case (packet_number)
                32'd0:
                expected_packet_tag = 128'h43b4f737248427cf7f96d197858d10b4;
                32'd1:
                expected_packet_tag = 128'hf05377b88664255bb41d78d63f86ad4e;
                default: expected_packet_tag = 128'hx;
            endcase
        end
    endfunction

    function automatic string tx_state_name(input logic [4:0] state_value);
        begin
            case (state_value)
                5'd0: tx_state_name = "IDLE";
                5'd1: tx_state_name = "H_START";
                5'd2: tx_state_name = "H_WAIT";
                5'd3: tx_state_name = "OUT_AAD";
                5'd4: tx_state_name = "INIT_START";
                5'd5: tx_state_name = "INIT_WAIT";
                5'd6: tx_state_name = "PAYLOAD_PRECOMPUTE_START";
                5'd7: tx_state_name = "PAYLOAD_PRECOMPUTE_WAIT";
                5'd8: tx_state_name = "PAYLOAD_WAIT_DATA";
                5'd9: tx_state_name = "PAYLOAD_OUT";
                5'd10: tx_state_name = "PAYLOAD_PARALLEL_START";
                5'd11: tx_state_name = "PAYLOAD_PARALLEL_WAIT";
                5'd12: tx_state_name = "GHASH_LEN_START";
                5'd13: tx_state_name = "GHASH_LEN_WAIT";
                5'd14: tx_state_name = "OUT_TAG";
                default: tx_state_name = "UNKNOWN";
            endcase
        end
    endfunction

    function automatic string rx_state_name(input logic [4:0] state_value);
        begin
            case (state_value)
                5'd0: rx_state_name = "IDLE";
                5'd1: rx_state_name = "H_START";
                5'd2: rx_state_name = "H_WAIT";
                5'd3: rx_state_name = "INIT_START";
                5'd4: rx_state_name = "INIT_WAIT";
                5'd5: rx_state_name = "PAYLOAD_WAIT_DATA";
                5'd6: rx_state_name = "PAYLOAD_WAIT_PARALLEL";
                5'd7: rx_state_name = "GHASH_LEN_START";
                5'd8: rx_state_name = "GHASH_LEN_WAIT";
                5'd9: rx_state_name = "TAG_VERIFY";
                5'd10: rx_state_name = "LINE_OUT_PREP";
                5'd11: rx_state_name = "LINE_OUT";
                default: rx_state_name = "UNKNOWN";
            endcase
        end
    endfunction

    initial begin : trace_configuration
        trace_level          = 3;
        vcd_file             = "tb_aes256_gcm.vcd";
        vcd_enabled          = 1'b1;
        backpressure_enabled = 1'b0;

        if ($value$plusargs("TRACE_LEVEL=%d", trace_level)) begin
            // Value loaded by the simulator.
        end
        if ($value$plusargs("VCD=%s", vcd_file)) begin
            // Value loaded by the simulator.
        end
        if ($test$plusargs("NO_VCD")) begin
            vcd_enabled = 1'b0;
        end
        if ($test$plusargs("BACKPRESSURE")) begin
            backpressure_enabled = 1'b1;
        end

        $display(
            "[TB][CONFIG] TRACE_LEVEL=%0d VCD=%0d FILE=%s BACKPRESSURE=%0d",
            trace_level, vcd_enabled, vcd_file, backpressure_enabled);

        if (vcd_enabled) begin
            $dumpfile(vcd_file);
            $dumpvars(1, tb_aes256_gcm);
        end
    end

    always #5 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
        end
    end

    // Optional output backpressure validates that authenticated plaintext and
    // TLAST remain stable while m_axis_tready is low.
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_m_tready <= 1'b1;
        end else if (backpressure_enabled) begin
            rx_m_tready <= (cycle_count[3:0] < 4'd12);
        end else begin
            rx_m_tready <= 1'b1;
        end
    end

    task automatic send_packet(input logic [31:0] packet_number,
                               input integer first_block_index);
        integer j;
        longint unsigned packet_start_cycle;
        begin
            tx_packet_counter  = packet_number;
            packet_start_cycle = cycle_count;

            if (trace_level >= 1) begin
                $display(
                    "[TB][TX-IN][C%0d] packet=%0d frame=%0d blocks=%0d..%0d START",
                    cycle_count, packet_number, tx_frame_counter,
                    first_block_index,
                    first_block_index + PAYLOAD_BLOCKS_PER_PACKET - 1);
            end

            for (j = 0; j < PAYLOAD_BLOCKS_PER_PACKET; j = j + 1) begin
                @(negedge clk);
                tx_s_tvalid = 1'b1;
                tx_s_tdata  = {96'h0, first_block_index + j};
                tx_s_tlast  = (j == PAYLOAD_BLOCKS_PER_PACKET - 1);

                do begin
                    @(posedge clk);
                end while (!tx_s_tready);
            end

            @(negedge clk);
            tx_s_tvalid = 1'b0;
            tx_s_tlast  = 1'b0;

            wait (tx_busy == 1'b0);
            if (trace_level >= 1) begin
                $display("[TB][TX-IN][C%0d] packet=%0d END latency=%0d cycles",
                         cycle_count, packet_number,
                         cycle_count - packet_start_cycle);
            end
        end
    endtask

    /*
     * Packet-level monitor for the encrypted stream:
     *   beat 0     = AAD
     *   beat 1..80 = ciphertext
     *   beat 81    = authentication TAG + TLAST
     */
    integer                  wire_beat_count;
    logic            [ 31:0] wire_packet_number;
    longint unsigned         wire_packet_start_cycle;
    logic                    mid_stalled;
    logic            [127:0] mid_stall_data;
    logic                    mid_stall_last;
    logic                    rx_out_stalled;
    logic            [127:0] rx_out_stall_data;
    logic                    rx_out_stall_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wire_beat_count         <= 0;
            wire_packet_number      <= 0;
            wire_packet_start_cycle <= 0;
            protocol_failed         <= 1'b0;
            reference_check_count   <= 0;
            mid_stalled             <= 1'b0;
            mid_stall_data          <= 128'h0;
            mid_stall_last          <= 1'b0;
            rx_out_stalled          <= 1'b0;
            rx_out_stall_data       <= 128'h0;
            rx_out_stall_last       <= 1'b0;
        end else begin
            // AXI-stream source stability checks under backpressure.
            if (mid_tvalid && !mid_tready) begin
                if (mid_stalled &&
                    ((mid_tdata !== mid_stall_data) ||
                     (mid_tlast !== mid_stall_last))) begin
                    protocol_failed <= 1'b1;
                    $error(
                        "[TB][AXIS][C%0d] TX changed data/TLAST while stalled",
                        cycle_count);
                end
                mid_stalled    <= 1'b1;
                mid_stall_data <= mid_tdata;
                mid_stall_last <= mid_tlast;
            end else begin
                mid_stalled <= 1'b0;
            end

            if (rx_m_tvalid && !rx_m_tready) begin
                if (rx_out_stalled &&
                    ((rx_m_tdata !== rx_out_stall_data) ||
                     (rx_m_tlast !== rx_out_stall_last))) begin
                    protocol_failed <= 1'b1;
                    $error(
                        "[TB][AXIS][C%0d] RX changed data/TLAST while stalled",
                        cycle_count);
                end
                rx_out_stalled    <= 1'b1;
                rx_out_stall_data <= rx_m_tdata;
                rx_out_stall_last <= rx_m_tlast;
            end else begin
                rx_out_stalled <= 1'b0;
            end

            if (mid_tvalid && mid_tready) begin
                if (wire_beat_count == 0) begin
                    wire_packet_number      <= mid_tdata[63:32];
                    wire_packet_start_cycle <= cycle_count;
                    if (trace_level >= 1) begin
                        $display(
                            "[WIRE][AAD][C%0d] session=%08h frame=%0d packet=%0d reserve=%08h raw=%032h",
                            cycle_count, mid_tdata[127:96], mid_tdata[95:64],
                            mid_tdata[63:32], mid_tdata[31:0], mid_tdata);
                    end
                end else if ((wire_beat_count >= 1) &&
                             (wire_beat_count <= PAYLOAD_BLOCKS_PER_PACKET)) begin
                    if (sampled_block(wire_beat_count - 1)) begin
                        reference_check_count <= reference_check_count + 1;
                        if (mid_tdata !== expected_cipher_sample(
                                wire_packet_number, wire_beat_count - 1
                            )) begin
                            protocol_failed <= 1'b1;
                            $error(
                                "[TB][REFERENCE][C%0d] cipher mismatch packet=%0d block=%0d expected=%032h actual=%032h",
                                cycle_count, wire_packet_number,
                                wire_beat_count - 1, expected_cipher_sample(
                                wire_packet_number, wire_beat_count - 1),
                                mid_tdata);
                        end
                    end
                    if ((trace_level >= 2) ||
                        ((trace_level >= 1) &&
                         sampled_block(
                            wire_beat_count - 1
                        ))) begin
                        $display(
                            "[WIRE][CIPHER][C%0d] packet=%0d block=%0d data=%032h",
                            cycle_count, wire_packet_number,
                            wire_beat_count - 1, mid_tdata);
                    end
                end else if (wire_beat_count ==
                             PAYLOAD_BLOCKS_PER_PACKET + 1) begin
                    reference_check_count <= reference_check_count + 1;
                    if (mid_tdata !== expected_packet_tag(
                            wire_packet_number
                        )) begin
                        protocol_failed <= 1'b1;
                        $error(
                            "[TB][REFERENCE][C%0d] TAG mismatch packet=%0d expected=%032h actual=%032h",
                            cycle_count, wire_packet_number,
                            expected_packet_tag(wire_packet_number), mid_tdata);
                    end
                    if (trace_level >= 1) begin
                        $display(
                            "[WIRE][TAG][C%0d] packet=%0d tag=%032h tlast=%0b reference=PASS",
                            cycle_count, wire_packet_number, mid_tdata,
                            mid_tlast);
                    end
                end

                if (mid_tlast !==
                    (wire_beat_count == PAYLOAD_BLOCKS_PER_PACKET + 1)) begin
                    protocol_failed <= 1'b1;
                    $error("[TB][WIRE][C%0d] TLAST at illegal beat=%0d",
                           cycle_count, wire_beat_count);
                end

                if (mid_tlast) begin
                    if (trace_level >= 1) begin
                        $display(
                            "[WIRE][PACKET][C%0d] packet=%0d complete beats=%0d latency=%0d cycles",
                            cycle_count, wire_packet_number,
                            wire_beat_count + 1,
                            cycle_count - wire_packet_start_cycle);
                    end
                    wire_beat_count <= 0;
                end else begin
                    wire_beat_count <= wire_beat_count + 1;
                end
            end
        end
    end

    // High-level cryptographic operation trace.
    always @(posedge clk) begin
        if (rst_n) begin
            if (wave_tx_cipher_commit &&
                ((trace_level >= 2) ||
                 ((trace_level >= 1) &&
                  sampled_block(
                    wave_tx_payload_cnt
                )))) begin
                $display(
                    "[TX][CTR][C%0d] block=%0d counter=%08h plain=%032h stream=%032h cipher=%032h",
                    cycle_count, wave_tx_payload_cnt, wave_tx_block_ctr,
                    wave_tx_plaintext, wave_tx_keystream, wave_tx_ciphertext);
            end

            if (wave_rx_plain_commit &&
                ((trace_level >= 2) ||
                 ((trace_level >= 1) &&
                  sampled_block(
                    wave_rx_payload_cnt
                )))) begin
                $display(
                    "[RX][CTR][C%0d] line_index=%0d counter=%08h cipher=%032h stream=%032h plain=%032h",
                    cycle_count, wave_rx_plain_index, wave_rx_block_ctr,
                    wave_rx_ciphertext, wave_rx_keystream, wave_rx_plaintext);
            end

            if (wave_rx_tag_check && (trace_level >= 1)) begin
                if (wave_rx_tag_match) begin
                    $display(
                        "[RX][TAG][C%0d] PASS received=%032h expected=%032h",
                        cycle_count, wave_rx_received_tag,
                        wave_rx_expected_tag);
                end else begin
                    $display(
                        "[RX][TAG][C%0d] FAIL received=%032h expected=%032h",
                        cycle_count, wave_rx_received_tag,
                        wave_rx_expected_tag);
                end
            end

            if (trace_level >= 2) begin
                if (wave_tx_aes_start) begin
                    $display("[TX][AES][C%0d] START wrapper=%s input=%032h",
                             cycle_count, tx_state_name(wave_tx_state),
                             u_top.u_tx_wrapper.aes_plaintext);
                end
                if (wave_tx_aes_done) begin
                    $display("[TX][AES][C%0d] DONE  wrapper=%s output=%032h",
                             cycle_count, tx_state_name(wave_tx_state),
                             wave_tx_aes_output);
                end
                if (wave_rx_aes_start) begin
                    $display("[RX][AES][C%0d] START wrapper=%s input=%032h",
                             cycle_count, rx_state_name(wave_rx_state),
                             u_top.u_rx_wrapper.aes_plaintext);
                end
                if (wave_rx_aes_done) begin
                    $display("[RX][AES][C%0d] DONE  wrapper=%s output=%032h",
                             cycle_count, rx_state_name(wave_rx_state),
                             wave_rx_aes_output);
                end

                if (wave_tx_ghash_start) begin
                    $display(
                        "[TX][GHASH][C%0d] START data=%032h y_in=%032h H=%032h",
                        cycle_count, wave_tx_ghash_data, wave_tx_ghash_y_in,
                        wave_tx_h);
                end
                if (wave_tx_ghash_done) begin
                    $display("[TX][GHASH][C%0d] DONE  y_out=%032h",
                             cycle_count, wave_tx_ghash_y_out);
                end
                if (wave_rx_ghash_start) begin
                    $display(
                        "[RX][GHASH][C%0d] START data=%032h y_in=%032h H=%032h",
                        cycle_count, wave_rx_ghash_data, wave_rx_ghash_y_in,
                        wave_rx_h);
                end
                if (wave_rx_ghash_done) begin
                    $display("[RX][GHASH][C%0d] DONE  y_out=%032h",
                             cycle_count, wave_rx_ghash_y_out);
                end
            end
        end
    end

    // Deep trace: wrapper state transitions, AES-256 key expansion/rounds,
    // and each 8-bit step of the sequential GF(2^128) multiplier.
    logic [4:0] previous_tx_state;
    logic [4:0] previous_rx_state;
    logic [2:0] previous_tx_aes_state;
    logic [2:0] previous_rx_aes_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            previous_tx_state     <= 5'd0;
            previous_rx_state     <= 5'd0;
            previous_tx_aes_state <= 3'd0;
            previous_rx_aes_state <= 3'd0;
            tx_key_expand_count   <= 0;
            rx_key_expand_count   <= 0;
        end else begin
            if ((wave_tx_aes_state == 3'd1) &&
                (previous_tx_aes_state != 3'd1)) begin
                tx_key_expand_count <= tx_key_expand_count + 1;
                if (trace_level >= 1) begin
                    $display("[TX][AES-KEY][C%0d] cache miss: expanding FIXED_KEY",
                             cycle_count);
                end
            end
            if ((wave_rx_aes_state == 3'd1) &&
                (previous_rx_aes_state != 3'd1)) begin
                rx_key_expand_count <= rx_key_expand_count + 1;
                if (trace_level >= 1) begin
                    $display("[RX][AES-KEY][C%0d] cache miss: expanding FIXED_KEY",
                             cycle_count);
                end
            end

            if (trace_level >= 3) begin
                if (wave_tx_state != previous_tx_state) begin
                    $display("[TX][FSM][C%0d] %s -> %s", cycle_count,
                             tx_state_name(previous_tx_state), tx_state_name(
                             wave_tx_state));
                end
                if (wave_rx_state != previous_rx_state) begin
                    $display("[RX][FSM][C%0d] %s -> %s", cycle_count,
                             rx_state_name(previous_rx_state), rx_state_name(
                             wave_rx_state));
                end

                if (wave_tx_aes_state == 3'd1) begin
                    $display("[TX][AES-KEY][C%0d] step=%0d generated=%032h",
                             cycle_count, wave_tx_aes_expand_step,
                             wave_tx_expanded_key_block);
                end
                if (wave_rx_aes_state == 3'd1) begin
                    $display("[RX][AES-KEY][C%0d] step=%0d generated=%032h",
                             cycle_count, wave_rx_aes_expand_step,
                             wave_rx_expanded_key_block);
                end

                if (wave_tx_aes_state == 3'd3) begin
                    $display(
                        "[TX][AES-ROUND][C%0d] round=%0d in=%032h rk=%032h out=%032h",
                        cycle_count, wave_tx_aes_round, wave_tx_aes_state_reg,
                        wave_tx_aes_round_key, wave_tx_aes_round_out);
                end else if (wave_tx_aes_state == 3'd4) begin
                    $display(
                        "[TX][AES-ROUND][C%0d] round=14(final) in=%032h rk=%032h out=%032h",
                        cycle_count, wave_tx_aes_state_reg,
                        wave_tx_aes_round_key, wave_tx_aes_round_out);
                end

                if (wave_rx_aes_state == 3'd3) begin
                    $display(
                        "[RX][AES-ROUND][C%0d] round=%0d in=%032h rk=%032h out=%032h",
                        cycle_count, wave_rx_aes_round, wave_rx_aes_state_reg,
                        wave_rx_aes_round_key, wave_rx_aes_round_out);
                end else if (wave_rx_aes_state == 3'd4) begin
                    $display(
                        "[RX][AES-ROUND][C%0d] round=14(final) in=%032h rk=%032h out=%032h",
                        cycle_count, wave_rx_aes_state_reg,
                        wave_rx_aes_round_key, wave_rx_aes_round_out);
                end

                if (wave_tx_mult_state == 2'd1) begin
                    $display(
                        "[TX][GHASH-MULT][C%0d] byte=%0d x_byte=%02h z=%032h v=%032h z_next=%032h",
                        cycle_count, wave_tx_mult_byte, wave_tx_mult_x_byte,
                        wave_tx_mult_z, wave_tx_mult_v, wave_tx_mult_z_next);
                end
                if (wave_rx_mult_state == 2'd1) begin
                    $display(
                        "[RX][GHASH-MULT][C%0d] byte=%0d x_byte=%02h z=%032h v=%032h z_next=%032h",
                        cycle_count, wave_rx_mult_byte, wave_rx_mult_x_byte,
                        wave_rx_mult_z, wave_rx_mult_v, wave_rx_mult_z_next);
                end
            end

            previous_tx_state <= wave_tx_state;
            previous_rx_state <= wave_rx_state;
            previous_tx_aes_state <= wave_tx_aes_state;
            previous_rx_aes_state <= wave_rx_aes_state;
        end
    end

    // End-to-end data, TLAST, and error checks.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_block_count <= 0;
            rx_line_done   <= 1'b0;
            test_failed    <= 1'b0;
            line_done_cycle <= 0;
        end else begin
            if (rx_anti_replay_err || rx_packet_loss_err ||
                rx_auth_fail_err || rx_length_err ||
                rx_session_err || rx_timeout_err) begin
                test_failed <= 1'b1;
                $error(
                    "[TB][RX-ERROR][C%0d] replay=%0b loss=%0b auth=%0b length=%0b session=%0b timeout=%0b",
                    cycle_count, rx_anti_replay_err, rx_packet_loss_err,
                    rx_auth_fail_err, rx_length_err, rx_session_err,
                    rx_timeout_err);
            end

            if (rx_m_tvalid && rx_m_tready) begin
                if (rx_m_tdata !== {96'h0, rx_block_count[31:0]}) begin
                    test_failed <= 1'b1;
                    $error(
                        "[TB][RX-OUT][C%0d] data mismatch block=%0d expected=%032h actual=%032h",
                        cycle_count, rx_block_count, {
                        96'h0, rx_block_count[31:0]}, rx_m_tdata);
                end

                if (rx_m_tlast !== (rx_block_count == LINE_BLOCKS - 1)) begin
                    test_failed <= 1'b1;
                    $error(
                        "[TB][RX-OUT][C%0d] TLAST mismatch block=%0d tlast=%0b",
                        cycle_count, rx_block_count, rx_m_tlast);
                end

                if ((trace_level >= 2) || ((trace_level >= 1) && (sampled_block(
                        rx_block_count % PAYLOAD_BLOCKS_PER_PACKET
                    )))) begin
                    $display(
                        "[TB][RX-OUT][C%0d] line_block=%0d data=%032h tlast=%0b",
                        cycle_count, rx_block_count, rx_m_tdata, rx_m_tlast);
                end

                if (rx_block_count == LINE_BLOCKS - 1) begin
                    rx_line_done    <= 1'b1;
                    line_done_cycle <= cycle_count;
                end else begin
                    rx_block_count <= rx_block_count + 1;
                end
            end
        end
    end

    initial begin : stimulus
        clk = 1'b0;
        rst_n = 1'b0;
        external_key_unused = {
            128'ha5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5,
            128'h5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a
        };
        session_id = 32'hDEADBEEF;
        tx_frame_counter = 32'd1;
        tx_packet_counter = 32'd0;

        tx_s_tdata = 128'h0;
        tx_s_tvalid = 1'b0;
        tx_s_tlast = 1'b0;

        #20 rst_n = 1'b1;
        #20;
        test_start_cycle = cycle_count;

        if (trace_level >= 1) begin
            $display("[TB][START][C%0d] AES-256-GCM fixed line test",
                     cycle_count);
            $display(
                "[TB][FORMAT] [AAD 16B][PAYLOAD 1280B][TAG 16B] x 2 packets");
            $display("[TB][KEY] fixed=%064h", FIXED_KEY);
            $display("[TB][KEY] reserved_external=%064h (must be ignored)",
                     external_key_unused);
        end

        // One 720p line consists of two fixed 1280-byte packets.
        send_packet(32'd0, 0);
        send_packet(32'd1, PAYLOAD_BLOCKS_PER_PACKET);

        fork
            begin
                wait (rx_line_done == 1'b1);
            end
            begin
                repeat (30000) @(posedge clk);
                $fatal(1,
                       "[TB][TIMEOUT] waiting for authenticated line output");
            end
        join_any
        disable fork;

        #20;
        if ((tx_key_expand_count != 1) ||
            (rx_key_expand_count != 1) ||
            !wave_tx_round_keys_valid ||
            !wave_rx_round_keys_valid) begin
            $fatal(1,
                   "[TB][KEY-CACHE] expected one expansion per core: tx=%0d rx=%0d tx_valid=%0b rx_valid=%0b",
                   tx_key_expand_count, rx_key_expand_count,
                   wave_tx_round_keys_valid, wave_rx_round_keys_valid);
        end

        if (test_failed || protocol_failed) begin
            $fatal(1, "[TB][FAIL] AES-256-GCM line test failed");
        end

        $display("[TB][PASS] AES-256-GCM line test passed");
        $display("[TB][KEY-CACHE] tx_expansions=%0d rx_expansions=%0d",
                 tx_key_expand_count, rx_key_expand_count);
        $display(
            "[TB][SUMMARY] line_blocks=%0d reference_checks=%0d elapsed=%0d cycles line_done_cycle=%0d",
            LINE_BLOCKS, reference_check_count,
            line_done_cycle - test_start_cycle, line_done_cycle);
        if (vcd_enabled) begin
            $display("[TB][WAVE] VCD written to %s", vcd_file);
        end
        $finish;
    end

endmodule
