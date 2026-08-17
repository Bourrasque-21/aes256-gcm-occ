module authenticated_packet_buffer #(
    parameter int unsigned PAYLOAD_BLOCKS = 80
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         packet_start_valid,
    output logic         packet_start_ready,
    input  logic [31:0]  packet_session_id,
    input  logic [31:0]  packet_frame,
    input  logic [31:0]  packet_counter,
    input  logic [3:0]   packet_flags,

    input  logic [127:0] plaintext_data,
    input  logic         plaintext_valid,
    output logic         plaintext_ready,

    input  logic         auth_valid,
    input  logic         auth_ok,
    output logic         auth_ready,

    output logic [127:0] packet_data,
    output logic         packet_valid,
    input  logic         packet_ready,
    output logic         packet_last,
    output logic [31:0]  output_session_id,
    output logic [31:0]  output_frame,
    output logic [31:0]  output_packet_counter,
    output logic [3:0]   output_flags,

    input  logic         abort,
    output logic         packet_complete,
    output logic         busy
);
    localparam int unsigned MEMORY_ADDR_WIDTH =
        (PAYLOAD_BLOCKS <= 1) ? 1 : $clog2(PAYLOAD_BLOCKS);

    typedef enum logic [2:0] {
        B_IDLE,
        B_WRITE,
        B_WAIT_AUTH,
        B_READ_PREP,
        B_READ
    } buffer_state_t;

    buffer_state_t state;

    // The read state is unreachable until the complete packet passes
    // authentication, so no untrusted plaintext is exposed downstream.
    (* ram_style = "block" *)
    logic [127:0] packet_memory [0:PAYLOAD_BLOCKS-1];

    logic [31:0] session_id_reg;
    logic [31:0] frame_reg;
    logic [31:0] packet_counter_reg;
    logic [3:0]  flags_reg;
    logic [31:0] write_count;
    logic [31:0] read_count;

    logic [127:0] memory_read_data;
    logic [MEMORY_ADDR_WIDTH-1:0] memory_read_addr;
    logic [MEMORY_ADDR_WIDTH-1:0] memory_write_addr;
    logic memory_write_enable;

    assign packet_start_ready = (state == B_IDLE);
    assign plaintext_ready    = (state == B_WRITE);
    assign auth_ready         = (state == B_WAIT_AUTH);

    assign packet_data  = memory_read_data;
    assign packet_valid = (state == B_READ);
    assign packet_last  = (read_count == (PAYLOAD_BLOCKS - 1));

    assign output_session_id     = session_id_reg;
    assign output_frame          = frame_reg;
    assign output_packet_counter = packet_counter_reg;
    assign output_flags          = flags_reg;
    assign busy                  = (state != B_IDLE);

    assign memory_write_enable =
        (state == B_WRITE) && plaintext_valid && plaintext_ready;
    assign memory_write_addr = write_count[MEMORY_ADDR_WIDTH-1:0];

    always_comb begin
        memory_read_addr = read_count[MEMORY_ADDR_WIDTH-1:0];
        if (state == B_READ_PREP) begin
            memory_read_addr = '0;
        end else if ((state == B_READ) && packet_valid && packet_ready &&
                     !packet_last) begin
            memory_read_addr =
                read_count[MEMORY_ADDR_WIDTH-1:0] + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (memory_write_enable)
            packet_memory[memory_write_addr] <= plaintext_data;
        memory_read_data <= packet_memory[memory_read_addr];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= B_IDLE;
            session_id_reg     <= 32'h0;
            frame_reg          <= 32'h0;
            packet_counter_reg <= 32'h0;
            flags_reg          <= 4'h0;
            write_count        <= 32'd0;
            read_count         <= 32'd0;
            packet_complete    <= 1'b0;
        end else begin
            packet_complete <= 1'b0;

            if (abort) begin
                state       <= B_IDLE;
                write_count <= 32'd0;
                read_count  <= 32'd0;
            end else begin
                unique case (state)
                    B_IDLE: begin
                        write_count <= 32'd0;
                        read_count  <= 32'd0;
                        if (packet_start_valid && packet_start_ready) begin
                            session_id_reg     <= packet_session_id;
                            frame_reg          <= packet_frame;
                            packet_counter_reg <= packet_counter;
                            flags_reg          <= packet_flags;
                            state              <= B_WRITE;
                        end
                    end

                    B_WRITE: begin
                        if (plaintext_valid && plaintext_ready) begin
                            if (write_count == (PAYLOAD_BLOCKS - 1)) begin
                                write_count <= 32'd0;
                                state       <= B_WAIT_AUTH;
                            end else begin
                                write_count <= write_count + 32'd1;
                            end
                        end
                    end

                    B_WAIT_AUTH: begin
                        if (auth_valid && auth_ready) begin
                            if (auth_ok) begin
                                read_count <= 32'd0;
                                state      <= B_READ_PREP;
                            end else begin
                                state <= B_IDLE;
                            end
                        end
                    end

                    B_READ_PREP: state <= B_READ;

                    B_READ: begin
                        if (packet_valid && packet_ready) begin
                            if (packet_last) begin
                                packet_complete <= 1'b1;
                                read_count      <= 32'd0;
                                state           <= B_IDLE;
                            end else begin
                                read_count <= read_count + 32'd1;
                            end
                        end
                    end

                    default: state <= B_IDLE;
                endcase
            end
        end
    end

    initial begin
        if (PAYLOAD_BLOCKS == 0)
            $error("authenticated_packet_buffer PAYLOAD_BLOCKS must be > 0");
    end
endmodule
