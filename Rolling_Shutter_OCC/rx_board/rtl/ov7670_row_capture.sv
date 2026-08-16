`timescale 1ns / 1ps

module ov7670_row_capture #(
    parameter int unsigned FRAME_LINES = 240,
    parameter int unsigned ROI_X_START = 128,
    parameter int unsigned ROI_X_END   = 191,
    parameter int unsigned SUM_WIDTH   = $clog2(((ROI_X_END - ROI_X_START + 1) * 31) + 1)
) (
    input  logic                        pclk,
    input  logic                        reset,
    input  logic                        href,
    input  logic                        vsync,
    input  logic [7:0]                  pdata,
    output logic                        line_valid,
    output logic [$clog2(FRAME_LINES)-1:0] line_index,
    output logic [SUM_WIDTH-1:0]        line_metric,
    output logic                        frame_done,
    output logic [$clog2(FRAME_LINES+1)-1:0] frame_lines,
    // Pixel tap for the VGA framebuffer. The decoder itself never needs these -
    // it only consumes line_metric - so they exist purely to make the banding
    // visible on a monitor.
    output logic                        pix_valid,
    output logic [8:0]                  pix_x,
    output logic [$clog2(FRAME_LINES)-1:0] pix_y,
    output logic [7:0]                  pix_data
);

    logic href_d;
    logic vsync_d;
    logic byte_phase;
    logic [7:0] byte_high;
    logic [8:0] pixel_x;
    logic [SUM_WIDTH-1:0] row_sum;
    logic [$clog2(FRAME_LINES+1)-1:0] row_count;

    always_ff @(posedge pclk or posedge reset) begin
        if (reset) begin
            href_d      <= 1'b0;
            vsync_d     <= 1'b0;
            byte_phase  <= 1'b0;
            byte_high   <= '0;
            pixel_x     <= '0;
            row_sum     <= '0;
            row_count   <= '0;
            line_valid  <= 1'b0;
            line_index  <= '0;
            line_metric <= '0;
            frame_done  <= 1'b0;
            frame_lines <= '0;
            pix_valid   <= 1'b0;
            pix_x       <= '0;
            pix_y       <= '0;
            pix_data    <= '0;
        end else begin
            href_d     <= href;
            vsync_d    <= vsync;
            line_valid <= 1'b0;
            frame_done <= 1'b0;
            pix_valid  <= 1'b0;

            if (vsync) begin
                byte_phase <= 1'b0;
                if (!vsync_d) begin
                    frame_lines <= row_count;
                    frame_done  <= (row_count != 0);
                    row_count   <= '0;
                end
            end else if (href) begin
                if (!href_d) begin
                    // HREF starts with the first (upper) RGB565 byte.
                    pixel_x    <= '0;
                    row_sum    <= '0;
                    byte_high  <= pdata;
                    byte_phase <= 1'b1;
                end else if (!byte_phase) begin
                    byte_high  <= pdata;
                    byte_phase <= 1'b1;
                end else begin
                    byte_phase <= 1'b0;

                    // In RGB565 the red sample is byte_high[7:3].
                    if ((pixel_x >= ROI_X_START) && (pixel_x <= ROI_X_END)) begin
                        row_sum <= row_sum + byte_high[7:3];
                    end

                    if ((pixel_x < 320) && (row_count < FRAME_LINES)) begin
                        pix_valid <= 1'b1;
                        pix_x     <= pixel_x;
                        pix_y     <= row_count[$clog2(FRAME_LINES)-1:0];
                        // Red expanded to eight bits; the LED is red, so this is
                        // the channel the banding actually lives in.
                        pix_data  <= {byte_high[7:3], byte_high[7:5]};
                    end

                    pixel_x <= pixel_x + 1'b1;
                end
            end else begin
                byte_phase <= 1'b0;

                if (href_d && (row_count < FRAME_LINES)) begin
                    line_index  <= row_count[$clog2(FRAME_LINES)-1:0];
                    line_metric <= row_sum;
                    line_valid  <= 1'b1;
                    row_count   <= row_count + 1'b1;
                end
            end
        end
    end

endmodule
