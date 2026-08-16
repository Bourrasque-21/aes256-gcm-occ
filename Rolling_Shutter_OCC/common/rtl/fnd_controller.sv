`timescale 1ns / 1ps

// Pure multiplexer now. Callers hand over four already-decoded segment patterns so
// hex readouts and scrolling text can share one display without a mode flag here.
// segments[31:24] drives the leftmost digit, segments[7:0] the rightmost.
module fnd_controller (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] segments,
    output logic [3:0]  fnd_digit,
    output logic [7:0]  fnd_data
);

    logic [16:0] refresh_count;
    logic [1:0] digit_select;

    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            refresh_count <= '0;
        else
            refresh_count <= refresh_count + 1'b1;
    end

    assign digit_select = refresh_count[16:15];

    always_comb begin
        case (digit_select)
            2'd0: begin fnd_digit = 4'b1110; fnd_data = segments[7:0];   end
            2'd1: begin fnd_digit = 4'b1101; fnd_data = segments[15:8];  end
            2'd2: begin fnd_digit = 4'b1011; fnd_data = segments[23:16]; end
            default: begin fnd_digit = 4'b0111; fnd_data = segments[31:24]; end
        endcase
    end

endmodule
