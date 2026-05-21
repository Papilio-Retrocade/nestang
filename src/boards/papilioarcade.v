// papilioarcade.v — Papilio Retrocade board configuration for nestang
// GW2A-LV18PG256C8/I7 (GW2A-18C), 27MHz crystal, 16-bit SDRAM (IS42S16160J-7)
//
// SDRAM: IS42S16160J-7 on-board
//   2 bytes per word × 8192 rows × 512 cols × 4 banks = 32MB
//   Same geometry as Tang SDRAM v1.2 pmod (used on Primer 25K)
//
// IO: FPGA Companion (ESP32-S3) over SPI via m0s[5:0] bus
//   No UART, no USB HID host — all input via FPGA Companion HID SPI channel
//   No CONTROLLER_SNES or CONTROLLER_DS2 — controllers via FPGA Companion

`define RES_720P
`define GW_IDE
`define PLL_R               // GW2A-18C uses rPLL (same family as GW2AR on nano20k)
`define LED2                // Tang Primer 20K module has 2 LEDs (DONE/READY)
`define PAPILIO_ARCADE      // Selects SPI iosys, SD card ports, removes UART from top

// Define MCU_BL616 to reuse its sdram_nes rv_* disconnect logic.
// (There is no RV softcore in PAPILIO_ARCADE mode — ROM loads via game_loader.v
// which gets its byte stream from iosys_retrocade, not from a RV CPU.)
`define MCU_BL616

package configPackage;
    // IS42S16160J-7: 2B × 8K rows × 512 cols × 4 banks = 32MB
    // Identical config to Tang SDRAM v1.2 pmod (primer25k.v)
    localparam SDRAM_DATA_WIDTH = 16;   // 2 bytes per word
    localparam SDRAM_ROW_WIDTH  = 13;   // 8K rows (2^13)
    localparam SDRAM_COL_WIDTH  = 9;    // 512 cols (2^9)
    localparam SDRAM_BANK_WIDTH = 2;    // 4 banks

endpackage
