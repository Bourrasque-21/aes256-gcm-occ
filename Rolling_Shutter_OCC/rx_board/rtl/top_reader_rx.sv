`timescale 1ns / 1ps

import occ_pkg::*;

// Reader board: watches for a tag, compares the credential it recovers against the
// one selected on the switches, and reports the verdict to the PC over UART.
//
// Also measures its own camera row period and displays the half-bit count the tag
// should be set to, which is what makes calibrating two independent boards a matter
// of copying one number rather than sweeping blindly.
module top_reader_rx (
    input  logic       clk,
    input  logic       reset,
    input  logic       start_btn,

    input  logic       pclk,
    input  logic       href,
    input  logic       vsync,
    input  logic [7:0] pdata,
    output logic       xclk,
    output logic       scl,
    inout  wire        sda,

    input  logic [3:0] sw_slot,       // SW3:SW0  credential this reader accepts
    input  logic [1:0] sw_exposure,   // SW5:SW4
    input  logic [1:0] sw_gain,       // SW7:SW6
    input  logic [1:0] sw_fnd_mode,   // SW9:SW8
    input  logic       sw_manchester,  // SW14
    input  logic       sw_banding_off, // SW15

    output logic       uart_tx_pin,
    output logic [8:0] status_led,
    output logic [3:0] fnd_digit,
    output logic [7:0] fnd_data,

    output logic       h_sync,
    output logic       v_sync,
    output logic [3:0] port_red,
    output logic [3:0] port_green,
    output logic [3:0] port_blue
);

    localparam int unsigned FRAME_LINES  = 240;
    localparam int unsigned ROI_X_START  = 128;
    localparam int unsigned ROI_X_END    = 191;
    localparam int unsigned METRIC_WIDTH = $clog2(((ROI_X_END - ROI_X_START + 1) * 31) + 1);

    // Row period is measured over this many rows, starting far enough into the frame
    // that the window never straddles vertical blanking.
    localparam int unsigned MEAS_SKIP  = 8;
    localparam int unsigned MEAS_ROWS  = 64;
    localparam int unsigned STALE_TICKS = 100_000_000; // one second
    localparam int unsigned SHIFT_TICKS = 10_000_000;  // 100 ms per digit
    localparam int unsigned SEND_GAP    = 50_000_000;  // 500 ms between UART lines

    logic [1:0] xclk_divider;
    logic pixel_tick;

    (* ASYNC_REG = "TRUE" *) logic [1:0] button_sync;
    logic button_sync_d;
    logic restart_pulse;

    (* ASYNC_REG = "TRUE" *) logic [1:0] manchester_sys;
    (* ASYNC_REG = "TRUE" *) logic [1:0] manchester_pclk;
    (* ASYNC_REG = "TRUE" *) logic [1:0] init_done_pclk;
    (* ASYNC_REG = "TRUE" *) logic [1:0] banding_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] exposure_meta, exposure_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] gain_meta, gain_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] fnd_mode_meta, fnd_mode_sync;
    (* ASYNC_REG = "TRUE" *) logic [3:0] slot_meta, slot_sync;

    logic init_done;
    logic init_ack_error;
    logic camera_path_reset;

    logic line_valid;
    logic [$clog2(FRAME_LINES)-1:0] line_index;
    logic [METRIC_WIDTH-1:0] line_metric;
    logic frame_done;
    logic [$clog2(FRAME_LINES+1)-1:0] frame_lines;

    logic pix_valid;
    logic [8:0] pix_x;
    logic [$clog2(FRAME_LINES)-1:0] pix_y;
    logic [7:0] pix_data;
    logic [16:0] fb_waddr, fb_raddr;
    logic [7:0]  fb_rdata;

    logic [15:0] rx_password_pclk;
    logic rx_valid_toggle_pclk;
    logic frame_seen_pclk, sync_seen_pclk, crc_ok_pclk, decode_error_pclk;
    logic [METRIC_WIDTH-1:0] frame_contrast_pclk, frame_peak_pclk;
    logic [$clog2(FRAME_LINES+1)-1:0] frame_rows_pclk;
    logic frame_scan_toggle_pclk;

    (* ASYNC_REG = "TRUE" *) logic [2:0] rx_toggle_sync;
    logic rx_toggle_seen;
    logic [15:0] rx_password;
    logic have_password;

    (* ASYNC_REG = "TRUE" *) logic [3:0] rx_status_meta, rx_status_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] scan_toggle_sync;
    logic scan_toggle_seen;
    logic [METRIC_WIDTH-1:0] contrast_display, peak_display;
    logic [$clog2(FRAME_LINES+1)-1:0] rows_display;

    logic row_toggle_pclk, frame_toggle_pclk;
    (* ASYNC_REG = "TRUE" *) logic [2:0] row_toggle_sync, frame_toggle_sync;
    logic row_tick, frame_tick;

    logic [7:0]  meas_rows;
    logic [23:0] meas_count;
    logic        meas_active;
    logic [15:0] half_bit_target;

    logic [15:0] shown;
    logic [2:0]  shift_step;
    logic [23:0] shift_timer;
    logic [26:0] stale_count;
    logic link_stale;

    logic match;
    logic [3:0] msg_index;
    logic       msg_active;
    logic       msg_match;
    logic [15:0] msg_password;
    logic [25:0] send_gap;
    logic uart_send;
    logic [7:0] uart_data;
    logic uart_busy;
    logic uart_busy_d;

    logic [31:0] fnd_segments;
    logic [15:0] hex_value;

    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            xclk_divider <= '0;
        else
            xclk_divider <= xclk_divider + 1'b1;
    end

    assign xclk       = xclk_divider[1];
    assign pixel_tick = (xclk_divider == 2'd3);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            button_sync    <= '0;
            button_sync_d  <= 1'b0;
            manchester_sys <= '0;
            banding_sync   <= '0;
            exposure_meta  <= '0;
            exposure_sync  <= '0;
            gain_meta      <= '0;
            gain_sync      <= '0;
            fnd_mode_meta  <= '0;
            fnd_mode_sync  <= '0;
            slot_meta      <= '0;
            slot_sync      <= '0;
        end else begin
            button_sync    <= {button_sync[0], start_btn};
            button_sync_d  <= button_sync[1];
            manchester_sys <= {manchester_sys[0], sw_manchester};
            banding_sync   <= {banding_sync[0], sw_banding_off};
            exposure_meta  <= sw_exposure;
            exposure_sync  <= exposure_meta;
            gain_meta      <= sw_gain;
            gain_sync      <= gain_meta;
            fnd_mode_meta  <= sw_fnd_mode;
            fnd_mode_sync  <= fnd_mode_meta;
            slot_meta      <= sw_slot;
            slot_sync      <= slot_meta;
        end
    end

    assign restart_pulse = button_sync[1] & ~button_sync_d;

    ov7670_init u_ov7670_init (
        .clk         (clk),
        .reset       (reset),
        .restart     (restart_pulse),
        .gain_sel    (gain_sync),
        .exposure_sel(exposure_sync),
        .banding_off (banding_sync[1]),
        .init_done   (init_done),
        .ack_error   (init_ack_error),
        .scl         (scl),
        .sda         (sda)
    );

    always_ff @(posedge pclk or posedge reset) begin
        if (reset) begin
            init_done_pclk  <= '0;
            manchester_pclk <= '0;
        end else begin
            init_done_pclk  <= {init_done_pclk[0], init_done};
            manchester_pclk <= {manchester_pclk[0], sw_manchester};
        end
    end

    assign camera_path_reset = reset | ~init_done_pclk[1];

    ov7670_row_capture #(
        .FRAME_LINES(FRAME_LINES),
        .ROI_X_START(ROI_X_START),
        .ROI_X_END  (ROI_X_END),
        .SUM_WIDTH  (METRIC_WIDTH)
    ) u_row_capture (
        .pclk       (pclk),
        .reset      (camera_path_reset),
        .href       (href),
        .vsync      (vsync),
        .pdata      (pdata),
        .line_valid (line_valid),
        .line_index (line_index),
        .line_metric(line_metric),
        .frame_done (frame_done),
        .frame_lines(frame_lines),
        .pix_valid  (pix_valid),
        .pix_x      (pix_x),
        .pix_y      (pix_y),
        .pix_data   (pix_data)
    );

    occ_rx_core #(
        .FRAME_LINES (FRAME_LINES),
        .METRIC_WIDTH(METRIC_WIDTH),
        .ROWS_PER_BIT(4),
        .MIN_CONTRAST(64)
    ) u_occ_rx_core (
        .pclk                 (pclk),
        .reset                (camera_path_reset),
        .manchester_enable    (manchester_pclk[1]),
        .line_valid           (line_valid),
        .line_index           (line_index),
        .line_metric          (line_metric),
        .frame_done           (frame_done),
        .frame_lines          (frame_lines),
        .rx_password          (rx_password_pclk),
        .password_valid_toggle(rx_valid_toggle_pclk),
        .frame_seen           (frame_seen_pclk),
        .sync_seen            (sync_seen_pclk),
        .crc_ok               (crc_ok_pclk),
        .decode_error         (decode_error_pclk),
        .frame_contrast       (frame_contrast_pclk),
        .frame_peak           (frame_peak_pclk),
        .frame_rows           (frame_rows_pclk),
        .frame_scan_toggle    (frame_scan_toggle_pclk)
    );

    // Row and frame events crossed as toggles so no pulse can be dropped.
    always_ff @(posedge pclk or posedge camera_path_reset) begin
        if (camera_path_reset) begin
            row_toggle_pclk   <= 1'b0;
            frame_toggle_pclk <= 1'b0;
        end else begin
            if (line_valid)
                row_toggle_pclk <= ~row_toggle_pclk;
            if (frame_done)
                frame_toggle_pclk <= ~frame_toggle_pclk;
        end
    end

    assign row_tick   = row_toggle_sync[2]   ^ row_toggle_sync[1];
    assign frame_tick = frame_toggle_sync[2] ^ frame_toggle_sync[1];

    assign fb_waddr = (17'(pix_y) * 17'd320) + 17'(pix_x);

    frame_buffer u_frame_buffer (
        .wclk (pclk),
        .we   (pix_valid),
        .waddr(fb_waddr),
        .wdata(pix_data),
        .rclk (clk),
        .ren  (pixel_tick),
        .raddr(fb_raddr),
        .rdata(fb_rdata)
    );

    vga_display #(
        .SRC_WIDTH  (320),
        .SRC_HEIGHT (FRAME_LINES),
        .ROI_X_START(ROI_X_START),
        .ROI_X_END  (ROI_X_END)
    ) u_vga_display (
        .clk       (clk),
        .reset     (reset),
        .pixel_tick(pixel_tick),
        .fb_addr   (fb_raddr),
        .fb_data   (fb_rdata),
        .h_sync    (h_sync),
        .v_sync    (v_sync),
        .port_red  (port_red),
        .port_green(port_green),
        .port_blue (port_blue)
    );

    uart_tx #(
        .CLK_HZ   (100_000_000),
        .BAUD_RATE(115_200)
    ) u_uart_tx (
        .clk  (clk),
        .reset(reset),
        .send (uart_send),
        .data (uart_data),
        .busy (uart_busy),
        .tx   (uart_tx_pin)
    );

    assign match = (rx_password == password(slot_sync));

    // Eleven bytes: "OPEN 1A2B\r\n" or "DENY 1A2B\r\n". Equal length keeps one FSM.
    function automatic logic [7:0] verdict_byte(
        input logic [3:0]  index,
        input logic        granted,
        input logic [15:0] value
    );
        case (index)
            4'd0:    verdict_byte = granted ? "O" : "D";
            4'd1:    verdict_byte = granted ? "P" : "E";
            4'd2:    verdict_byte = granted ? "E" : "N";
            4'd3:    verdict_byte = granted ? "N" : "Y";
            4'd4:    verdict_byte = " ";
            4'd5:    verdict_byte = hex_ascii(value[15:12]);
            4'd6:    verdict_byte = hex_ascii(value[11:8]);
            4'd7:    verdict_byte = hex_ascii(value[7:4]);
            4'd8:    verdict_byte = hex_ascii(value[3:0]);
            4'd9:    verdict_byte = 8'h0D;
            default: verdict_byte = 8'h0A;
        endcase
    endfunction

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rx_toggle_sync   <= '0;
            rx_toggle_seen   <= 1'b0;
            rx_password      <= '0;
            have_password    <= 1'b0;
            rx_status_meta   <= '0;
            rx_status_sync   <= '0;
            scan_toggle_sync <= '0;
            scan_toggle_seen <= 1'b0;
            contrast_display <= '0;
            peak_display     <= '0;
            rows_display     <= '0;
            row_toggle_sync  <= '0;
            frame_toggle_sync <= '0;
            meas_rows        <= '0;
            meas_count       <= '0;
            meas_active      <= 1'b0;
            half_bit_target  <= '0;
            shown            <= '0;
            shift_step       <= 3'd4;
            shift_timer      <= '0;
            stale_count      <= '0;
            link_stale       <= 1'b0;
            msg_index        <= '0;
            msg_active       <= 1'b0;
            msg_match        <= 1'b0;
            msg_password     <= '0;
            send_gap         <= '0;
            uart_send        <= 1'b0;
            uart_data        <= '0;
            uart_busy_d      <= 1'b0;
        end else begin
            rx_toggle_sync    <= {rx_toggle_sync[1:0], rx_valid_toggle_pclk};
            scan_toggle_sync  <= {scan_toggle_sync[1:0], frame_scan_toggle_pclk};
            row_toggle_sync   <= {row_toggle_sync[1:0], row_toggle_pclk};
            frame_toggle_sync <= {frame_toggle_sync[1:0], frame_toggle_pclk};
            rx_status_meta    <= {decode_error_pclk, crc_ok_pclk, sync_seen_pclk, frame_seen_pclk};
            rx_status_sync    <= rx_status_meta;
            uart_send         <= 1'b0;
            uart_busy_d       <= uart_busy;

            // Row period, measured between two row ticks a fixed number of rows apart.
            // The window starts a few rows into the frame so it can never include the
            // long vertical blanking gap. The tag needs this to better than about
            // 0.6 %, so the endpoints have to bracket exactly MEAS_ROWS periods.
            if (frame_tick) begin
                meas_rows   <= '0;
                meas_count  <= '0;
                meas_active <= 1'b0;
            end else if (row_tick) begin
                meas_rows <= meas_rows + 1'b1;
                if (meas_rows == MEAS_SKIP - 1) begin
                    meas_active <= 1'b1;
                    meas_count  <= '0;
                end else if (meas_rows == MEAS_SKIP + MEAS_ROWS - 1) begin
                    // Two rows make a half-bit, so MEAS_ROWS periods hold MEAS_ROWS/2.
                    meas_active     <= 1'b0;
                    half_bit_target <= 16'((meas_count + 1) / (MEAS_ROWS / 2));
                end else if (meas_active) begin
                    meas_count <= meas_count + 1'b1;
                end
            end else if (meas_active) begin
                meas_count <= meas_count + 1'b1;
            end

            if (rx_toggle_sync[2] != rx_toggle_seen) begin
                rx_toggle_seen <= rx_toggle_sync[2];
                rx_password    <= rx_password_pclk;
                have_password  <= 1'b1;
                stale_count    <= '0;
                link_stale     <= 1'b0;

                if (rx_password_pclk != shown) begin
                    shift_step  <= '0;
                    shift_timer <= '0;
                end

                if (send_gap == 0) begin
                    msg_match    <= (rx_password_pclk == password(slot_sync));
                    msg_password <= rx_password_pclk;
                    msg_index    <= '0;
                    msg_active   <= 1'b1;
                    send_gap     <= SEND_GAP;
                end
            end else if (stale_count == STALE_TICKS - 1) begin
                link_stale <= 1'b1;
            end else begin
                stale_count <= stale_count + 1'b1;
            end

            if (send_gap != 0)
                send_gap <= send_gap - 1'b1;

            // Shift the recovered credential in one digit at a time so the display
            // shows it arriving rather than snapping.
            if (shift_step < 3'd4) begin
                if (shift_timer == SHIFT_TICKS - 1) begin
                    shift_timer <= '0;
                    shift_step  <= shift_step + 1'b1;
                    case (shift_step)
                        3'd0:    shown <= {shown[11:0], rx_password[15:12]};
                        3'd1:    shown <= {shown[11:0], rx_password[11:8]};
                        3'd2:    shown <= {shown[11:0], rx_password[7:4]};
                        default: shown <= {shown[11:0], rx_password[3:0]};
                    endcase
                end else begin
                    shift_timer <= shift_timer + 1'b1;
                end
            end

            if (scan_toggle_sync[2] != scan_toggle_seen) begin
                scan_toggle_seen <= scan_toggle_sync[2];
                contrast_display <= frame_contrast_pclk;
                peak_display     <= frame_peak_pclk;
                rows_display     <= frame_rows_pclk;
            end

            // One byte handed to the UART on each falling edge of busy. The byte is
            // registered here rather than decoded from msg_index combinationally:
            // msg_index advances on this same edge, but uart_tx does not sample its
            // data until the next one, so a combinational feed would hand over the
            // following byte and drop the first character of every message.
            if (msg_active && !uart_busy && !uart_busy_d && !uart_send) begin
                uart_send <= 1'b1;
                uart_data <= verdict_byte(msg_index, msg_match, msg_password);
                if (msg_index == 4'd10) begin
                    msg_active <= 1'b0;
                    msg_index  <= '0;
                end else begin
                    msg_index <= msg_index + 1'b1;
                end
            end
        end
    end

    always_comb begin
        case (fnd_mode_sync)
            2'b01:   hex_value = 16'(contrast_display);
            2'b10:   hex_value = 16'(peak_display);
            default: hex_value = 16'(rows_display);
        endcase

        if (fnd_mode_sync == 2'b00)
            fnd_segments = (link_stale || !have_password)
                         ? {4{SEG_DASH}}
                         : seg_word(shown);
        else if (fnd_mode_sync == 2'b11)
            fnd_segments = seg_word(half_bit_target);
        else
            fnd_segments = seg_word(hex_value);
    end

    fnd_controller u_fnd_controller (
        .clk      (clk),
        .reset    (reset),
        .segments (fnd_segments),
        .fnd_digit(fnd_digit),
        .fnd_data (fnd_data)
    );

    always_comb begin
        status_led    = '0;
        status_led[0] = init_done;
        status_led[1] = rx_status_sync[0];             // camera frame received
        status_led[2] = rx_status_sync[1];             // sync word found
        status_led[3] = rx_status_sync[2];             // CRC passed
        status_led[4] = have_password & ~link_stale;   // tag present
        status_led[5] = have_password & ~link_stale & match;  // credential accepted
        status_led[6] = msg_active;
        status_led[7] = init_ack_error;
        status_led[8] = rx_status_sync[3];             // decode error
    end

endmodule
