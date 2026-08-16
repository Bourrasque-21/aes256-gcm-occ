`timescale 1ns / 1ps

import occ_pkg::*;

// Recovers one packet per camera frame from the per-row brightness metric.
//
// Runs entirely in the PCLK domain during vertical blanking, after the frame it is
// working on has finished arriving.
module occ_rx_core #(
    parameter int unsigned FRAME_LINES  = 240,
    parameter int unsigned METRIC_WIDTH = 11,
    parameter int unsigned ROWS_PER_BIT = 4,
    parameter int unsigned MIN_CONTRAST = 64
) (
    input  logic                             pclk,
    input  logic                             reset,
    input  logic                             manchester_enable,
    input  logic                             line_valid,
    input  logic [$clog2(FRAME_LINES)-1:0]   line_index,
    input  logic [METRIC_WIDTH-1:0]          line_metric,
    input  logic                             frame_done,
    input  logic [$clog2(FRAME_LINES+1)-1:0] frame_lines,

    output logic [15:0]                      rx_password,
    output logic                             password_valid_toggle,
    output logic                             frame_seen,
    output logic                             sync_seen,
    output logic                             crc_ok,
    output logic                             decode_error,

    output logic [METRIC_WIDTH-1:0]          frame_contrast,
    output logic [METRIC_WIDTH-1:0]          frame_peak,
    output logic [$clog2(FRAME_LINES+1)-1:0] frame_rows,
    output logic                             frame_scan_toggle
);

    localparam int unsigned PACKET_ROWS  = PACKET_BITS * ROWS_PER_BIT;
    localparam int unsigned HALF_ROWS    = ROWS_PER_BIT / 2;
    localparam int unsigned ROW_INDEX_W  = $clog2(FRAME_LINES);
    localparam int unsigned LINE_COUNT_W = $clog2(FRAME_LINES + 1);

    typedef enum logic [2:0] {
        ST_WAIT_FRAME,
        ST_MINMAX,
        ST_SEARCH,
        ST_PAYLOAD,
        ST_CRC,
        ST_CHECK
    } state_t;

    state_t state;
    logic [METRIC_WIDTH-1:0] row_memory [0:FRAME_LINES-1];
    logic [ROW_INDEX_W-1:0]  scan_index;
    logic [LINE_COUNT_W-1:0] line_count_latched;
    logic [METRIC_WIDTH-1:0] min_metric;
    logic [METRIC_WIDTH-1:0] max_metric;
    logic [METRIC_WIDTH-1:0] threshold;
    logic [METRIC_WIDTH-1:0] scan_metric;
    logic [METRIC_WIDTH-1:0] min_next;
    logic [METRIC_WIDTH-1:0] max_next;
    logic [ROW_INDEX_W-1:0]  candidate_start;
    logic [ROW_INDEX_W-1:0]  packet_start;
    logic [4:0] header_index;
    logic [4:0] payload_index;
    logic [3:0] crc_index;
    logic [15:0] payload_shift;
    logic [7:0]  crc_shift;
    logic manchester_latched;

    integer bit_row_base;
    integer sample_row_a;
    integer sample_row_b;
    logic sample_a;
    logic sample_b;
    logic decoded_bit;
    logic decoded_valid;

    always_comb begin
        scan_metric = row_memory[scan_index];
        min_next    = (scan_metric < min_metric) ? scan_metric : min_metric;
        max_next    = (scan_metric > max_metric) ? scan_metric : max_metric;

        bit_row_base = 0;
        case (state)
            ST_SEARCH:  bit_row_base = candidate_start + (header_index * ROWS_PER_BIT);
            ST_PAYLOAD: bit_row_base = packet_start + ((HEADER_BITS + payload_index) * ROWS_PER_BIT);
            ST_CRC:     bit_row_base = packet_start + ((HEADER_BITS + PW_BITS + crc_index) * ROWS_PER_BIT);
            default:    bit_row_base = 0;
        endcase

        sample_row_a = bit_row_base + (HALF_ROWS / 2);
        sample_row_b = bit_row_base + HALF_ROWS + (HALF_ROWS / 2);
        sample_a     = (row_memory[sample_row_a] > threshold);
        sample_b     = (row_memory[sample_row_b] > threshold);

        if (manchester_latched) begin
            // Manchester guarantees a transition inside every bit, so the two halves
            // disagreeing is what makes the bit trustworthy.
            decoded_valid = sample_a ^ sample_b;
            decoded_bit   = sample_a;
        end else begin
            decoded_valid = 1'b1;
            decoded_bit   = (row_memory[bit_row_base + (ROWS_PER_BIT / 2)] > threshold);
        end
    end

    always_ff @(posedge pclk or posedge reset) begin
        if (reset) begin
            state                 <= ST_WAIT_FRAME;
            scan_index            <= '0;
            line_count_latched    <= '0;
            min_metric            <= {METRIC_WIDTH{1'b1}};
            max_metric            <= '0;
            threshold             <= '0;
            candidate_start       <= '0;
            packet_start          <= '0;
            header_index          <= '0;
            payload_index         <= '0;
            crc_index             <= '0;
            payload_shift         <= '0;
            crc_shift             <= '0;
            manchester_latched    <= 1'b0;
            rx_password           <= '0;
            password_valid_toggle <= 1'b0;
            frame_seen            <= 1'b0;
            sync_seen             <= 1'b0;
            crc_ok                <= 1'b0;
            decode_error          <= 1'b0;
            frame_contrast        <= '0;
            frame_peak            <= '0;
            frame_rows            <= '0;
            frame_scan_toggle     <= 1'b0;
        end else begin
            if (line_valid)
                row_memory[line_index] <= line_metric;

            if (frame_done) begin
                frame_seen         <= 1'b1;
                sync_seen          <= 1'b0;
                crc_ok             <= 1'b0;
                decode_error       <= 1'b0;
                line_count_latched <= frame_lines;
                manchester_latched <= manchester_enable;
                scan_index         <= '0;
                min_metric         <= {METRIC_WIDTH{1'b1}};
                max_metric         <= '0;
                frame_rows         <= frame_lines;
                frame_scan_toggle  <= ~frame_scan_toggle;

                if (frame_lines >= PACKET_ROWS)
                    state <= ST_MINMAX;
                else begin
                    decode_error <= 1'b1;
                    state        <= ST_WAIT_FRAME;
                end
            end else begin
                case (state)
                    ST_WAIT_FRAME: begin
                        // Idle until the next completed camera frame.
                    end

                    ST_MINMAX: begin
                        min_metric <= min_next;
                        max_metric <= max_next;

                        if (scan_index == line_count_latched - 1'b1) begin
                            threshold       <= ({1'b0, min_next} + {1'b0, max_next}) >> 1;
                            candidate_start <= '0;
                            header_index    <= '0;

                            frame_contrast    <= max_next - min_next;
                            frame_peak        <= max_next;
                            frame_scan_toggle <= ~frame_scan_toggle;

                            if ((max_next - min_next) >= MIN_CONTRAST)
                                state <= ST_SEARCH;
                            else begin
                                decode_error <= 1'b1;
                                state        <= ST_WAIT_FRAME;
                            end
                        end else begin
                            scan_index <= scan_index + 1'b1;
                        end
                    end

                    ST_SEARCH: begin
                        if ((candidate_start + PACKET_ROWS) > line_count_latched) begin
                            decode_error <= 1'b1;
                            state        <= ST_WAIT_FRAME;
                        end else if (!decoded_valid ||
                                     (decoded_bit != SYNC_WORD[HEADER_BITS-1-header_index])) begin
                            header_index <= '0;
                            if ((candidate_start + 1'b1 + PACKET_ROWS) <= line_count_latched)
                                candidate_start <= candidate_start + 1'b1;
                            else begin
                                decode_error <= 1'b1;
                                state        <= ST_WAIT_FRAME;
                            end
                        end else if (header_index == HEADER_BITS - 1) begin
                            packet_start  <= candidate_start;
                            payload_index <= '0;
                            payload_shift <= '0;
                            sync_seen     <= 1'b1;
                            state         <= ST_PAYLOAD;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end

                    ST_PAYLOAD: begin
                        if (!decoded_valid) begin
                            decode_error <= 1'b1;
                            state        <= ST_WAIT_FRAME;
                        end else begin
                            payload_shift <= {payload_shift[PW_BITS-2:0], decoded_bit};
                            if (payload_index == PW_BITS - 1) begin
                                crc_index <= '0;
                                crc_shift <= '0;
                                state     <= ST_CRC;
                            end else begin
                                payload_index <= payload_index + 1'b1;
                            end
                        end
                    end

                    ST_CRC: begin
                        if (!decoded_valid) begin
                            decode_error <= 1'b1;
                            state        <= ST_WAIT_FRAME;
                        end else begin
                            crc_shift <= {crc_shift[6:0], decoded_bit};
                            if (crc_index == CRC_BITS - 1)
                                state <= ST_CHECK;
                            else
                                crc_index <= crc_index + 1'b1;
                        end
                    end

                    ST_CHECK: begin
                        if (crc_shift == password_crc(payload_shift)) begin
                            rx_password           <= payload_shift;
                            password_valid_toggle <= ~password_valid_toggle;
                            crc_ok                <= 1'b1;
                            decode_error          <= 1'b0;
                        end else begin
                            crc_ok       <= 1'b0;
                            decode_error <= 1'b1;
                        end
                        state <= ST_WAIT_FRAME;
                    end

                    default: state <= ST_WAIT_FRAME;
                endcase
            end
        end
    end

endmodule
