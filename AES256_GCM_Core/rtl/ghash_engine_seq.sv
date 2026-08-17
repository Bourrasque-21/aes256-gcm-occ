module ghash_engine_seq (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [127:0] h,
    input  logic [127:0] data_in,
    input  logic [127:0] y_in,
    output logic [127:0] y_out,
    output logic         busy,
    output logic         done
);
    typedef enum logic [1:0] {
        H_IDLE,
        H_WAIT_MULT,
        H_DONE
    } ghash_state_t;

    ghash_state_t state;

    logic [127:0] mult_x;
    logic [127:0] mult_product;
    logic         mult_start;
    logic         mult_busy;
    logic         mult_done;

    assign mult_x = y_in ^ data_in;
    assign mult_start = (state == H_IDLE) && start;
    // H_DONE still belongs to the active transaction because done is asserted
    // in that state. A new request is accepted only after returning to H_IDLE.
    assign busy = (state != H_IDLE);
    assign done = (state == H_DONE);

    gf128_mult_8bit_seq u_gf128_mult_8bit_seq (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (mult_start),
        .x       (mult_x),
        .y       (h),
        .product (mult_product),
        .busy    (mult_busy),
        .done    (mult_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= H_IDLE;
            y_out <= 128'h0;
        end else begin
            unique case (state)
                H_IDLE: begin
                    if (start) begin
                        state <= H_WAIT_MULT;
                    end
                end

                H_WAIT_MULT: begin
                    if (mult_done) begin
                        y_out <= mult_product;
                        state <= H_DONE;
                    end
                end

                H_DONE: begin
                    state <= H_IDLE;
                end

                default: begin
                    state <= H_IDLE;
                end
            endcase
        end
    end
endmodule
