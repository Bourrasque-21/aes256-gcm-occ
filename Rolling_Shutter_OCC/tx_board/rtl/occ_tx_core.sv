`timescale 1ns / 1ps

import occ_pkg::*;

// Free-running optical transmitter for the tag board.
//
// The single-board loopback could tie its bit clock to the camera's own HREF, so a
// bit was four rows by construction. A separate tag has no access to that camera,
// so the half-bit period is a runtime input instead: the reader measures its real
// row period and displays the value the tag should be dialled to. Both boards run
// from crystals, so once the ratio is set it stays put.
module occ_tx_core #(
    parameter int unsigned GUARD_HALVES = 4,
    parameter int unsigned COUNT_W      = 16
) (
    input  logic                clk,
    input  logic                reset,
    input  logic                enable,
    input  logic                manchester_enable,
    input  logic [15:0]         payload,
    input  logic [COUNT_W-1:0]  half_bit_clks,

    output logic                led_tx,
    output logic                packet_active
);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_GUARD,
        ST_DATA
    } state_t;

    state_t state;
    logic [COUNT_W-1:0] half_count;
    logic [$clog2(GUARD_HALVES)-1:0] guard_count;
    logic [5:0] bit_index;
    logic       half_phase;
    logic       manchester_latched;
    logic [PACKET_BITS-1:0] packet_latched;
    logic       half_elapsed;
    logic       packet_bit;

    assign half_elapsed  = (half_count >= half_bit_clks - 1);
    assign packet_bit    = packet_latched[PACKET_BITS-1-bit_index];
    assign packet_active = (state == ST_DATA);

    always_comb begin
        led_tx = 1'b0;
        if ((state == ST_DATA) && enable) begin
            if (manchester_latched)
                led_tx = half_phase ? ~packet_bit : packet_bit;
            else
                led_tx = packet_bit;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state              <= ST_IDLE;
            half_count         <= '0;
            guard_count        <= '0;
            bit_index          <= '0;
            half_phase         <= 1'b0;
            manchester_latched <= 1'b0;
            packet_latched     <= '0;
        end else if (!enable) begin
            state       <= ST_IDLE;
            half_count  <= '0;
            guard_count <= '0;
            bit_index   <= '0;
            half_phase  <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    // Latch once per packet so turning the password switches partway
                    // through a transmission cannot produce a half-old codeword.
                    packet_latched     <= {SYNC_WORD, payload, password_crc(payload)};
                    manchester_latched <= manchester_enable;
                    half_count         <= '0;
                    guard_count        <= '0;
                    state              <= ST_GUARD;
                end

                ST_GUARD: begin
                    if (half_elapsed) begin
                        half_count <= '0;
                        if (guard_count == GUARD_HALVES - 1) begin
                            bit_index  <= '0;
                            half_phase <= 1'b0;
                            state      <= ST_DATA;
                        end else begin
                            guard_count <= guard_count + 1'b1;
                        end
                    end else begin
                        half_count <= half_count + 1'b1;
                    end
                end

                ST_DATA: begin
                    if (half_elapsed) begin
                        half_count <= '0;
                        if (!half_phase) begin
                            half_phase <= 1'b1;
                        end else if (bit_index == PACKET_BITS - 1) begin
                            // Straight back to the next packet: the reader only sees
                            // 240 of the ~510 line periods in a frame, so repeating
                            // without a pause is what gets a whole packet inside the
                            // captured window.
                            half_phase <= 1'b0;
                            state      <= ST_IDLE;
                        end else begin
                            half_phase <= 1'b0;
                            bit_index  <= bit_index + 1'b1;
                        end
                    end else begin
                        half_count <= half_count + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
