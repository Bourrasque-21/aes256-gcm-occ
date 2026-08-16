## Tag board - Basys3. Pin assignments match the single-board OCC design; only the
## meanings attached to the switches differ. No camera is fitted on this board.

## 100 MHz system clock
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

## Buttons
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports reset]
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports btn_show_trim]

## SW3:SW0 select which of the sixteen demo credentials is transmitted.
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[0]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[1]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[2]}]
set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {sw_slot[3]}]

## SW11:SW4 trim the half-bit period. 0x80 is nominal, each step is 8 clocks.
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {sw_trim[0]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {sw_trim[1]}]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {sw_trim[2]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sw_trim[3]}]
set_property -dict { PACKAGE_PIN V2  IOSTANDARD LVCMOS33 } [get_ports {sw_trim[4]}]
set_property -dict { PACKAGE_PIN T3  IOSTANDARD LVCMOS33 } [get_ports {sw_trim[5]}]
set_property -dict { PACKAGE_PIN T2  IOSTANDARD LVCMOS33 } [get_ports {sw_trim[6]}]
set_property -dict { PACKAGE_PIN R3  IOSTANDARD LVCMOS33 } [get_ports {sw_trim[7]}]

## SW14 modulation, SW15 transmit enable
set_property -dict { PACKAGE_PIN T1 IOSTANDARD LVCMOS33 } [get_ports sw_manchester]
set_property -dict { PACKAGE_PIN R2 IOSTANDARD LVCMOS33 } [get_ports sw_tx_enable]

## External LED MOSFET gate: Pmod JA1. 4 kbps needs no edge rate, so SLEW SLOW keeps
## ringing off the ribbon. Fit a 10k gate-to-source pulldown externally - Basys3 I/O
## sit on weak pull-ups during configuration and would otherwise light the LED before
## the bitstream loads. A 100R series resistor protects the pin.
set_property -dict { PACKAGE_PIN J1 IOSTANDARD LVCMOS33 DRIVE 12 SLEW SLOW } [get_ports led_tx]

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

## Board controls enter explicit two-flop synchronizers.
set_false_path -from [get_ports {btn_show_trim sw_slot[*] sw_trim[*] \
                                 sw_manchester sw_tx_enable}]

## reset drives asynchronous reset pins straight from the pin, so its release is
## unsynchronised and recovery/removal cannot be met. The real fix is a reset
## synchroniser per domain in RTL.
set_false_path -from [get_ports reset]

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
