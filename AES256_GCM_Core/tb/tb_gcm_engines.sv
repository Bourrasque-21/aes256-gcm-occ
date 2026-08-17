`timescale 1ns/1ps

module tb_gcm_engines;
    localparam int PAYLOAD_BLOCKS = 4;
    localparam logic [255:0] KEY = {
        128'h000102030405060708090a0b0c0d0e0f,
        128'h101112131415161718191a1b1c1d1e1f
    };
    localparam logic [127:0] AAD =
        128'h11223344000000010000000000000005;
    localparam logic [95:0] IV = AAD[127:32];
    localparam logic [127:0] EXPECTED_TAG =
        128'ha80cdd5dfa969ef52d447be2723916ba;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #4 clk = ~clk;

    logic tx_cmd_valid;
    logic tx_cmd_ready;
    logic [127:0] tx_plaintext_data;
    logic tx_plaintext_valid;
    logic tx_plaintext_ready;
    logic [127:0] tx_ciphertext_data;
    logic tx_ciphertext_valid;
    logic tx_tag_valid;
    logic [127:0] tx_tag_data;
    logic tx_busy;

    logic rx_cmd_valid;
    logic rx_cmd_ready;
    logic [127:0] rx_ciphertext_data;
    logic rx_ciphertext_valid;
    logic rx_ciphertext_ready;
    logic [127:0] rx_plaintext_data;
    logic rx_plaintext_valid;
    logic rx_plaintext_last;
    logic [127:0] rx_received_tag;
    logic rx_received_tag_valid;
    logic rx_received_tag_ready;
    logic rx_auth_valid;
    logic rx_auth_ok;
    logic rx_auth_ready;
    logic rx_busy;

    logic buffer_start_valid;
    logic buffer_start_ready;
    logic buffer_plaintext_ready;
    logic [127:0] safe_packet_data;
    logic safe_packet_valid;
    logic safe_packet_last;
    logic safe_packet_complete;
    logic buffer_busy;

    logic [127:0] ciphertext [0:PAYLOAD_BLOCKS-1];
    logic [127:0] captured_tag;
    integer tx_cipher_count;
    integer rx_plain_count;
    integer safe_plain_count;
    integer auth_pass_count;
    integer auth_fail_count;
    logic test_failed;
    logic expected_auth_ok;

    function automatic logic [127:0] make_plain(input integer index);
        make_plain = {
            32'h00112200 + index,
            32'h33445500 + index,
            32'h66778800 + index,
            32'h99aabb00 + index
        };
    endfunction

    function automatic logic [127:0] expected_cipher(input integer index);
        case (index)
            0: expected_cipher = 128'hdb994747215d7d93784b15fdb3976e9c;
            1: expected_cipher = 128'h7f2842e7e14eac640d7b883b0756ce26;
            2: expected_cipher = 128'h2bd4f7f72c95aab952466f8a59e91447;
            3: expected_cipher = 128'h3b3dd755e9ea4058ac5f242fd45a7446;
            default: expected_cipher = 128'hx;
        endcase
    endfunction

    gcm_tx_engine u_tx (
        .clk                (clk),
        .rst_n              (rst_n),
        .cmd_valid          (tx_cmd_valid),
        .cmd_ready          (tx_cmd_ready),
        .cmd_key            (KEY),
        .cmd_iv             (IV),
        .cmd_aad            (AAD),
        .cmd_payload_blocks (PAYLOAD_BLOCKS),
        .plaintext_data     (tx_plaintext_data),
        .plaintext_valid    (tx_plaintext_valid),
        .plaintext_ready    (tx_plaintext_ready),
        .ciphertext_data    (tx_ciphertext_data),
        .ciphertext_valid   (tx_ciphertext_valid),
        .ciphertext_ready   (1'b1),
        .tag_data           (tx_tag_data),
        .tag_valid          (tx_tag_valid),
        .tag_ready          (1'b1),
        .abort              (1'b0),
        .busy               (tx_busy)
    );

    gcm_rx_engine u_rx (
        .clk                (clk),
        .rst_n              (rst_n),
        .cmd_valid          (rx_cmd_valid),
        .cmd_ready          (rx_cmd_ready),
        .cmd_key            (KEY),
        .cmd_iv             (IV),
        .cmd_aad            (AAD),
        .cmd_payload_blocks (PAYLOAD_BLOCKS),
        .ciphertext_data    (rx_ciphertext_data),
        .ciphertext_valid   (rx_ciphertext_valid),
        .ciphertext_ready   (rx_ciphertext_ready),
        .plaintext_data     (rx_plaintext_data),
        .plaintext_valid    (rx_plaintext_valid),
        .plaintext_last     (rx_plaintext_last),
        .plaintext_ready    (buffer_plaintext_ready),
        .received_tag       (rx_received_tag),
        .received_tag_valid (rx_received_tag_valid),
        .received_tag_ready (rx_received_tag_ready),
        .auth_valid         (rx_auth_valid),
        .auth_ok            (rx_auth_ok),
        .auth_ready         (rx_auth_ready),
        .abort              (1'b0),
        .busy               (rx_busy)
    );

    authenticated_packet_buffer #(
        .PAYLOAD_BLOCKS (PAYLOAD_BLOCKS)
    ) u_authenticated_packet_buffer (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .packet_start_valid    (buffer_start_valid),
        .packet_start_ready    (buffer_start_ready),
        .packet_session_id     (32'h11223344),
        .packet_frame          (32'd1),
        .packet_counter        (32'd0),
        .packet_flags          (4'h5),
        .plaintext_data        (rx_plaintext_data),
        .plaintext_valid       (rx_plaintext_valid),
        .plaintext_ready       (buffer_plaintext_ready),
        .auth_valid            (rx_auth_valid),
        .auth_ok               (rx_auth_ok),
        .auth_ready            (rx_auth_ready),
        .packet_data           (safe_packet_data),
        .packet_valid          (safe_packet_valid),
        .packet_ready          (1'b1),
        .packet_last           (safe_packet_last),
        .output_session_id     (),
        .output_frame          (),
        .output_packet_counter (),
        .output_flags          (),
        .abort                 (1'b0),
        .packet_complete       (safe_packet_complete),
        .busy                  (buffer_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_cipher_count <= 0;
            rx_plain_count  <= 0;
            safe_plain_count <= 0;
            auth_pass_count <= 0;
            auth_fail_count <= 0;
            captured_tag    <= 128'h0;
            test_failed     <= 1'b0;
        end else begin
            if (tx_ciphertext_valid) begin
                if (tx_cipher_count >= PAYLOAD_BLOCKS) begin
                    $error("[TB] too many TX ciphertext blocks");
                    test_failed <= 1'b1;
                end else begin
                    ciphertext[tx_cipher_count] <= tx_ciphertext_data;
                    if (tx_ciphertext_data !==
                        expected_cipher(tx_cipher_count)) begin
                        $error("[TB] ciphertext[%0d] mismatch: %032h",
                               tx_cipher_count, tx_ciphertext_data);
                        test_failed <= 1'b1;
                    end
                    tx_cipher_count <= tx_cipher_count + 1;
                end
            end

            if (tx_tag_valid) begin
                captured_tag <= tx_tag_data;
                if (tx_tag_data !== EXPECTED_TAG) begin
                    $error("[TB] TAG mismatch: %032h", tx_tag_data);
                    test_failed <= 1'b1;
                end
            end

            if (rx_plaintext_valid) begin
                if (rx_plaintext_data !==
                    make_plain(rx_plain_count % PAYLOAD_BLOCKS)) begin
                    $error("[TB] plaintext[%0d] mismatch: %032h",
                           rx_plain_count, rx_plaintext_data);
                    test_failed <= 1'b1;
                end
                if (rx_plaintext_last !==
                    ((rx_plain_count % PAYLOAD_BLOCKS) ==
                     (PAYLOAD_BLOCKS - 1))) begin
                    $error("[TB] plaintext_last mismatch at block %0d",
                           rx_plain_count);
                    test_failed <= 1'b1;
                end
                rx_plain_count <= rx_plain_count + 1;
            end

            if (rx_auth_valid) begin
                if (rx_auth_ok !== expected_auth_ok) begin
                    $error("[TB] auth result mismatch: got=%0b expected=%0b",
                           rx_auth_ok, expected_auth_ok);
                    test_failed <= 1'b1;
                end
                if (rx_auth_ok)
                    auth_pass_count <= auth_pass_count + 1;
                else
                    auth_fail_count <= auth_fail_count + 1;
            end

            if (safe_packet_valid) begin
                if (safe_packet_data !==
                    make_plain(safe_plain_count % PAYLOAD_BLOCKS)) begin
                    $error("[TB] authenticated plaintext[%0d] mismatch: %032h",
                           safe_plain_count, safe_packet_data);
                    test_failed <= 1'b1;
                end
                if (safe_packet_last !==
                    ((safe_plain_count % PAYLOAD_BLOCKS) ==
                     (PAYLOAD_BLOCKS - 1))) begin
                    $error("[TB] safe packet_last mismatch at block %0d",
                           safe_plain_count);
                    test_failed <= 1'b1;
                end
                safe_plain_count <= safe_plain_count + 1;
            end
        end
    end

    task automatic start_tx;
        begin
            while (!tx_cmd_ready) @(posedge clk);
            @(negedge clk);
            tx_cmd_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tx_cmd_valid = 1'b0;
        end
    endtask

    task automatic send_tx_plaintext(input logic [127:0] value);
        begin
            @(negedge clk);
            tx_plaintext_data  = value;
            tx_plaintext_valid = 1'b1;
            do @(posedge clk); while (!tx_plaintext_ready);
            @(negedge clk);
            tx_plaintext_valid = 1'b0;
        end
    endtask

    task automatic start_rx;
        begin
            while (!(rx_cmd_ready && buffer_start_ready)) @(posedge clk);
            @(negedge clk);
            rx_cmd_valid      = 1'b1;
            buffer_start_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rx_cmd_valid       = 1'b0;
            buffer_start_valid = 1'b0;
        end
    endtask

    task automatic send_rx_ciphertext(input logic [127:0] value);
        begin
            @(negedge clk);
            rx_ciphertext_data  = value;
            rx_ciphertext_valid = 1'b1;
            do @(posedge clk); while (!rx_ciphertext_ready);
            @(negedge clk);
            rx_ciphertext_valid = 1'b0;
        end
    endtask

    task automatic send_rx_tag(input logic corrupt);
        begin
            while (!rx_received_tag_ready) @(posedge clk);
            @(negedge clk);
            rx_received_tag = captured_tag ^ (corrupt ? 128'h1 : 128'h0);
            rx_received_tag_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rx_received_tag_valid = 1'b0;
        end
    endtask

    task automatic run_rx_packet(input logic corrupt);
        integer index;
        integer auth_before;
        integer safe_before;
        begin
            expected_auth_ok = !corrupt;
            auth_before = auth_pass_count + auth_fail_count;
            safe_before = safe_plain_count;
            start_rx();
            for (index = 0; index < PAYLOAD_BLOCKS; index = index + 1)
                send_rx_ciphertext(ciphertext[index]);
            send_rx_tag(corrupt);
            while ((auth_pass_count + auth_fail_count) == auth_before)
                @(posedge clk);
            while (rx_busy || buffer_busy) @(posedge clk);
            if (corrupt && (safe_plain_count != safe_before)) begin
                $error("[TB] corrupted packet escaped quarantine buffer");
                test_failed = 1'b1;
            end
            if (!corrupt &&
                (safe_plain_count != (safe_before + PAYLOAD_BLOCKS))) begin
                $error("[TB] authenticated packet was not released");
                test_failed = 1'b1;
            end
        end
    endtask

    integer index;
    initial begin
        tx_cmd_valid          = 1'b0;
        tx_plaintext_data     = 128'h0;
        tx_plaintext_valid    = 1'b0;
        rx_cmd_valid          = 1'b0;
        buffer_start_valid    = 1'b0;
        rx_ciphertext_data    = 128'h0;
        rx_ciphertext_valid   = 1'b0;
        rx_received_tag       = 128'h0;
        rx_received_tag_valid = 1'b0;
        expected_auth_ok      = 1'b0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("[TB] TX reference-vector check");
        start_tx();
        for (index = 0; index < PAYLOAD_BLOCKS; index = index + 1)
            send_tx_plaintext(make_plain(index));
        while (tx_busy) @(posedge clk);

        if ((tx_cipher_count != PAYLOAD_BLOCKS) ||
            (captured_tag !== EXPECTED_TAG)) begin
            $error("[TB] incomplete TX result");
            test_failed = 1'b1;
        end

        $display("[TB] RX valid-TAG check");
        run_rx_packet(1'b0);

        $display("[TB] RX corrupted-TAG rejection check");
        run_rx_packet(1'b1);

        if ((rx_plain_count != 2 * PAYLOAD_BLOCKS) ||
            (safe_plain_count != PAYLOAD_BLOCKS) ||
            (auth_pass_count != 1) || (auth_fail_count != 1)) begin
            $error("[TB] result count mismatch: raw=%0d safe=%0d pass=%0d fail=%0d",
                   rx_plain_count, safe_plain_count,
                   auth_pass_count, auth_fail_count);
            test_failed = 1'b1;
        end

        if (test_failed)
            $fatal(1, "[TB][FAIL] GCM engine test");

        $display("[TB][PASS] GCM TX/RX core engine test");
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "[TB][TIMEOUT] GCM engine test");
    end
endmodule
