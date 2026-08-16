`timescale 1ns / 1ps

import ov7670_pkg::*;

module ov7670_init #(
    parameter int unsigned CLK_HZ = 100_000_000
) (
    input  logic clk,
    input  logic reset,
    input  logic restart,
    input  logic [1:0] gain_sel,
    input  logic [1:0] exposure_sel,
    input  logic       banding_off,
    output logic init_done,
    output logic ack_error,
    output logic scl,
    inout  wire  sda
);

    localparam int unsigned POWERUP_DELAY_CYCLES = CLK_HZ / 10;    // 100 ms
    localparam int unsigned RESET_DELAY_CYCLES   = CLK_HZ / 20;    // 50 ms
    localparam int unsigned REG_DELAY_CYCLES     = CLK_HZ / 10_000; // 100 us

    typedef enum logic [2:0] {
        ST_POWER_WAIT,
        ST_LAUNCH,
        ST_WAIT_TRANSACTION,
        ST_REGISTER_DELAY,
        ST_DONE
    } state_t;

    state_t state;
    logic [31:0] delay_count;
    logic [6:0]  reg_index;
    logic [15:0] reg_pair;
    logic        master_start;
    logic        master_busy;
    logic        master_done;
    logic        master_ack_error;

    always_comb begin
        reg_pair = ov7670_reg(reg_index);

        if (reg_index == IDX_COM8[6:0])
            reg_pair[7:0] = com8_value(banding_off);
        else if (reg_index == IDX_GAIN[6:0])
            reg_pair[7:0] = gain_value(gain_sel);
        else if (reg_index == IDX_AECH[6:0])
            reg_pair[7:0] = aech_value(exposure_sel);
        else if (reg_index == IDX_COM1[6:0])
            reg_pair[7:0] = com1_value(exposure_sel);
    end

    sccb_master #(
        .CLK_HZ(CLK_HZ),
        .SCCB_HZ(100_000)
    ) u_sccb_master (
        .clk      (clk),
        .reset    (reset),
        .start    (master_start),
        .reg_addr (reg_pair[15:8]),
        .reg_data (reg_pair[7:0]),
        .busy     (master_busy),
        .done     (master_done),
        .ack_error(master_ack_error),
        .scl      (scl),
        .sda      (sda)
    );

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= ST_POWER_WAIT;
            delay_count  <= '0;
            reg_index    <= '0;
            master_start <= 1'b0;
            init_done    <= 1'b0;
            ack_error    <= 1'b0;
        end else begin
            master_start <= 1'b0;

            case (state)
                ST_POWER_WAIT: begin
                    init_done <= 1'b0;
                    if (delay_count == POWERUP_DELAY_CYCLES - 1) begin
                        delay_count <= '0;
                        reg_index   <= '0;
                        ack_error   <= 1'b0;
                        state       <= ST_LAUNCH;
                    end else begin
                        delay_count <= delay_count + 1'b1;
                    end
                end

                ST_LAUNCH: begin
                    if (!master_busy) begin
                        master_start <= 1'b1;
                        state        <= ST_WAIT_TRANSACTION;
                    end
                end

                ST_WAIT_TRANSACTION: begin
                    if (master_done) begin
                        ack_error   <= ack_error | master_ack_error;
                        delay_count <= '0;
                        state       <= ST_REGISTER_DELAY;
                    end
                end

                ST_REGISTER_DELAY: begin
                    if ((reg_index == 0 && delay_count == RESET_DELAY_CYCLES - 1) ||
                        (reg_index != 0 && delay_count == REG_DELAY_CYCLES - 1)) begin
                        delay_count <= '0;
                        if (reg_index == OV7670_REG_COUNT - 1) begin
                            init_done <= 1'b1;
                            state     <= ST_DONE;
                        end else begin
                            reg_index <= reg_index + 1'b1;
                            state     <= ST_LAUNCH;
                        end
                    end else begin
                        delay_count <= delay_count + 1'b1;
                    end
                end

                ST_DONE: begin
                    init_done <= 1'b1;
                    if (restart) begin
                        init_done   <= 1'b0;
                        reg_index   <= '0;
                        delay_count <= '0;
                        ack_error   <= 1'b0;
                        state       <= ST_LAUNCH;
                    end
                end

                default: state <= ST_POWER_WAIT;
            endcase
        end
    end

endmodule
