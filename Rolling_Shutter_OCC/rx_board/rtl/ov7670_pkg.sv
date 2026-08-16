package ov7670_pkg;

    localparam int unsigned OV7670_REG_COUNT = 69;

    // Table positions ov7670_init overrides from the board switches, so gain and
    // exposure can be swept with BTNU instead of a resynthesis.
    localparam int unsigned IDX_COM8 = 3;
    localparam int unsigned IDX_GAIN = 26;
    localparam int unsigned IDX_AECH = 27;
    localparam int unsigned IDX_COM1 = 29;

    // COM8 bit5 is the anti-flicker banding filter - the feature that exists to erase
    // exactly the banding this design transmits with. AEC/AGC/AWB stay off either way.
    function automatic logic [7:0] com8_value(input logic banding_off);
        com8_value = banding_off ? 8'hC0 : 8'hE0;
    endfunction

    function automatic logic [7:0] gain_value(input logic [1:0] sel);
        case (sel)
            2'b00:   gain_value = 8'h00; // minimum
            2'b01:   gain_value = 8'h40;
            2'b10:   gain_value = 8'h80;
            default: gain_value = 8'hFF; // maximum
        endcase
    endfunction

    // AEC is measured in row times and spans AECHH:AECH:COM1 as AEC[15:10]:AEC[9:2]:AEC[1:0].
    // Keep it well below ROWS_PER_BIT - an exposure window wider than one bit period
    // averages neighbouring bits together and erases the banding entirely.
    function automatic logic [7:0] aech_value(input logic [1:0] sel);
        case (sel)
            2'b00:   aech_value = 8'h00; // AEC = 1 row
            2'b01:   aech_value = 8'h00; // AEC = 2 rows
            2'b10:   aech_value = 8'h01; // AEC = 4 rows
            default: aech_value = 8'h02; // AEC = 8 rows
        endcase
    endfunction

    function automatic logic [7:0] com1_value(input logic [1:0] sel);
        case (sel)
            2'b00:   com1_value = 8'h01;
            2'b01:   com1_value = 8'h02;
            default: com1_value = 8'h00;
        endcase
    endfunction

    // {register address, register data}
    // Tracks the known-good table in vga_uart_project/ov7670_pkg.sv, with three
    // deliberate departures for rolling-shutter OCC:
    //   AECH  = 0x02  short manual exposure, so a bit period is not smeared across rows
    //   AECHH = 0x00  and COM1 = 0x00, pinning the exposure MSBs/LSBs the reference leaves alone
    //   COM15 = 0xD0  RGB565 at full 0x00-0xFF output range instead of 0x10-0xF0, for contrast
    function automatic logic [15:0] ov7670_reg(input logic [6:0] index);
        case (index)
            7'd0:  ov7670_reg = 16'h1280; // COM7: software reset

            // Default settings
            7'd1:  ov7670_reg = 16'h3A04; // TSLB
            7'd2:  ov7670_reg = 16'h1200; // COM7: VGA/YUV base
            7'd3:  ov7670_reg = 16'h13E0; // COM8: AEC/AGC/AWB disabled
            7'd4:  ov7670_reg = 16'h6F9F; // AWBCTR0
            7'd5:  ov7670_reg = 16'hB084;
            7'd6:  ov7670_reg = 16'h703A;
            7'd7:  ov7670_reg = 16'h7135;
            7'd8:  ov7670_reg = 16'h7211;
            7'd9:  ov7670_reg = 16'h73F0;
            7'd10: ov7670_reg = 16'h7A20;
            7'd11: ov7670_reg = 16'h7B10;
            7'd12: ov7670_reg = 16'h7C1E;
            7'd13: ov7670_reg = 16'h7D35;
            7'd14: ov7670_reg = 16'h7E5A;
            7'd15: ov7670_reg = 16'h7F69;
            7'd16: ov7670_reg = 16'h8076;
            7'd17: ov7670_reg = 16'h8180;
            7'd18: ov7670_reg = 16'h8288;
            7'd19: ov7670_reg = 16'h838F;
            7'd20: ov7670_reg = 16'h8496;
            7'd21: ov7670_reg = 16'h85A3;
            7'd22: ov7670_reg = 16'h86AF;
            7'd23: ov7670_reg = 16'h87C4;
            7'd24: ov7670_reg = 16'h88D7;
            7'd25: ov7670_reg = 16'h89E8;
            7'd26: ov7670_reg = 16'h0000; // GAIN
            7'd27: ov7670_reg = 16'h1002; // AECH: short manual exposure
            7'd28: ov7670_reg = 16'h0700; // AECHH
            7'd29: ov7670_reg = 16'h0400; // COM1: exposure LSBs
            7'd30: ov7670_reg = 16'h0D40; // COM4
            7'd31: ov7670_reg = 16'h1418; // COM9
            7'd32: ov7670_reg = 16'hA505; // BD50MAX
            7'd33: ov7670_reg = 16'hAB07; // BD60MAX
            7'd34: ov7670_reg = 16'h2495; // AEW
            7'd35: ov7670_reg = 16'h2533; // AEB
            7'd36: ov7670_reg = 16'h26E3; // VPT
            7'd37: ov7670_reg = 16'h9F78; // HAECC1
            7'd38: ov7670_reg = 16'hA068; // HAECC2
            7'd39: ov7670_reg = 16'hA103;
            7'd40: ov7670_reg = 16'hA6D8; // HAECC3
            7'd41: ov7670_reg = 16'hA7D8; // HAECC4
            7'd42: ov7670_reg = 16'hA8F0; // HAECC5
            7'd43: ov7670_reg = 16'hA990; // HAECC6
            7'd44: ov7670_reg = 16'hAA94; // HAECC7

            // QVGA resolution
            7'd45: ov7670_reg = 16'h1211; // COM7: QVGA select
            7'd46: ov7670_reg = 16'h0C04; // COM3
            7'd47: ov7670_reg = 16'h3E19; // COM14
            7'd48: ov7670_reg = 16'h703A; // SCALING_XSC
            7'd49: ov7670_reg = 16'h7135; // SCALING_YSC
            7'd50: ov7670_reg = 16'h7211; // SCALING_DCWCTR
            7'd51: ov7670_reg = 16'h73F1; // SCALING_PCLK_DIV: PCLK = XCLK / 2
            7'd52: ov7670_reg = 16'hA202; // SCALING_PCLK_DELAY

            // QVGA frame window. Without these the sensor keeps its VGA reset window
            // and HREF/VSYNC never line up with a 320x240 readout.
            7'd53: ov7670_reg = 16'h1715; // HSTART
            7'd54: ov7670_reg = 16'h1803; // HSTOP
            7'd55: ov7670_reg = 16'h3200; // HREF
            7'd56: ov7670_reg = 16'h1903; // VSTART
            7'd57: ov7670_reg = 16'h1A7B; // VSTOP
            7'd58: ov7670_reg = 16'h0300; // VREF

            // Colour format
            7'd59: ov7670_reg = 16'h1214; // COM7: QVGA + RGB
            7'd60: ov7670_reg = 16'h40D0; // COM15: RGB565, full 0x00-0xFF range

            7'd61: ov7670_reg = 16'h5587; // BRIGHT

            // Colour matrix
            7'd62: ov7670_reg = 16'h4FB3; // MTX1
            7'd63: ov7670_reg = 16'h50B3; // MTX2
            7'd64: ov7670_reg = 16'h5100; // MTX3
            7'd65: ov7670_reg = 16'h523D; // MTX4
            7'd66: ov7670_reg = 16'h53B0; // MTX5
            7'd67: ov7670_reg = 16'h54E4; // MTX6
            7'd68: ov7670_reg = 16'h589E; // MTX_SIGN

            default: ov7670_reg = 16'h1280;
        endcase
    endfunction

endpackage
