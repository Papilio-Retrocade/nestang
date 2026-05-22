// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

module nes2hdmi (
	input clk,      // nes clock
	input resetn,

    // nes video signals
    input [5:0] color,
    input [2:0] diag,    // {loading, ~loader_done, reset_nes}
    // DEBUG: PRG byte snoop (driven from nestang_top off the loader write path)
    input        snoop_we,    // pulse: latch snoop_data at snoop_idx
    input  [5:0] snoop_idx,   // 0..63, PRG byte index
    input  [7:0] snoop_data,  // byte value
    // DEBUG: CPU READ snoop (driven from nestang_top off memory_din_cpu)
    input        rsnoop_we,   // CPU reading addr in 0..15 (gated)
    input  [3:0] rsnoop_idx,  // 0..15, addr low nibble
    input  [7:0] rsnoop_data, // byte value on memory_din_cpu
    // DEBUG: per-cart static diagnostics (latched at top level, stable in GREEN)
    input  [7:0] diag_rdata,  // last byte CPU saw on memory_din_cpu (proves SDRAM read path)
    input  [7:0] diag_ppu_max, // sticky-OR of PPU color output since reset (0=PPU dead, non-0=PPU alive)
    input  [7:0] diag_rcount, // CPU read pulse count (wraps mod 256) since loader_done
    input  [7:0] diag_wcount, // CPU write pulse count (wraps mod 256) since loader_done
    input  [7:0] diag_raddr_lo,// last memory_addr_cpu[7:0]   on a CPU read
    input  [7:0] diag_raddr_hi,// last memory_addr_cpu[15:8]  on a CPU read
    input  [7:0] diag_waddr_lo,// last memory_addr_cpu[7:0]   on a CPU write
    input  [7:0] diag_waddr_hi,// last memory_addr_cpu[15:8]  on a CPU write
    input  [7:0] diag_wdata,   // last memory_dout_cpu on a CPU write
    input [127:0] diag_hdr,    // first 16 loader-written bytes (iNES header as received)
    input [23:0] diag_load_bcount, // total loader_write pulses since loader_reset
    input  [7:0] diag_load_amax_lo,// bits [15:8] of highest loader_addr observed
    input  [5:0] diag_load_amax_hi,// bits [21:16] of highest loader_addr observed (0x20+ means CHR loaded)
    input [31:0] diag_prg_tail,    // last 4 bytes the loader wrote to PRG region (addr<0x200000)
                                   // tail[31:24]=PRG[end-4]=reset_lo, [23:16]=reset_hi, [15:8]=IRQ_lo, [7:0]=IRQ_hi
    input [8:0] cycle,
    input [8:0] scanline,
    input [15:0] sample,
    input aspect_8x7,       // 1: 8x7 pixel aspect ratio mode

    // overlay interface
    input overlay,
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color, // BGR5

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

// NES generates 256x240. We assume the center 256x224 is visible and scale that to 4:3 aspect ratio.
// https://www.nesdev.org/wiki/Overscan

localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;

// localparam IDIV_SEL_X5 = 3;
// localparam FBDIV_SEL_X5 = 54;
// localparam ODIV_SEL_X5 = 2;
// localparam DUTYDA_SEL_X5 = "1000";
// localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 74250;

localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;

localparam POWERUPNS = 100000000.0;
localparam CLKPERNS = (1.0/CLKFRQ)*1000000.0;
localparam int POWERUPCYCLES = $rtoi($ceil( POWERUPNS/CLKPERNS ));

// video stuff
wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// BRAM frame buffer
//
localparam MEM_DEPTH=256*240;
localparam MEM_ABITS=16;

logic [5:0] mem [0:256*240-1];
logic [15:0] mem_portA_addr;
logic [5:0] mem_portA_wdata;
logic mem_portA_we;

wire [15:0] mem_portB_addr;
logic [5:0] mem_portB_rdata;

// BRAM port A read/write
always_ff @(posedge clk) begin
    if (mem_portA_we) begin
        mem[mem_portA_addr] <= mem_portA_wdata;
    end
end

// BRAM port B read
always_ff @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

initial begin
    $readmemb("background.txt", mem);
end


// 
// Data input and initial background loading
//
logic [8:0] r_scanline;
logic [8:0] r_cycle;
always @(posedge clk) begin
    r_scanline <= scanline;
    r_cycle <= cycle;
    mem_portA_we <= 1'b0;
    if ((r_scanline != scanline || r_cycle != cycle) && scanline < 9'd240 && ~cycle[8]) begin
        mem_portA_addr <= {scanline[7:0], cycle[7:0]};
        mem_portA_wdata <= color;
        mem_portA_we <= 1'b1;
    end
end

// audio stuff
//    localparam AUDIO_RATE=32000;        // weird only 32K sampling rate works
//    localparam AUDIO_RATE=96000;
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
always @(posedge clk_pixel) begin       // crossing clock domain
    audio_sample_word0[0] <= sample;
    audio_sample_word[0] <= audio_sample_word0[0];
    audio_sample_word0[1] <= sample;
    audio_sample_word[1] <= audio_sample_word0[1];
end

//
// Video
// Scale 256x224 to 1280x720
//
localparam WIDTH=256;
localparam HEIGHT=240;
reg [23:0] rgb;             // actual RGB output
reg active                  /* xsynthesis syn_keep=1 */;
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;
assign mem_portB_addr = yy * WIDTH + xx + 8*256;
assign overlay_x = xx;
assign overlay_y = yy;
localparam XSTART = (1280 - 960) / 2;   // 960:720 = 4:3
localparam XSTOP = (1280 + 960) / 2;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
// xcnt and ycnt are fractional scaling counters.
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + 256;
    ycnt_next = ycnt + 224;

    active_t = 0;
    if (cx == XSTART - 1) begin
        active_t = 1;
        active <= 1;
    end else if (cx == XSTOP - 1) begin
        active_t = 0;
        active <= 0;
    end

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (xcnt_next >= 960) begin
            xcnt <= xcnt_next - 960;
            xx <= xx + 1;
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
            yy <= yy + 1;
        end
    end

    if (cx == 0) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

// DEBUG: snoop the first 64 PRG bytes as they go past the loader (writes).
// Latched in `clk` (NES) domain; safely read after loader_done (no longer changing).
reg [7:0] prg_snoop [0:63];
always @(posedge clk) begin
    if (snoop_we)
        prg_snoop[snoop_idx] <= snoop_data;
end

// DEBUG: snoop CPU READS from SDRAM addr 0..15. Sampled in `clk` domain on
// any cycle where the CPU is actively reading one of these bytes back from
// the controller. Last sample wins (doutB stays stable between requests).
reg [7:0] cpu_read_snoop [0:15];
always @(posedge clk) begin
    if (rsnoop_we)
        cpu_read_snoop[rsnoop_idx] <= rsnoop_data;
end

// Overlay strip in top-right of NES active area:
//   xx in [128..255] (right half), yy in [0..47] (top 48 lines)
//   -> 8 cols x 3 rows of 16x16 cells
//   Row 0 (top)    = loader writes  prg_snoop[0..7]     (grayscale)
//   Row 1 (mid)    = LOADER TELEMETRY                    (yellow on BLUE floor)
//                    col0=bcount[7:0]  col1=bcount[15:8] col2=bcount[23:16]
//                    col3=amax[15:8]   col4=amax[21:16]   (amax_hi 0x20+ => CHR loaded)
//                    col5=prg_tail[31:24] = reset vec lo (PRG[end-4])
//                    col6=prg_tail[23:16] = reset vec hi (PRG[end-3]) -- HEALTHY = $80..$FF (yellow!)
//                    col7=prg_tail[ 7: 0] = IRQ   vec hi (PRG[end-1]) -- HEALTHY = $80..$FF (yellow!)
//   Row 2 (bottom) = static cart diag                    (yellow on GREEN floor)
//                    col0=mapper#  col1=rcount   col2=wcount
//                    col3=Raddr_lo col4=Raddr_hi
//                    col5=Waddr_lo col6=Waddr_hi col7=Wdata
//   Interpreting: if (col4,col3) shows $FF,$FC -> CPU stuck reading reset vec.
//                 if (col6,col5) shows $01,xx  -> CPU writing to stack page.
//                 if (col6,col5) shows $00,xx  -> CPU writing to zero page.
//                 if (col6,col5) shows $6x,xx  -> CPU writing to PRG-RAM range.
//   Row 3 (yy 48..63) = iNES HEADER as received by loader (cyan on dark-red)
//                       col0=byte0 col1=byte1 col2=byte2 col3=byte3
//                       col4=byte4 col5=byte5 col6=byte6 col7=byte7
//                       Healthy:  4E 45 53 1A NN MM FF GG  ("NES\x1A" + sizes/flags)
//                       Anything else -> .nes file / framing / transport is wrong.
//   If row 0 == row 1 across all 8 columns -> SDRAM round-trip is healthy.
//   If they differ -> SDRAM read corruption (timing / port conflict / bank).
wire ovr_active = (yy < 7'd64) && (xx >= 8'd128);
wire [2:0] ovr_col = xx[6:4];        // (xx-128)>>4 = xx[6:4]
wire [1:0] ovr_row = yy[5:4];         // 0=top 1=mid 2=bottom 3=hdr
reg  [7:0] ovr_byte;
always @(posedge clk_pixel) begin
    case (ovr_row)
        2'd0: ovr_byte <= prg_snoop[{3'b0, ovr_col}];
        2'd1: begin
            // Row 1: loader telemetry (proves whether full PRG-ROM arrived)
            case (ovr_col)
                3'd0:    ovr_byte <= diag_load_bcount[ 7: 0];
                3'd1:    ovr_byte <= diag_load_bcount[15: 8];
                3'd2:    ovr_byte <= diag_load_bcount[23:16];
                3'd3:    ovr_byte <= diag_load_amax_lo;       // amax[15:8]
                3'd4:    ovr_byte <= {2'd0, diag_load_amax_hi};// amax[21:16] -> 0x20+ if CHR
                3'd5:    ovr_byte <= diag_prg_tail[31:24];    // reset vec lo (PRG[end-4])
                3'd6:    ovr_byte <= diag_prg_tail[23:16];    // reset vec hi (PRG[end-3]) -- should be yellow
                3'd7:    ovr_byte <= diag_prg_tail[ 7: 0];    // IRQ vec hi (PRG[end-1]) -- should be yellow
                default: ovr_byte <= 8'h00;
            endcase
        end
        2'd3: begin
            // Row 3: iNES header bytes 0..7 (cells 0..7)
            case (ovr_col)
                3'd0: ovr_byte <= diag_hdr[  7:  0];  // hdr_snoop[0]
                3'd1: ovr_byte <= diag_hdr[ 15:  8];  // hdr_snoop[1]
                3'd2: ovr_byte <= diag_hdr[ 23: 16];  // hdr_snoop[2]
                3'd3: ovr_byte <= diag_hdr[ 31: 24];  // hdr_snoop[3]
                3'd4: ovr_byte <= diag_hdr[ 39: 32];  // hdr_snoop[4] = prgrom
                3'd5: ovr_byte <= diag_hdr[ 47: 40];  // hdr_snoop[5] = chrrom
                3'd6: ovr_byte <= diag_hdr[ 55: 48];  // hdr_snoop[6] = flags6
                3'd7: ovr_byte <= diag_hdr[ 63: 56];  // hdr_snoop[7] = flags7
                default: ovr_byte <= 8'h00;
            endcase
        end
        default: begin
            case (ovr_col)
                3'd0:    ovr_byte <= diag_rdata;   // SDRAM-read sanity: $00 stuck = read broken, $4C/$78/$A9 = real opcode
                3'd1:    ovr_byte <= diag_ppu_max; // PPU liveness: $00 = PPU never emits non-zero pixel -> PPU dead
                3'd2:    ovr_byte <= diag_wcount;
                3'd3:    ovr_byte <= diag_raddr_lo;
                3'd4:    ovr_byte <= diag_raddr_hi;
                3'd5:    ovr_byte <= diag_waddr_lo;
                3'd6:    ovr_byte <= diag_waddr_hi;
                3'd7:    ovr_byte <= diag_wdata;
                default: ovr_byte <= 8'h00;
            endcase
        end
    endcase
end

// 2-pixel MAGENTA gridlines around overlay strip + between rows.
// Magenta is always visible against black, so even an all-zero row
// shows its frame and you can tell empty vs missing.
wire ovr_gridline = ovr_active && (
    (xx[3:0] < 4'd2) ||
    (yy[3:0] < 4'd2) ||
    (yy == 9'd63) ||
    (xx == 9'd128) ||
    (yy == 9'd15) || (yy == 9'd16) ||  // divider between row 0 and row 1
    (yy == 9'd31) || (yy == 9'd32) ||  // divider between row 1 and row 2
    (yy == 9'd47) || (yy == 9'd48)     // divider between row 2 and row 3
);

// calc rgb value to hdmi
reg [23:0] NES_PALETTE [0:63];
always @(posedge clk_pixel) begin
    if (active) begin
        if (overlay)
            rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else begin
            // DIAG: encode loader state as solid color in NES area
            //   diag[2]=loading, diag[1]=~loader_done, diag[0]=reset_nes
            case (diag)
                // GREEN: ROM done, NES running. Show real NES PPU output, with a
                // small 8x2 strip in top-right.  Top row = loader writes (grayscale),
                // bottom row = CPU reads from same addrs (BLUE-tinted so 0x00 shows
                // as dark blue and is distinguishable from background black).
                3'b000: begin
                    if (ovr_gridline)
                        rgb <= 24'hFF00FF;   // magenta frame & divider
                    else if (ovr_active && ovr_row == 2'd3)
                        rgb <= {8'h40, ovr_byte, ovr_byte}; // row 3: cyan-on-dark-red (iNES header)
                    else if (ovr_active && ovr_row == 2'd2)
                        rgb <= {ovr_byte, 8'h40, ovr_byte}; // row 2: yellow-on-green tint (static cart diag)
                    else if (ovr_active && ovr_row == 2'd1)
                        rgb <= {ovr_byte, ovr_byte, 8'h40};   // row 1: yellow-on-blue tint (CPU reads)
                    else if (ovr_active)
                        rgb <= {ovr_byte, ovr_byte, ovr_byte}; // row 0: grayscale (loader writes)
                    else
                        rgb <= NES_PALETTE[mem_portB_rdata];
                end
                3'b001: rgb <= 24'h00FFFF;  // CYAN:  ROM done but NES held in reset (CMD6(0) lost)
                3'b010: rgb <= 24'h0000FF;  // BLUE:  idle, no ROM loaded yet
                3'b011: rgb <= 24'h800080;  // PURPLE: idle + reset (boot state)
                3'b100: rgb <= 24'hFFFF00;  // YELLOW: loading without reset (shouldn't happen)
                3'b101: rgb <= 24'hFF8000;  // ORANGE: loading + done? (shouldn't happen)
                3'b110: rgb <= 24'hFF0000;  // RED:   loading in progress (normal)
                3'b111: rgb <= 24'hFFFFFF;  // WHITE: loading + reset + not-done (also normal)
            endcase
        end
    end else
        rgb <= 24'h303030;
end

// HDMI output.
logic[2:0] tmds;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( 0 ),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( frameWidth ),
        .frame_height( frameHeight ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

// 2C02 palette: https://www.nesdev.org/wiki/PPU_palettes
assign NES_PALETTE[0] = 24'h545454;  assign NES_PALETTE[1] = 24'h001e74;  assign NES_PALETTE[2] = 24'h081090;  assign NES_PALETTE[3] = 24'h300088;  
assign NES_PALETTE[4] = 24'h440064;  assign NES_PALETTE[5] = 24'h5c0030;  assign NES_PALETTE[6] = 24'h540400;  assign NES_PALETTE[7] = 24'h3c1800;
assign NES_PALETTE[8] = 24'h202a00;  assign NES_PALETTE[9] = 24'h083a00;  assign NES_PALETTE[10] = 24'h004000;  assign NES_PALETTE[11] = 24'h003c00;  
assign NES_PALETTE[12] = 24'h00323c;  assign NES_PALETTE[13] = 24'h000000;  assign NES_PALETTE[14] = 24'h000000;  assign NES_PALETTE[15] = 24'h000000;
assign NES_PALETTE[16] = 24'h989698;  assign NES_PALETTE[17] = 24'h084cc4;  assign NES_PALETTE[18] = 24'h3032ec;  assign NES_PALETTE[19] = 24'h5c1ee4;  
assign NES_PALETTE[20] = 24'h8814b0;  assign NES_PALETTE[21] = 24'ha01464;  assign NES_PALETTE[22] = 24'h982220;  assign NES_PALETTE[23] = 24'h783c00;
assign NES_PALETTE[24] = 24'h545a00;  assign NES_PALETTE[25] = 24'h287200;  assign NES_PALETTE[26] = 24'h087c00;  assign NES_PALETTE[27] = 24'h007628; 
assign NES_PALETTE[28] = 24'h006678;  assign NES_PALETTE[29] = 24'h000000;  assign NES_PALETTE[30] = 24'h000000;  assign NES_PALETTE[31] = 24'h000000;
assign NES_PALETTE[32] = 24'heceeec;  assign NES_PALETTE[33] = 24'h4c9aec;  assign NES_PALETTE[34] = 24'h787cec;  assign NES_PALETTE[35] = 24'hb062ec;  
assign NES_PALETTE[36] = 24'he454ec;  assign NES_PALETTE[37] = 24'hec58b4;  assign NES_PALETTE[38] = 24'hec6a64;  assign NES_PALETTE[39] = 24'hd48820;
assign NES_PALETTE[40] = 24'ha0aa00;  assign NES_PALETTE[41] = 24'h74c400;  assign NES_PALETTE[42] = 24'h4cd020;  assign NES_PALETTE[43] = 24'h38cc6c; 
assign NES_PALETTE[44] = 24'h38b4cc;  assign NES_PALETTE[45] = 24'h3c3c3c;  assign NES_PALETTE[46] = 24'h000000;  assign NES_PALETTE[47] = 24'h000000;
assign NES_PALETTE[48] = 24'heceeec;  assign NES_PALETTE[49] = 24'ha8ccec;  assign NES_PALETTE[50] = 24'hbcbcec;  assign NES_PALETTE[51] = 24'hd4b2ec;
assign NES_PALETTE[52] = 24'hecaeec;  assign NES_PALETTE[53] = 24'hecaed4;  assign NES_PALETTE[54] = 24'hecb4b0;  assign NES_PALETTE[55] = 24'he4c490;
assign NES_PALETTE[56] = 24'hccd278;  assign NES_PALETTE[57] = 24'hb4de78;  assign NES_PALETTE[58] = 24'ha8e290;  assign NES_PALETTE[59] = 24'h98e2b4;
assign NES_PALETTE[60] = 24'ha0d6e4;  assign NES_PALETTE[61] = 24'ha0a2a0;  assign NES_PALETTE[62] = 24'h000000;  assign NES_PALETTE[63] = 24'h000000;

endmodule
