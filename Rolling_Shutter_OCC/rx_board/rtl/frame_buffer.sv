`timescale 1ns / 1ps

// Simple dual-port memory: the camera writes in the PCLK domain, the display reads
// in the system-clock domain. One byte per pixel because only brightness matters
// here, which keeps 320x240 at 614 kbit - about a third of the XC7A35T's BRAM.
//
// No reset on the array and a registered read port, so this infers block RAM.
module frame_buffer #(
    parameter int unsigned DEPTH = 76800,
    parameter int unsigned ADDR_WIDTH = 17
) (
    input  logic                   wclk,
    input  logic                   we,
    input  logic [ADDR_WIDTH-1:0]  waddr,
    input  logic [7:0]             wdata,

    input  logic                   rclk,
    input  logic                   ren,
    input  logic [ADDR_WIDTH-1:0]  raddr,
    output logic [7:0]             rdata
);

    (* ram_style = "block" *) logic [7:0] mem [0:DEPTH-1];

    always_ff @(posedge wclk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always_ff @(posedge rclk) begin
        if (ren)
            rdata <= mem[raddr];
    end

endmodule
