`timescale 1ns / 1ps

import occ_pkg::*;

// Tag board: transmits one credential over the optical link, continuously.
//
// No camera. The only tricky part is the bit period, which has to match the
// reader's four-rows-per-bit assumption. The reader measures its own row period
// and shows the number to dial in here, so calibration is reading one hex value
// off one board and matching it on the other.
module top_tag_tx (
    input  logic       clk,
    input  logic       reset,

    input  logic [3:0] sw_slot,      // SW3:SW0  credential select
    input  logic [7:0] sw_trim,      // SW11:SW4 half-bit period trim
    input  logic       sw_manchester, // SW14
    input  logic       sw_tx_enable,  // SW15
    input  logic       btn_show_trim, // BTNU: show the dialled period instead

    output logic       led_tx,
    output logic [8:0] status_led,
    output logic [3:0] fnd_digit,
    output logic [7:0] fnd_data
);

    // The switches encode the half-bit period outright rather than trimming around a
    // compiled-in guess. A guess is exactly what went wrong first time: the QVGA PCLK
    // divider also halves the frame rate, which put the real row period at ~125 us
    // instead of the assumed ~65, and no trim range around the wrong centre could
    // reach it. Spanning 128..32768 clocks in 128-clock steps covers any plausible
    // row period, and a 0.5 % step leaves under half a row of drift across a packet.
    logic [15:0] half_bit_clks;
    logic [15:0] active_password;
    logic        packet_active;
    logic        show_trim;

    (* ASYNC_REG = "TRUE" *) logic [1:0] enable_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] manchester_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] show_trim_sync;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            enable_sync     <= '0;
            manchester_sync <= '0;
            show_trim_sync  <= '0;
        end else begin
            enable_sync     <= {enable_sync[0], sw_tx_enable};
            manchester_sync <= {manchester_sync[0], sw_manchester};
            show_trim_sync  <= {show_trim_sync[0], btn_show_trim};
        end
    end

    assign show_trim = show_trim_sync[1];

    assign half_bit_clks = {sw_trim, 7'b0000000} + 16'd128;

    assign active_password = password(sw_slot);

    occ_tx_core #(
        .GUARD_HALVES(4),
        .COUNT_W     (16)
    ) u_occ_tx_core (
        .clk              (clk),
        .reset            (reset),
        .enable           (enable_sync[1]),
        .manchester_enable(manchester_sync[1]),
        .payload          (active_password),
        .half_bit_clks    (half_bit_clks),
        .led_tx           (led_tx),
        .packet_active    (packet_active)
    );

    fnd_controller u_fnd_controller (
        .clk      (clk),
        .reset    (reset),
        .segments (show_trim ? seg_word(half_bit_clks) : seg_word(active_password)),
        .fnd_digit(fnd_digit),
        .fnd_data (fnd_data)
    );

    always_comb begin
        status_led    = '0;
        status_led[0] = led_tx;
        status_led[1] = enable_sync[1];
        status_led[2] = packet_active;
        status_led[3] = manchester_sync[1];
        status_led[8] = show_trim;
    end

endmodule
