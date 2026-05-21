# build_papilioarcade.tcl — Gowin build script for nestang on Papilio Retrocade
#
# Target: GW2A-LV18PG256C8/I7 (GW2A-18C, Tang Primer 20K core)
# IO System: FPGA Companion (ESP32-S3) SPI via m0s[5:0] bus
# SDRAM: IS42S16160J-7, 16-bit, 32MB (same geometry as Tang SDRAM v1.2 pmod)
#
# Usage:
#   gw_sh build_papilioarcade.tcl
#
# Output: impl/pnr/nestang_papilioarcade.fs

# Change to the directory containing this script so relative paths work correctly
cd [file dirname [file normalize [info script]]]

set_device GW2A-LV18PG256C8/I7 -device_version C

# Board config: defines PAPILIO_ARCADE, MCU_BL616, RES_720P, PLL_R, LED2, configPackage
add_file src/boards/papilioarcade.v
add_file -type cst "src/boards/papilioarcade.cst"
add_file -type sdc "src/boards/nano20k.sdc"

# PLL files for GW2A-18C (rPLL, same parameters as nano20k but DEVICE=GW2A-18C)
add_file -type verilog "src/pllr_papilio/gowin_pll_hdmi.v"
add_file -type verilog "src/pllr_papilio/gowin_pll_nes.v"

# FPGA Companion IO system (SPI-based, replaces iosys_bl616)
add_file -type verilog "src/iosys/iosys_retrocade.v"

# FPGA Companion support modules (copied from snestang/src/misc/)
add_file -type verilog "src/misc/mcu_spi.v"
add_file -type verilog "src/misc/hid.v"
add_file -type verilog "src/misc/sysctrl.v"
add_file -type verilog "src/misc/sd_card.v"
add_file -type verilog "src/misc/sdcmd_ctrl.v"
add_file -type verilog "src/gowin_dpb/sector_dpram.v"
add_file -type verilog "src/misc/sd_rw.v"

# NES core sources (same as other boards)
add_file -type verilog "src/apu.v"
add_file -type verilog "src/autofire.v"
add_file -type verilog "src/cart.sv"
add_file -type verilog "src/compat.v"
add_file -type verilog "src/controller_snes.v"
add_file -type verilog "src/controller_ds2.sv"
add_file -type verilog "src/dpram.v"
add_file -type verilog "src/dualshock_controller.v"
add_file -type verilog "src/EEPROM_24C0x.sv"
add_file -type verilog "src/game_loader.v"
add_file -type verilog "src/hdmi2/audio_clock_regeneration_packet.sv"
add_file -type verilog "src/hdmi2/audio_info_frame.sv"
add_file -type verilog "src/hdmi2/audio_sample_packet.sv"
add_file -type verilog "src/hdmi2/auxiliary_video_information_info_frame.sv"
add_file -type verilog "src/hdmi2/hdmi.sv"
add_file -type verilog "src/hdmi2/packet_assembler.sv"
add_file -type verilog "src/hdmi2/packet_picker.sv"
add_file -type verilog "src/hdmi2/serializer.sv"
add_file -type verilog "src/hdmi2/source_product_description_info_frame.sv"
add_file -type verilog "src/hdmi2/tmds_channel.sv"
add_file -type verilog "src/mappers/generic.sv"
add_file -type verilog "src/mappers/iir_filter.v"
add_file -type verilog "src/mappers/JYCompany.sv"
add_file -type verilog "src/mappers/misc.sv"
add_file -type verilog "src/mappers/MMC1.sv"
add_file -type verilog "src/mappers/MMC2.sv"
add_file -type verilog "src/mappers/MMC3.sv"
add_file -type verilog "src/mappers/MMC5.sv"
add_file -type verilog "src/mappers/Namco.sv"
add_file -type verilog "src/mappers/Sachen.sv"
add_file -type verilog "src/mappers/Sunsoft.sv"
add_file -type verilog "src/nes.v"
add_file -type verilog "src/nes2hdmi.sv"
add_file -type verilog "src/nestang_top.sv"
add_file -type verilog "src/ppu.v"
add_file -type verilog "src/sdram_nes.v"
add_file -type verilog "src/t65/T65.v"
add_file -type verilog "src/t65/T65_ALU.v"
add_file -type verilog "src/t65/T65_MCode.v"
add_file -type verilog "src/t65/T65_Pack.v"
add_file -type verilog "src/uart_tx_V2.v"

set_option -synthesis_tool gowinsynthesis
set_option -top_module nestang_top
set_option -verilog_std sysv2017
set_option -rw_check_on_ram 1
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -multi_boot 1
set_option -place_option 2
set_option -output_base_name nestang_papilioarcade

run all
