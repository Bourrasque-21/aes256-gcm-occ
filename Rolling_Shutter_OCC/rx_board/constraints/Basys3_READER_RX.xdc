## Reader board - Basys3. Camera, VGA and FND pins are unchanged from the
## single-board OCC design; UART TX is added on A18.

## 100 MHz system clock
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

## Buttons
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports reset]
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports start_btn]

## SW3:SW0 select the credential this reader will accept.
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[0]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[1]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[2]}]
set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[3]}]

## SW5:SW4 exposure, SW7:SW6 gain. Press BTNU after changing either.
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {sw_exposure[0]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {sw_exposure[1]}]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {sw_gain[0]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sw_gain[1]}]

## SW9:SW8 FND source: 00 credential, 01 contrast, 10 peak, 11 tag half-bit target
set_property -dict { PACKAGE_PIN V2 IOSTANDARD LVCMOS33 } [get_ports {sw_fnd_mode[0]}]
set_property -dict { PACKAGE_PIN T3 IOSTANDARD LVCMOS33 } [get_ports {sw_fnd_mode[1]}]

## SW14 modulation, SW15 clears the sensor's anti-flicker banding filter
set_property -dict { PACKAGE_PIN T1 IOSTANDARD LVCMOS33 } [get_ports sw_manchester]
set_property -dict { PACKAGE_PIN R2 IOSTANDARD LVCMOS33 } [get_ports sw_banding_off]

## OV7670 camera. Pmod JB. sda is open-drain in sccb_master, so its pull-up is what
## holds the bus high; scl is push-pull and carries one only to mirror the reference
## constraints. Keep the module's external pull-ups fitted either way.
set_property -dict { PACKAGE_PIN A14 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports scl]   ;# JB1
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 }             [get_ports vsync] ;# JB2
set_property -dict { PACKAGE_PIN A15 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports sda]   ;# JB7
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 }             [get_ports href]  ;# JB8
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 }             [get_ports xclk]  ;# JB9
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 }             [get_ports pclk]  ;# JB10

## Pmod JC: OV7670 D[7:0]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports {pdata[7]}]
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {pdata[5]}]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports {pdata[3]}]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports {pdata[1]}]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports {pdata[6]}]
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports {pdata[4]}]
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports {pdata[2]}]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports {pdata[0]}]

## XCLK is 100 MHz / 4 = 25 MHz. COM14 = 0x19 and SCALING_PCLK_DIV = 0xF1 halve it
## for QVGA, so PCLK should arrive at 12.5 MHz (80 ns). 40 ns deliberately
## over-constrains it by 2x: analysis stays pessimistic and the design still signs
## off if the divider is ever changed.
create_clock -name cam_pclk -period 40.000 -waveform {0.000 20.000} [get_ports pclk]
create_generated_clock -name cam_xclk -source [get_ports clk] -divide_by 4 [get_ports xclk]
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk cam_xclk}] \
    -group [get_clocks cam_pclk]

## Source-synchronous DVP bus. The OV7670 drives HREF/VSYNC/D[7:0] from the PCLK
## falling edge, so the design samples them on the rising edge. These numbers cover
## the sensor's output delay plus the Pmod ribbon; tighten once measured.
set_input_delay -clock cam_pclk -max 15.000 [get_ports {pdata[*] href vsync}]
set_input_delay -clock cam_pclk -min  5.000 [get_ports {pdata[*] href vsync}]

## USB-UART bridge, TX only
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports uart_tx_pin]

## Status LEDs LD0..LD8
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {status_led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {status_led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {status_led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {status_led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {status_led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {status_led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {status_led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {status_led[7]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {status_led[8]}]

## Four-digit seven-segment display
set_property -dict { PACKAGE_PIN W7 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[0]}]
set_property -dict { PACKAGE_PIN W6 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[1]}]
set_property -dict { PACKAGE_PIN U8 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[2]}]
set_property -dict { PACKAGE_PIN V8 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[3]}]
set_property -dict { PACKAGE_PIN U5 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[4]}]
set_property -dict { PACKAGE_PIN V5 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[5]}]
set_property -dict { PACKAGE_PIN U7 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[6]}]
set_property -dict { PACKAGE_PIN V7 IOSTANDARD LVCMOS33 } [get_ports {fnd_data[7]}]

set_property -dict { PACKAGE_PIN U2 IOSTANDARD LVCMOS33 } [get_ports {fnd_digit[0]}]
set_property -dict { PACKAGE_PIN U4 IOSTANDARD LVCMOS33 } [get_ports {fnd_digit[1]}]
set_property -dict { PACKAGE_PIN V4 IOSTANDARD LVCMOS33 } [get_ports {fnd_digit[2]}]
set_property -dict { PACKAGE_PIN W4 IOSTANDARD LVCMOS33 } [get_ports {fnd_digit[3]}]

## VGA connector. The stored 320x240 frame is doubled to 640x480 so the banding, and
## whether the tag is aimed inside the ROI, can be checked by eye.
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports {port_red[0]}]
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS33 } [get_ports {port_red[1]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 } [get_ports {port_red[2]}]
set_property -dict { PACKAGE_PIN N19 IOSTANDARD LVCMOS33 } [get_ports {port_red[3]}]
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports {port_green[0]}]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {port_green[1]}]
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports {port_green[2]}]
set_property -dict { PACKAGE_PIN D17 IOSTANDARD LVCMOS33 } [get_ports {port_green[3]}]
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports {port_blue[0]}]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports {port_blue[1]}]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports {port_blue[2]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports {port_blue[3]}]
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 } [get_ports h_sync]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports v_sync]

## A monitor recovers its own sampling phase from HSYNC, and the UART bridge samples
## on its own baud clock, so neither carries a meaningful requirement against sys_clk.
set_false_path -to [get_ports {port_red[*] port_green[*] port_blue[*] \
                               h_sync v_sync uart_tx_pin}]

## Board controls enter explicit two-flop synchronizers.
set_false_path -from [get_ports {start_btn sw_slot[*] sw_exposure[*] sw_gain[*] \
                                 sw_fnd_mode[*] sw_manchester sw_banding_off}]

## reset drives asynchronous reset pins straight from the pin, so its release is
## unsynchronised and recovery/removal cannot be met. The real fix is a reset
## synchroniser per domain in RTL.
set_false_path -from [get_ports reset]

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
