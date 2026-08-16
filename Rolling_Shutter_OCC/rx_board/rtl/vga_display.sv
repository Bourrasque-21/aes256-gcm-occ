`timescale 1ns / 1ps

// 640x480 @ 60 Hz driven from the 100 MHz system clock with a one-in-four enable
// rather than a divided clock, so no second clock domain is introduced. The stored
// 320x240 image is doubled to fill the screen.
module vga_display #(
    parameter int unsigned SRC_WIDTH   = 320,
    parameter int unsigned SRC_HEIGHT  = 240,
    parameter int unsigned ROI_X_START = 128,
    parameter int unsigned ROI_X_END   = 191
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        pixel_tick,

    output logic [16:0] fb_addr,
    input  logic [7:0]  fb_data,

    output logic        h_sync,
    output logic        v_sync,
    output logic [3:0]  port_red,
    output logic [3:0]  port_green,
    output logic [3:0]  port_blue
);

    localparam int unsigned H_VISIBLE = 640;
    localparam int unsigned H_FRONT   = 16;
    localparam int unsigned H_SYNC    = 96;
    localparam int unsigned H_TOTAL   = 800;

    localparam int unsigned V_VISIBLE = 480;
    localparam int unsigned V_FRONT   = 10;
    localparam int unsigned V_SYNC    = 2;
    localparam int unsigned V_TOTAL   = 525;

    logic [9:0] h_count;
    logic [9:0] v_count;

    logic hs_raw, vs_raw, de_raw, roi_edge_raw;
    logic hs_q,  vs_q,  de_q,  roi_edge_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            h_count <= '0;
            v_count <= '0;
        end else if (pixel_tick) begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= '0;
                v_count <= (v_count == V_TOTAL - 1) ? '0 : (v_count + 1'b1);
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    // Source coordinates: the screen is exactly twice the stored image.
    logic [8:0] src_x;
    logic [7:0] src_y;

    assign src_x = h_count[9:1];
    assign src_y = v_count[9:1];

    // Outside the visible area src_y runs past the stored image, so the address is
    // parked at zero rather than allowed to leave the buffer.
    assign fb_addr = (de_raw && (src_y < SRC_HEIGHT))
                   ? ((17'(src_y) * 17'(SRC_WIDTH)) + 17'(src_x))
                   : 17'd0;

    assign hs_raw = ~((h_count >= H_VISIBLE + H_FRONT) &&
                      (h_count <  H_VISIBLE + H_FRONT + H_SYNC));
    assign vs_raw = ~((v_count >= V_VISIBLE + V_FRONT) &&
                      (v_count <  V_VISIBLE + V_FRONT + V_SYNC));
    assign de_raw = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);

    // Mark the columns the decoder actually integrates, so the light source can be
    // lined up by eye instead of by guessing at the metric.
    assign roi_edge_raw = de_raw && ((src_x == ROI_X_START) || (src_x == ROI_X_END));

    // The framebuffer read is registered, so the sync and blank signals ride one
    // pixel behind the counters to stay aligned with the data.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            hs_q       <= 1'b1;
            vs_q       <= 1'b1;
            de_q       <= 1'b0;
            roi_edge_q <= 1'b0;
        end else if (pixel_tick) begin
            hs_q       <= hs_raw;
            vs_q       <= vs_raw;
            de_q       <= de_raw;
            roi_edge_q <= roi_edge_raw;
        end
    end

    assign h_sync = hs_q;
    assign v_sync = vs_q;

    always_comb begin
        port_red   = 4'h0;
        port_green = 4'h0;
        port_blue  = 4'h0;

        if (de_q) begin
            if (roi_edge_q) begin
                port_green = 4'hF;
            end else begin
                // Greyscale: banding is a brightness pattern, so colour would only
                // make the bands harder to judge.
                port_red   = fb_data[7:4];
                port_green = fb_data[7:4];
                port_blue  = fb_data[7:4];
            end
        end
    end

endmodule
