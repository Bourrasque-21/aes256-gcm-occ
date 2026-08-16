`timescale 1ns / 1ps

// 8N1 transmitter for the Basys3 USB-UART bridge. Idle line is high.
module uart_tx #(
    parameter int unsigned CLK_HZ    = 100_000_000,
    parameter int unsigned BAUD_RATE = 115_200
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       send,
    input  logic [7:0] data,
    output logic       busy,
    output logic       tx
);

    localparam int unsigned DIVISOR = CLK_HZ / BAUD_RATE;
    localparam int unsigned DIV_W   = $clog2(DIVISOR);

    logic [DIV_W-1:0] div_count;
    logic [3:0]       bit_index;
    logic [9:0]       shifter;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            div_count <= '0;
            bit_index <= '0;
            shifter   <= 10'h3FF;
            busy      <= 1'b0;
            tx        <= 1'b1;
        end else if (!busy) begin
            tx <= 1'b1;
            if (send) begin
                // Start bit low, then LSB first, then stop bit high.
                shifter   <= {1'b1, data, 1'b0};
                div_count <= '0;
                bit_index <= '0;
                busy      <= 1'b1;
            end
        end else begin
            tx <= shifter[0];
            if (div_count == DIVISOR - 1) begin
                div_count <= '0;
                shifter   <= {1'b1, shifter[9:1]};
                if (bit_index == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule
