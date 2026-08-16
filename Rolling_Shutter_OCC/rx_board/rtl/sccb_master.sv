`timescale 1ns / 1ps

module sccb_master #(
    parameter int unsigned CLK_HZ  = 100_000_000,
    parameter int unsigned SCCB_HZ = 100_000,
    parameter logic [6:0] DEVICE_ADDRESS = 7'h21
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       start,
    input  logic [7:0] reg_addr,
    input  logic [7:0] reg_data,
    output logic       busy,
    output logic       done,
    output logic       ack_error,
    output logic       scl,
    inout  wire        sda
);

    localparam int unsigned HALF_PERIOD_CYCLES = CLK_HZ / (SCCB_HZ * 2);
    localparam int unsigned DIV_WIDTH = (HALF_PERIOD_CYCLES <= 1) ? 1 : $clog2(HALF_PERIOD_CYCLES);

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_START_HIGH,
        ST_START_LOW,
        ST_WRITE_HIGH,
        ST_WRITE_LOW,
        ST_ACK_HIGH,
        ST_ACK_LOW,
        ST_STOP_HIGH,
        ST_STOP_RELEASE
    } state_t;

    state_t state;
    logic [DIV_WIDTH-1:0] div_count;
    logic [7:0] reg_addr_latched;
    logic [7:0] reg_data_latched;
    logic [7:0] current_byte;
    logic [2:0] bit_index;
    logic [1:0] byte_index;
    logic       sda_release;

    assign sda = sda_release ? 1'bz : 1'b0;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state             <= ST_IDLE;
            div_count         <= '0;
            reg_addr_latched  <= '0;
            reg_data_latched  <= '0;
            current_byte      <= '0;
            bit_index         <= 3'd7;
            byte_index        <= '0;
            sda_release       <= 1'b1;
            scl               <= 1'b1;
            busy              <= 1'b0;
            done              <= 1'b0;
            ack_error         <= 1'b0;
        end else begin
            done <= 1'b0;

            if (state == ST_IDLE) begin
                scl         <= 1'b1;
                sda_release <= 1'b1;
                div_count   <= '0;
                busy        <= 1'b0;

                if (start) begin
                    reg_addr_latched <= reg_addr;
                    reg_data_latched <= reg_data;
                    current_byte     <= {DEVICE_ADDRESS, 1'b0};
                    bit_index        <= 3'd7;
                    byte_index       <= 2'd0;
                    ack_error        <= 1'b0;
                    busy             <= 1'b1;
                    state            <= ST_START_HIGH;
                end
            end else if (div_count == HALF_PERIOD_CYCLES - 1) begin
                div_count <= '0;

                case (state)
                    ST_START_HIGH: begin
                        scl         <= 1'b1;
                        sda_release <= 1'b0; // START: SDA falls while SCL is high
                        state       <= ST_START_LOW;
                    end

                    ST_START_LOW: begin
                        scl         <= 1'b0;
                        sda_release <= current_byte[7];
                        state       <= ST_WRITE_HIGH;
                    end

                    ST_WRITE_HIGH: begin
                        scl   <= 1'b1;
                        state <= ST_WRITE_LOW;
                    end

                    ST_WRITE_LOW: begin
                        scl <= 1'b0;
                        if (bit_index == 0) begin
                            sda_release <= 1'b1;
                            state       <= ST_ACK_HIGH;
                        end else begin
                            bit_index   <= bit_index - 1'b1;
                            sda_release <= current_byte[bit_index-1'b1];
                            state       <= ST_WRITE_HIGH;
                        end
                    end

                    ST_ACK_HIGH: begin
                        scl       <= 1'b1;
                        ack_error <= ack_error | sda;
                        state     <= ST_ACK_LOW;
                    end

                    ST_ACK_LOW: begin
                        scl <= 1'b0;
                        if (byte_index == 2) begin
                            sda_release <= 1'b0;
                            state       <= ST_STOP_HIGH;
                        end else begin
                            byte_index <= byte_index + 1'b1;
                            bit_index  <= 3'd7;
                            if (byte_index == 0) begin
                                current_byte <= reg_addr_latched;
                                sda_release  <= reg_addr_latched[7];
                            end else begin
                                current_byte <= reg_data_latched;
                                sda_release  <= reg_data_latched[7];
                            end
                            state <= ST_WRITE_HIGH;
                        end
                    end

                    ST_STOP_HIGH: begin
                        scl         <= 1'b1;
                        sda_release <= 1'b0;
                        state       <= ST_STOP_RELEASE;
                    end

                    ST_STOP_RELEASE: begin
                        scl         <= 1'b1;
                        sda_release <= 1'b1;
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule
