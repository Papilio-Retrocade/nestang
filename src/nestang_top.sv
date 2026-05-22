//
// NESTang top level
// nand2mario
//

// `timescale 1ns / 100ps

import configPackage::*;

module nestang_top (
    input sys_clk,

    // Button S1 and pin 48 are both resets
    input s1,
    input reset2,

// `ifdef PAPILIO_ARCADE
//     // SPI bus to FPGA Companion MCU
//     inout [5:0] m0s,
//     // Physical SD card
//     output sd_clk,
//     inout  sd_cmd,
//     inout  [3:0] sd_dat,
// `else
    // UART for BL616 UART iosys
    input UART_RXD,
    output UART_TXD,
    // SD card (Tang Primer 20K onboard TF slot) — direct ESP32 SPI pass-through
    output sd_clk,
    output sd_cmd,       // MOSI: ESP32 GPIO11 → SD CMD
    input  sd_miso,      // MISO: SD D0/DAT0  → ESP32 GPIO3
    output sd_cs,        // CS:   ESP32 GPIO10 → SD D3/DAT3
    output sd_dat1,      // tie HIGH (unused in SPI mode)
    output sd_dat2,      // tie HIGH (unused in SPI mode)
    // ESP32 SPI companion pins — wired through FPGA to SD card
    input  pmod_companion_clk,    // ESP32 GPIO12 (SCK)
    input  pmod_companion_din,    // ESP32 GPIO11 (MOSI)
    output pmod_companion_dout,   // ESP32 GPIO3  (MISO)
    input  pmod_companion_ss,     // ESP32 GPIO10 (CS)
// `endif

    // SDRAM - Tang SDRAM pmod 1.2 for primer 25k, on-chip 32-bit 8MB SDRAM for nano 20k
    output O_sdram_clk,
    output O_sdram_cke,
    output O_sdram_cs_n,            // chip select
    output O_sdram_cas_n,           // columns address select
    output O_sdram_ras_n,           // row address select
    output O_sdram_wen_n,           // write enable
    inout [SDRAM_DATA_WIDTH-1:0] IO_sdram_dq,      // bidirectional data bus
    output [SDRAM_ROW_WIDTH-1:0] O_sdram_addr,     // multiplexed address bus
    output [1:0] O_sdram_ba,        // two banks
    output [SDRAM_DATA_WIDTH/8-1:0] O_sdram_dqm,  

// `ifdef LED2
//     // LEDs
//     output [1:0] led,
// `else
//     // LEDs
//     output [7:0] led,
// `endif

// `ifdef CONTROLLER_SNES
//     // snes controllers
//     output joy1_strb,
//     output joy1_clk,
//     input joy1_data,
//     output joy2_strb,
//     output joy2_clk,
//     input joy2_data,
// `endif

// `ifdef CONTROLLER_DS2
//     // dualshock controllers
//     output ds_clk,
//     input ds_miso,
//     output ds_mosi,
//     output ds_cs,
//     output ds_clk2,
//     input ds_miso2,
//     output ds_mosi2,
//     output ds_cs2,
// `endif

// `ifdef USB1
//     // USB1 and USB2
//     inout usb1_dp,
//     inout usb1_dn,
// `endif
// `ifdef USB2
//     inout usb2_dp,
//     inout usb2_dn,
// `endif

    // HDMI TX
    output       tmds_clk_n,
    output       tmds_clk_p,
    output [2:0] tmds_d_n,
    output [2:0] tmds_d_p
);

// Core settings
wire arm_reset = 0;
wire [1:0] system_type = 2'b0;
wire pal_video = 0;
wire [1:0] scanlines = 2'b0;
wire joy_swap = 0;
wire mirroring_osd = 0;
wire overscan_osd = 0;
wire famicon_kbd = 0;
wire [3:0] palette_osd = 0;
wire [2:0] diskside_osd = 0;
wire blend = 0;
wire bk_save = 0;

// NES signals
reg reset_nes = 1;
reg clkref;
wire [5:0] color;
wire [15:0] sample;
wire [8:0] scanline;
wire [8:0] cycle;
wire [2:0] joypad_out;
wire joypad_strobe = joypad_out[0];
wire [1:0] joypad_clock;
wire [4:0] joypad1_data, joypad2_data;

wire sdram_busy;
wire [21:0] memory_addr_cpu, memory_addr_ppu;
wire memory_read_cpu, memory_read_ppu;
wire memory_write_cpu, memory_write_ppu;
wire [7:0] memory_din_cpu, memory_din_ppu;
wire [7:0] memory_dout_cpu, memory_dout_ppu;

reg [7:0] joypad_bits, joypad_bits2;
reg [1:0] last_joypad_clock;
wire [31:0] dbgadr;
wire [1:0] dbgctr;

wire [1:0] nes_ce;

wire loading;                 // from iosys or game_data
wire [7:0] loader_do;
wire loader_do_valid;

// iosys softcore
wire        rv_valid;
reg         rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata;
wire [3:0]  rv_wstrb;
reg  [15:0] rv_dout0;
wire [31:0] rv_rdata = {rv_dout, rv_dout0};
reg         rv_valid_r;
reg         rv_word;           // which word
reg         rv_req;
wire        rv_req_ack;
wire [15:0] rv_dout;
reg [1:0]   rv_ds;
reg         rv_new_req;

// Controller
wire [7:0] joy_rx[0:1], joy_rx2[0:1];     // 6 RX bytes for all button/axis state
wire [7:0] usb_btn, usb_btn2;
wire usb_btn_x, usb_btn_y, usb_btn_x2, usb_btn_y2;
wire usb_conerr, usb_conerr2;
wire auto_a, auto_b, auto_a2, auto_b2;


// OR together when both SNES and DS2 controllers are connected (right now only nano20k supports both simultaneously)
wor [11:0] joy1_btns, joy2_btns;    // SNES layout (R L X A RT LT DN UP START SELECT Y B)
                                    // Lower 8 bits are NES buttons
wire [11:0] joy_usb1, joy_usb2;
wire [11:0] hid1, hid2;             // From BL616
wire [11:0] joy1 = joy1_btns | hid1 | joy_usb1;
wire [11:0] joy2 = joy2_btns | hid2 | joy_usb2;

// NES gamepad
wire [7:0]NES_gamepad_button_state;
wire NES_gamepad_data_available;
wire [7:0]NES_gamepad_button_state2;
wire NES_gamepad_data_available2;

// Loader
wire [21:0] loader_addr;
wire [7:0] loader_write_data;
reg loading_r;
always @(posedge clk) loading_r <= loading;
wire loader_reset = loading & ~loading_r;
wire loader_write;
wire [63:0] loader_flags;
reg  [63:0] mapper_flags;
wire loader_done, loader_fail;
wire loader_busy, loaded;
wire type_nes = 1'b1;  // (menu_index == 0) || (menu_index == {2'd0, 6'h1});
wire type_bios = 1'b0; // (menu_index == 2);
wire is_bios = 0;      //type_bios;
wire type_fds = 1'b0;  // (menu_index == {2'd1, 6'h1});
wire type_nsf = 1'b0;  // (menu_index == {2'd2, 6'h1});

wire int_audio;         // for VCR6
wire ext_audio;

///////////////////////////
// Clocks
///////////////////////////

wire clk;       // 21.477Mhz main clock
wire fclk;      // 3x clk SDRAM clock
wire hclk;      // 720p pixel clock: 74.25 Mhz
wire hclk5;     // 5x pixel clock: 371.25 Mhz
wire clk27;     // 27Mhz to generate hclk/hclk5
wire clk_usb;   // 12Mhz USB clock

reg sys_resetn = 0;
reg [7:0] reset_cnt = 255;      // reset for 255 cycles before start everything
always @(posedge clk) begin
    reset_cnt <= reset_cnt == 0 ? 0 : reset_cnt - 1;
    if (reset_cnt == 0)
        sys_resetn <= 1'b1;    // DEBUG: one-shot timer reset only, no external reset sources
end

`ifndef VERILATOR

`ifdef PLL_R
// Nano uses rPLL and 27Mhz crystal
assign clk27 = sys_clk;       // Nano20K: native 27Mhz system clock
gowin_pll_nes pll_nes(.clkin(sys_clk), .clkoutd3(clk), .clkout(fclk), .clkoutp(O_sdram_clk));
`else
// All other boards uses 50Mhz crystal
gowin_pll_27 pll_27 (.clkin(sys_clk), .clkout0(clk27));      // Primer25K: PLL to generate 27Mhz from 50Mhz
gowin_pll_nes pll_nes (.clkin(sys_clk), .clkout0(clk), .clkout1(fclk), .clkout2(O_sdram_clk));
`endif

gowin_pll_hdmi pll_hdmi (
    .clkin(clk27),
    .clkout(hclk5)
);

CLKDIV #(.DIV_MODE(5)) div5 (
    .CLKOUT(hclk),
    .HCLKIN(hclk5),
    .RESETN(sys_resetn),
    .CALIB(1'b0)
);

`else   // verilator

// dummy clocks for verilator
assign clk = sys_clk;
assign fclk = sys_clk;

`endif  // verilator

wire [31:0] status;


// Main NES machine
// Debug taps from inside NES (CPU bus visibility) -- declared BEFORE instance
wire [15:0] cpu_dbg_addr;
wire        cpu_dbg_mr;
wire        cpu_dbg_mw;
wire        cpu_dbg_ce;
NES nes(
    .clk(clk), .reset_nes(reset_nes), .cold_reset(1'b0),
    .sys_type(system_type), .nes_div(nes_ce),
    .mapper_flags(mapper_flags),
    .sample(sample), .color(color),
    .joypad_out(joypad_out), .joypad_clock(joypad_clock), 
    .joypad1_data(joypad1_data), .joypad2_data(joypad2_data),

    .fds_busy(), .fds_eject(), .diskside_req(), .diskside(),        // disk system
    .audio_channels(5'b11111),  // enable all channels
    
    .cpumem_addr(memory_addr_cpu),
    .cpumem_read(memory_read_cpu),
    .cpumem_din(memory_din_cpu),
    .cpumem_write(memory_write_cpu),
    .cpumem_dout(memory_dout_cpu),
    .ppumem_addr(memory_addr_ppu),
    .ppumem_read(memory_read_ppu),
    .ppumem_write(memory_write_ppu),
    .ppumem_din(memory_din_ppu),
    .ppumem_dout(memory_dout_ppu),

    .bram_addr(), .bram_din(), .bram_dout(), .bram_write(), .bram_override(),

    .cycle(cycle), .scanline(scanline),
    .int_audio(int_audio),    // VRC6
    .ext_audio(ext_audio),

    .apu_ce(), .gg(), .gg_code(), .gg_avail(), .gg_reset(), .emphasis(), .save_written(),
    // Debug taps for CPU-bus instrumentation
    .dbg_addr(cpu_dbg_addr), .dbg_mr(cpu_dbg_mr), .dbg_mw(cpu_dbg_mw), .dbg_cpu_ce(cpu_dbg_ce)
);

// ============================================================================
// Loader -> SDRAM Port B throttle FIFO + FSM   (Papilio Retrocade cart-load fix)
//
// PROBLEM with the previous logic
//     loader_write_mem <= loader_write || loader_write_r;   // width 2
// game_loader.v emits a 1-clk loader_write pulse for every cart byte. When the
// SD-card delivers a burst, those pulses arrive back-to-back and the 2-clk
// widener merges them into a CONTINUOUSLY-HIGH signal. sdram_nes.v's Port B
// detects writes by *rising edge* on weB:
//     wire reqB = (~oeB_d & oeB) || (~weB_d & weB);
// A continuously-high weB therefore produces only ONE write — every byte after
// the first in a burst is silently dropped, leaving the cart partially loaded
// in SDRAM and the 6502 reading garbage on boot (black screen).
//
// FIX: enforce a guaranteed weB low-gap between every byte. The FSM holds weB
// high for 2 clk (>= 1 SDRAM cycle so cycle[0] samples the rising edge), then
// pulls it low for 1 clk (>= 1 SDRAM cycle so weB_d clears) — 3 clk/byte
// total (~7.2 MB/s @ clk=21.6 MHz). A small FIFO absorbs the SD burst that
// arrives slightly faster than the FSM can drain.
// ============================================================================
reg [21:0] loader_addr_mem;
reg [7:0]  loader_write_data_mem;
reg        loader_write_mem;

localparam LDR_FIFO_AW = 3;                       // 8 entries
reg [21:0] ldr_fifo_addr [0:(1<<LDR_FIFO_AW)-1];
reg [7:0]  ldr_fifo_data [0:(1<<LDR_FIFO_AW)-1];
reg [LDR_FIFO_AW-1:0] ldr_wptr, ldr_rptr;
wire ldr_fifo_empty = (ldr_wptr == ldr_rptr);
wire ldr_fifo_full  = ((ldr_wptr + {{(LDR_FIFO_AW-1){1'b0}},1'b1}) == ldr_rptr);

reg [1:0] ldr_phase;
reg       ldr_overflow;                           // sticky: latched on FIFO overflow

always @(posedge clk) begin
    if (~sys_resetn | loader_reset) begin
        ldr_wptr         <= 0;
        ldr_rptr         <= 0;
        loader_write_mem <= 1'b0;
        ldr_phase        <= 2'd0;
        ldr_overflow     <= 1'b0;
    end else begin
        // ----- Enqueue every loader_write pulse from game_loader -----
        if (loader_write) begin
            if (!ldr_fifo_full) begin
                ldr_fifo_addr[ldr_wptr] <= loader_addr;
                ldr_fifo_data[ldr_wptr] <= loader_write_data;
                ldr_wptr <= ldr_wptr + 1'b1;
            end else begin
                ldr_overflow <= 1'b1;             // FIFO too small for SD burst
            end
        end

        // ----- Drain: one byte per 3 clk with mandatory low-gap -----
        case (ldr_phase)
        2'd0: begin
            loader_write_mem <= 1'b0;
            if (!ldr_fifo_empty) begin
                loader_addr_mem       <= ldr_fifo_addr[ldr_rptr];
                loader_write_data_mem <= ldr_fifo_data[ldr_rptr];
                loader_write_mem      <= 1'b1;    // rising edge on weB
                ldr_phase             <= 2'd1;
            end
        end
        2'd1: begin
            loader_write_mem <= 1'b1;             // hold high across SDRAM cycle[0]
            ldr_phase        <= 2'd2;
        end
        2'd2: begin
            loader_write_mem <= 1'b0;             // mandatory low-gap (weB_d clears)
            ldr_rptr         <= ldr_rptr + 1'b1;
            ldr_phase        <= 2'd0;
        end
        default: ldr_phase <= 2'd0;
        endcase
    end

    if (loader_done)
        mapper_flags <= loader_flags;
end

// From sdram_nes.v or sdram_sim.v
sdram_nes sdram (
    .clk(fclk), .clkref(clkref), .resetn(sys_resetn), .busy(sdram_busy),

    .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba), 
    .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n), .SDRAM_nRAS(O_sdram_ras_n), 
    .SDRAM_nCAS(O_sdram_cas_n), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm), 

    // PPU
    .addrA(memory_addr_ppu), .weA(memory_write_ppu), .dinA(memory_dout_ppu),
    .oeA(memory_read_ppu), .doutA(memory_din_ppu),

    // CPU
    .addrB(loading ? loader_addr_mem : memory_addr_cpu), .weB(loader_write_mem || memory_write_cpu),
    .dinB(loading ? loader_write_data_mem : memory_dout_cpu),
    .oeB(~loading & memory_read_cpu), .doutB(memory_din_cpu),

`ifdef MCU_BL616
    // IOSys risc-v softcore
    .rv_addr(), .rv_din(), 
    .rv_ds(), .rv_dout(), .rv_req(), .rv_req_ack(), .rv_we()
`else
    // IOSys risc-v softcore
    .rv_addr({rv_addr[20:2], rv_word}), .rv_din(rv_word ? rv_wdata[31:16] : rv_wdata[15:0]), 
    .rv_ds(rv_ds), .rv_dout(rv_dout), .rv_req(rv_req), .rv_req_ack(rv_req_ack), .rv_we(rv_wstrb != 0)
`endif
);

// ROM parser
GameLoader loader(
    .clk(clk), .reset(~sys_resetn | loader_reset), .downloading(loading), 
    .filetype({4'b0000, type_nsf, type_fds, type_nes, type_bios}),
    .is_bios(is_bios), .invert_mirroring(1'b0),
    .indata(loader_do), .indata_clk(loader_do_valid),

    .mem_addr(loader_addr), .mem_data(loader_write_data), .mem_write(loader_write),
    .bios_download(),
    .mapper_flags(loader_flags), .busy(loader_busy), .done(loader_done),
    .error(loader_fail), .rom_loaded()
);

assign int_audio = 1;
assign ext_audio = (mapper_flags[7:0] == 19) | (mapper_flags[7:0] == 24) | (mapper_flags[7:0] == 26);

always @(posedge clk) begin
    clkref <= ~clkref;
    if (~loading && loading_r) begin
        reset_nes <= 0;
        clkref <= 1;
    end else if (loading && ~loading_r)
        reset_nes <= 1;
    // DEBUG: sys_resetn no longer overrides reset_nes — isolating reset source
end

///////////////////////////
// Peripherals
///////////////////////////

`ifdef VERILATOR

// For verilator, the only peripheral is the compiled-in game data 
GameData game_data(
    .clk(clk), .reset(~sys_resetn), .downloading(loading), 
    .odata(loader_do), .odata_clk(loader_do_valid));

`else

// For physical board, there's HDMI, iosys, joypads, and USB
wire overlay;                   // iosys controls overlay
wire [7:0] overlay_x;
wire [7:0]  overlay_y;
wire [14:0] overlay_color;      // BGR5

// DEBUG: diagnostic color mux to visualize loading/reset state on HDMI
// Red    = loading in progress
// Blue   = idle, no ROM ever finished parsing (loader_done==0)
// Green  = loader finished but NES still held in reset (CMD6(0) lost?)
// Normal = reset_nes==0, NES running
wire [5:0] diag_color =
    loading        ? 6'h05 :   // NES palette: red
    (~loader_done) ? 6'h12 :   // NES palette: blue
    reset_nes      ? 6'h1A :   // NES palette: green
                     color;

// DEBUG: snoop the first 64 bytes the loader writes (PRG addresses 0..63)
// Used by nes2hdmi to render an 8x8 grayscale grid of the iNES header + PRG start
// during the GREEN (NES running) diag state. Confirms what bytes reached the FPGA
// loader from the ESP32 UART path.
wire        snoop_we   = loader_write && (loader_addr[21:6] == 16'h0000);
wire [5:0]  snoop_idx  = loader_addr[5:0];
wire [7:0]  snoop_data = loader_write_data;

// DEBUG: snoop ALL CPU READS, indexed by addr low nibble.
// (Previous version gated on physical addr 0..15, but the NES CPU starts at
//  reset vector 0xFFFC which maps to the TOP of PRG-ROM, not addr 0, so that
//  gate almost never fired. By dropping the gate we get a rolling histogram
//  of recent CPU read activity: any non-zero bytes prove the CPU is actually
//  reading SDRAM. All-zero still means CPU is dead or PRG returns zeros.)
wire        rsnoop_we   = ~loading & memory_read_cpu;
wire [3:0]  rsnoop_idx  = memory_addr_cpu[3:0];
wire [7:0]  rsnoop_data = memory_din_cpu;

// DEBUG: capture the FIRST 16 bytes the loader writes -- this is the iNES
// header AS RECEIVED FROM ESP32 (before mem_addr resets to 0 for PRG load,
// which overwrites prg_snoop[0..15]). If hdr_snoop[0..3] == {4E, 45, 53, 1A}
// then the .nes file format is intact and transport is correct. Any other
// pattern proves the cart format / framing / endianness is wrong.
reg [7:0] hdr_snoop [0:15];
reg [4:0] hdr_cnt;   // 5 bits so we can saturate at 16 (bit[4]==1 -> done)
always @(posedge clk) begin
    if (loader_reset)
        hdr_cnt <= 5'd0;
    else if (loader_write && !hdr_cnt[4]) begin
        hdr_snoop[hdr_cnt[3:0]] <= loader_write_data;
        hdr_cnt <= hdr_cnt + 5'd1;
    end
end
// Flatten to one packed bus for nes2hdmi (avoids passing a 2D array port).
wire [127:0] hdr_snoop_flat = {
    hdr_snoop[15], hdr_snoop[14], hdr_snoop[13], hdr_snoop[12],
    hdr_snoop[11], hdr_snoop[10], hdr_snoop[ 9], hdr_snoop[ 8],
    hdr_snoop[ 7], hdr_snoop[ 6], hdr_snoop[ 5], hdr_snoop[ 4],
    hdr_snoop[ 3], hdr_snoop[ 2], hdr_snoop[ 1], hdr_snoop[ 0]
};

// DEBUG: total loader byte count + maximum loader_addr observed. These prove
// whether the loader actually delivered the WHOLE PRG-ROM, not just the header.
//   Healthy 16KB NROM: bcount ~ 0x004010 (header16 + 16K) and amax ~ 0x3FFF.
//   Healthy 32KB NROM: bcount ~ 0x008010 and amax ~ 0x7FFF.
//   Truncation bug:    bcount stays near 0x000010 and amax stays near 0x000F.
reg [23:0] loader_bcount;
reg [21:0] loader_amax;
always @(posedge clk) begin
    if (loader_reset) begin
        loader_bcount <= 24'd0;
        loader_amax   <= 22'd0;
    end else if (loader_write) begin
        loader_bcount <= loader_bcount + 24'd1;
        if (loader_addr > loader_amax) loader_amax <= loader_addr;
    end
end

// DEBUG: rolling latch of the LAST 4 bytes written to PRG region (addr <
// 0x200000). This works for ANY cart size -- 16K, 32K, 64K, etc -- because
// the very last PRG bytes written are always the 6502 vectors (NMI/RESET/IRQ
// at PRG offsets end-6..end-1). For a healthy NES cart:
//   prg_tail[31:24] = PRG[end-4] = reset vec lo ($FFFC contents)
//   prg_tail[23:16] = PRG[end-3] = reset vec hi ($FFFD contents) -- MUST be $80-$FF
//   prg_tail[15: 8] = PRG[end-2] = IRQ   vec lo
//   prg_tail[ 7: 0] = PRG[end-1] = IRQ   vec hi -- MUST be $80-$FF
// CHR writes are skipped because loader jumps mem_addr >= 0x200000 for CHR,
// so the latch preserves the last PRG byte even after CHR-ROM loads.
reg [31:0] prg_tail;
always @(posedge clk) begin
    if (loader_reset) begin
        prg_tail <= 32'd0;
    end else if (loader_write && (loader_addr < 22'h200000)) begin
        prg_tail <= {prg_tail[23:0], loader_write_data};
    end
end

// DEBUG: sticky CPU activity counters (post-loading). These confirm whether
// memory_read_cpu / memory_write_cpu EVER pulse, independent of the snoop
// data values (an all-0x00 or all-0xFF snoop row could still mean the CPU
// is alive and reading garbage). Counters wrap at 256 -> low byte shown.
reg  [7:0] cpu_rcount;
reg  [7:0] cpu_wcount;
// DEBUG: latch the LAST CPU read & write addresses + last write data byte
// (latched on every pulse, so they show the most-recent activity). Lets
// us see whether CPU is stuck near $FFFC (reset vec) / $0000 (BRK loop)
// and whether writes are landing in stack ($0100) / cart-ram ($6000) / etc.
reg  [21:0] last_raddr;
reg  [21:0] last_waddr;
reg   [7:0] last_wdata;
// DEBUG: last byte the CPU's memory_din_cpu bus held. Sampled every cycle
// after loading completes so SDRAM read latency / pipelining doesn't matter
// -- we'll always see the most recent value the CPU saw on its read port.
//   If last_rdata stays $00 while rcount climbs -> SDRAM-read PATH IS BROKEN
//     (writes verified by prg_tail, so the data is there; we just can't read it).
//   If last_rdata is $4C/$78/$A9/etc. (real 6502 opcodes) -> read path OK,
//     bug is elsewhere (mapper bank selection, PPU, etc.).
reg   [7:0] last_rdata;
// DEBUG: sticky-OR of every PPU `color` output (NES palette index, 6-bit) seen
// since the loader finished. Answers: is the PPU producing ANY non-zero pixel?
//   $00 (black) -> PPU stuck at index 0 (NES_PALETTE[0]=$545454 grey) -- but
//                  screen is BLACK not grey, so this would mean PPU is dead.
//   non-zero    -> PPU IS producing pixels; bug is that all indices happen to
//                  map to a black palette entry (palette RAM stuck at $0F).
reg   [5:0] ppu_pixel_max;
// DEBUG: sticky 8-bit byte that lights one bit per kind of CPU<->PPU register
// access. CPU registers live at $2000-$3FFF (mirrored every 8) and these
// accesses do NOT pass through memory_*_cpu (only PRG ROM/RAM in SDRAM does).
// So we tap the internal CPU bus directly via dbg_addr/dbg_mr/dbg_mw, gated
// by cpu_ce so we sample on real bus cycles only.
//   bit 0 = CPU read $2002 (PPUSTATUS, VBLANK poll)
//   bit 1 = CPU read $2007 (PPUDATA)
//   bit 2 = CPU read any other $2xxx register
//   bit 3 = CPU write $2000 (PPUCTRL, NMI enable)
//   bit 4 = CPU write $2001 (PPUMASK, rendering enable!)
//   bit 5 = CPU write $2003 (OAMADDR)
//   bit 6 = CPU write $2006 (PPUADDR)
//   bit 7 = CPU write $2007 (PPUDATA)
// Reading:
//   $00 dark green   -> CPU never touched PPU regs (stuck before WAIT_VBLANK)
//   $01-$07 dim      -> reads only, no writes (stuck in VBLANK wait!)
//   $1F bright purple-> wrote PPUMASK -> rendering should be on; bug in PPU
//   $FF bright pink  -> full PPU init done; palette/VRAM corrupt
reg   [7:0] ppu_iface;
wire ppu_reg_sel = (cpu_dbg_addr[15:13] == 3'b001); // $2000-$3FFF
wire [2:0] ppu_reg_idx = cpu_dbg_addr[2:0];
always @(posedge clk) begin
    if (loading) begin
        cpu_rcount <= 8'd0;
        cpu_wcount <= 8'd0;
        last_raddr <= 22'd0;
        last_waddr <= 22'd0;
        last_wdata <= 8'd0;
        last_rdata <= 8'd0;
        ppu_pixel_max <= 6'd0;
        ppu_iface <= 8'd0;
    end else begin
        if (memory_read_cpu)  begin cpu_rcount <= cpu_rcount + 8'd1; last_raddr <= memory_addr_cpu; end
        if (memory_write_cpu) begin cpu_wcount <= cpu_wcount + 8'd1; last_waddr <= memory_addr_cpu; last_wdata <= memory_dout_cpu; end
        last_rdata <= memory_din_cpu;
        ppu_pixel_max <= ppu_pixel_max | color;
        // Sticky PPU-register-access tracker (sample on real CPU bus cycles)
        if (cpu_dbg_ce && ppu_reg_sel) begin
            if (cpu_dbg_mr) begin
                if (ppu_reg_idx == 3'd2)      ppu_iface[0] <= 1'b1; // read $2002
                else if (ppu_reg_idx == 3'd7) ppu_iface[1] <= 1'b1; // read $2007
                else                          ppu_iface[2] <= 1'b1; // read other $2xxx
            end
            if (cpu_dbg_mw) begin
                case (ppu_reg_idx)
                    3'd0: ppu_iface[3] <= 1'b1; // write $2000 (PPUCTRL)
                    3'd1: ppu_iface[4] <= 1'b1; // write $2001 (PPUMASK)
                    3'd3: ppu_iface[5] <= 1'b1; // write $2003 (OAMADDR)
                    3'd6: ppu_iface[6] <= 1'b1; // write $2006 (PPUADDR)
                    3'd7: ppu_iface[7] <= 1'b1; // write $2007 (PPUDATA)
                    default: ;                  // ignore other writes
                endcase
            end
        end
    end
end

// HDMI output
nes2hdmi u_hdmi (     // purple: RGB=440064 (010001000_00000000_01100100), BGR5=01100_00000_01000
    .clk(clk), .resetn(sys_resetn),
    .color(diag_color), .cycle(cycle), 
    .diag({loading, ~loader_done, reset_nes}),
    .snoop_we(snoop_we), .snoop_idx(snoop_idx), .snoop_data(snoop_data),
    .rsnoop_we(rsnoop_we), .rsnoop_idx(rsnoop_idx), .rsnoop_data(rsnoop_data),
    .diag_rdata(last_rdata),
    .diag_ppu_max({2'b0, ppu_pixel_max}),
    .diag_wcount(ppu_iface),  // REPURPOSED: now sticky PPU-register-interaction byte
    .diag_raddr_lo(last_raddr[7:0]),
    .diag_raddr_hi(last_raddr[15:8]),
    .diag_waddr_lo(last_waddr[7:0]),
    .diag_waddr_hi(last_waddr[15:8]),
    .diag_wdata(last_wdata),
    .diag_hdr(hdr_snoop_flat),
    .diag_load_bcount(loader_bcount),
    .diag_load_amax_lo(loader_amax[15:8]),
    .diag_load_amax_hi(loader_amax[21:16]),
    .diag_prg_tail(prg_tail),
    .scanline(scanline), .sample(sample >> 1),
    .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y),
    .overlay_color(overlay_color),
    .clk_pixel(hclk), .clk_5x_pixel(hclk5),
    .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
    .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
);


// IO system: FPGA Companion SPI (PAPILIO_ARCADE) or BL616 UART
// `ifdef PAPILIO_ARCADE
// iosys_retrocade #(.CORE_ID(8'd7), .FREQ(21_600_000)) sys_inst (
//     .clk(clk), .hclk(hclk), .resetn(sys_resetn),
//     .m0s(m0s),
//     .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat),
//     .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
//     .hid1(hid1), .hid2(hid2),
//     .rom_loading(loading), .rom_do(loader_do), .rom_do_valid(loader_do_valid)
// );
// `else
// Connect to BL616 companion MCU for sys module for menu, rom loading...
iosys_bl616 #(.COLOR_LOGO(15'b01100_00000_01000), .FREQ(21_492_000), .CORE_ID(1) )     // purple nestang logo
    sys_inst (
    .clk(clk), .hclk(hclk), .resetn(sys_resetn),

    .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
    .joy1(joy1_btns | joy_usb1), .joy2(joy2_btns | joy_usb2),
    .hid1(hid1), .hid2(hid2),
    .uart_tx(UART_TXD), .uart_rx(UART_RXD),

    .rom_loading(loading), .rom_do(loader_do), .rom_do_valid(loader_do_valid)
);
// `endif

// Controller input
// `ifdef CONTROLLER_SNES
// controller_snes joy1_snes (
//     .clk(clk), .resetn(sys_resetn), .buttons(joy1_btns),
//     .joy_strb(joy1_strb), .joy_clk(joy1_clk), .joy_data(joy1_data)
// );
// controller_snes joy2_snes (
//     .clk(clk), .resetn(sys_resetn), .buttons(joy2_btns),
//     .joy_strb(joy2_strb), .joy_clk(joy2_clk), .joy_data(joy2_data)
// );
// `endif

// `ifdef CONTROLLER_DS2
// controller_ds2 joy1_ds2 (
//     .clk(clk), .snes_buttons(joy1_btns),
//     .ds_clk(ds_clk), .ds_miso(ds_miso), .ds_mosi(ds_mosi), .ds_cs(ds_cs) 
// );
// controller_ds2 joy2_ds2 (
//    .clk(clk), .snes_buttons(joy2_btns),
//    .ds_clk(ds_clk2), .ds_miso(ds_miso2), .ds_mosi(ds_mosi2), .ds_cs(ds_cs2) 
// );
// `endif

`ifdef USB1
wire clk12;
wire pll_lock_12;
wire usb_conerr;
wire [1:0] usb_type;
pll_12 pll12(.clkin(sys_clk), .clkout0(clk12), .lock(pll_lock_12));
usb_hid_host usb_hid_host (
    .usbclk(clk12), .usbrst_n(pll_lock_12),
    .usb_dm(usb1_dn), .usb_dp(usb1_dp),
    .game_snes(joy_usb1), .typ(usb_type), .conerr(usb_conerr)
);
`else
assign joy_usb1 = 12'b0;
`endif

`ifdef USB2
wire usb_conerr2;
wire [1:0] usb_type2;
usb_hid_host usb_hid_host2 (
    .usbclk(clk12), .usbrst_n(pll_lock_12),
    .usb_dm(usb2_dn), .usb_dp(usb2_dp),
    .game_snes(joy_usb2), .typ(usb_type2), .conerr(usb_conerr2)
);
assign led = ~{joy_usb2[1:0], usb_type2, usb_conerr2, usb_type, usb_conerr};
`else
assign joy_usb2 = 12'b0;
`endif

// Autofire for NES A (right) and B (left) buttons
// Autofire af_a (.clk(clk), .resetn(sys_resetn), .btn(joy1[8]), .out(auto_a));
// Autofire af_b (.clk(clk), .resetn(sys_resetn), .btn(joy1[9]), .out(auto_b));
// Autofire af_a2 (.clk(clk), .resetn(sys_resetn), .btn(joy2[8]), .out(auto_a2));
// Autofire af_b2 (.clk(clk), .resetn(sys_resetn), .btn(joy2[9]), .out(auto_b2));

// Joypad handling
always @(posedge clk) begin
    if (joypad_strobe) begin
        joypad_bits <= {joy1[7:2], joy1[1] | auto_b, joy1[0] | auto_a};;
        joypad_bits2 <= {joy2[7:2], joy2[1] | auto_b2, joy2[0] | auto_a2};
    end
    if (!joypad_clock[0] && last_joypad_clock[0])
        joypad_bits <= {1'b1, joypad_bits[7:1]};
    if (!joypad_clock[1] && last_joypad_clock[1])
        joypad_bits2 <= {1'b1, joypad_bits2[7:1]};
    last_joypad_clock <= joypad_clock;
end
assign joypad1_data[0] = joypad_bits[0];
assign joypad2_data[0] = joypad_bits2[0];

`endif

//assign led = ~{~UART_RXD, loader_done};
//assign led = ~{~UART_RXD, usb_conerr, loader_done};

reg [23:0] led_cnt;
always @(posedge clk) led_cnt <= led_cnt + 1;
//assign led = {led_cnt[23], led_cnt[22]};

`ifndef PAPILIO_ARCADE
// SD card pass-through: ESP32 SPI <-> Tang Primer 20K onboard TF slot
// FPGA is pure wire routing — ESP32 speaks native SPI-to-SD protocol
assign sd_clk            = pmod_companion_clk;
assign sd_cmd            = pmod_companion_din;
assign pmod_companion_dout = sd_miso;
assign sd_cs             = pmod_companion_ss;
assign sd_dat1           = 1'b1;
assign sd_dat2           = 1'b1;
`endif

endmodule