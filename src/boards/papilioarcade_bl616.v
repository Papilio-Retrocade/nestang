// papilioarcade_bl616.v — Papilio Retrocade board config for nestang + BL616 UART iosys
// GW2A-LV18PG256C8/I7 (GW2A-18C), 27MHz crystal, 16-bit SDRAM (IS42S16160J-7)
//
// This variant uses iosys_bl616 (UART) instead of iosys_retrocade (SPI).
// The ESP32-S3 TX/RX lines connect to FPGA E14 (uart_rx) and C9 (uart_tx).
//
// SDRAM: IS42S16160J-7 on-board — same geometry as Tang SDRAM v1.2 pmod
// IO: ESP32-S3 over UART at 2 Mbps via GPIO43(TX)→E14, GPIO44(RX)←C9
//   No SPI m0s bus, no CONTROLLER_SNES/DS2 — joysticks via UART HID channel

`define RES_720P
`define GW_IDE
`define PLL_R               // GW2A-18C uses rPLL (same family as GW2AR on nano20k)
// `define LED2                // Tang Primer 20K module has 2 LEDs (DONE/READY)
// NOTE: PAPILIO_ARCADE is intentionally NOT defined here.
// nestang_top.sv uses `ifdef PAPILIO_ARCADE for iosys selection:
//   - defined   → iosys_retrocade (SPI, m0s bus)
//   - undefined → iosys_bl616    (UART, E14/C9)
`define MCU_BL616           // Disconnects RV softcore rv_* ports from SDRAM

package configPackage;
    // W9825G6KH-6: 16-bit × 8K rows × 512 cols × 4 banks = 32MB
    localparam SDRAM_DATA_WIDTH = 16;
    localparam SDRAM_ROW_WIDTH  = 13;
    localparam SDRAM_COL_WIDTH  = 9;
    localparam SDRAM_BANK_WIDTH = 2;
endpackage
