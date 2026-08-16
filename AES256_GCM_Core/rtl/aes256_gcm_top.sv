module aes256_gcm_top #(
    // Development/bootstrap key.
    // Replace the FIXED_KEY connections in the TX/RX instances with tx_key
    // and rx_key when the external Session/Key Manager is integrated.
    parameter logic [255:0] FIXED_KEY =
        {128'h000102030405060708090a0b0c0d0e0f,
         128'h101112131415161718191a1b1c1d1e1f}
) (
    input  logic         clk,
    input  logic         rst_n,
    
    // Reserved external key connections for a future Session/Key Manager.
    // They are intentionally unused while FIXED_KEY is selected below.
    input  logic [255:0] tx_key,
    input  logic [255:0] rx_key,
    
    // Session IDs
    input  logic [31:0]  tx_session_id,
    input  logic [31:0]  rx_expected_session_id,
    
    // Tx Control
    input  logic [31:0]  tx_frame_counter,
    input  logic [31:0]  tx_packet_counter,
    input  logic         tx_flag_eof,
    input  logic         tx_flag_sof,
    input  logic         tx_flag_frame1,
    input  logic         tx_flag_frame0,
    
    // Tx Payload Input (1280B)
    input  logic [127:0] tx_s_axis_tdata,
    input  logic         tx_s_axis_tvalid,
    output logic         tx_s_axis_tready,
    input  logic         tx_s_axis_tlast,
    
    // Tx Packet Output (1312B)
    output logic [127:0] tx_m_axis_tdata,
    output logic         tx_m_axis_tvalid,
    input  logic         tx_m_axis_tready,
    output logic         tx_m_axis_tlast,
    output logic         tx_busy,
    
    // Rx Packet Input (1312B)
    input  logic [127:0] rx_s_axis_tdata,
    input  logic         rx_s_axis_tvalid,
    output logic         rx_s_axis_tready,
    input  logic         rx_s_axis_tlast,
    
    // Rx authenticated line output (2 payload packets = 2560B, 160 blocks)
    output logic [127:0] rx_m_axis_tdata,
    output logic         rx_m_axis_tvalid,
    input  logic         rx_m_axis_tready,
    output logic         rx_m_axis_tlast,
    output logic         rx_busy,
    
    // Rx Error Flags
    output logic         rx_anti_replay_err,
    output logic         rx_packet_loss_err,
    output logic         rx_auth_fail_err,
    output logic         rx_length_err,
    output logic         rx_session_err,
    output logic         rx_timeout_err
);

    aes256_gcm_tx_wrapper u_tx_wrapper (
        .clk             (clk),
        .rst_n           (rst_n),
        // Future Session/Key Manager connection:
        // .key          (tx_key),
        .key             (FIXED_KEY),
        .session_id      (tx_session_id),
        .frame_counter   (tx_frame_counter),
        .packet_counter  (tx_packet_counter),
        .flag_eof        (tx_flag_eof),
        .flag_sof        (tx_flag_sof),
        .flag_frame1     (tx_flag_frame1),
        .flag_frame0     (tx_flag_frame0),
        .s_axis_tdata    (tx_s_axis_tdata),
        .s_axis_tvalid   (tx_s_axis_tvalid),
        .s_axis_tready   (tx_s_axis_tready),
        .s_axis_tlast    (tx_s_axis_tlast),
        .m_axis_tdata    (tx_m_axis_tdata),
        .m_axis_tvalid   (tx_m_axis_tvalid),
        .m_axis_tready   (tx_m_axis_tready),
        .m_axis_tlast    (tx_m_axis_tlast),
        .busy            (tx_busy)
    );

    aes256_gcm_rx_wrapper u_rx_wrapper (
        .clk                 (clk),
        .rst_n               (rst_n),
        // Future Session/Key Manager connection:
        // .key              (rx_key),
        .key                 (FIXED_KEY),
        .expected_session_id (rx_expected_session_id),
        .s_axis_tdata        (rx_s_axis_tdata),
        .s_axis_tvalid       (rx_s_axis_tvalid),
        .s_axis_tready       (rx_s_axis_tready),
        .s_axis_tlast        (rx_s_axis_tlast),
        .m_axis_tdata        (rx_m_axis_tdata),
        .m_axis_tvalid       (rx_m_axis_tvalid),
        .m_axis_tready       (rx_m_axis_tready),
        .m_axis_tlast        (rx_m_axis_tlast),
        .anti_replay_err     (rx_anti_replay_err),
        .packet_loss_err     (rx_packet_loss_err),
        .auth_fail_err       (rx_auth_fail_err),
        .length_err          (rx_length_err),
        .session_err         (rx_session_err),
        .timeout_err         (rx_timeout_err),
        .busy                (rx_busy)
    );

endmodule
