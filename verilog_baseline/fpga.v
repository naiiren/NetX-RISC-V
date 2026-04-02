// The shared FPGA wrapper already contains `rv32i_data_mem_adapter`, so the
// handwritten baseline peripheral file starts directly with the MMIO devices.

/**
 * On-board LCD driver for a 16x2 HD44780-compatible character LCD. 
 * This block implements a simple FSM to initialize the LCD and then continuously update the
 * display based on a shadow text RAM that the CPU can write to via MMIO.
 * The CPU can write ASCII character codes to the text RAM, and the LCD driver will handle
 * the necessary command sequences to update the display.
 *
 * @port clk        System clock
 * @port rst        Reset signal
 * @port core_addr  CPU/MMIO address
 * @port core_wdata CPU/MMIO write data
 * @port core_op    CPU load/store width selector
 * @port core_we    CPU write enable
 * @port core_rdata MMIO readback word
 * @port mmio_hit   High when the LCD MMIO window is selected
 * @port lcd_data   LCD command/data byte
 * @port lcd_blon   LCD backlight control
 * @port lcd_en     LCD enable pulse
 * @port lcd_on     LCD power control
 * @port lcd_rs     LCD register-select signal
 * @port lcd_rw     LCD read/write signal
 */
module LCD_DRIVER(
    input         clk,
    input         rst,
    input  [31:0] core_addr,
    input  [31:0] core_wdata,
    input  [2:0]  core_op,
    input         core_we,
    output reg [31:0] core_rdata,
    output        mmio_hit,
    output reg [7:0] lcd_data,
    output reg       lcd_blon,
    output reg       lcd_en,
    output reg       lcd_on,
    output reg       lcd_rs,
    output reg       lcd_rw
);
    localparam [3:0] LCD_BOOT0  = 4'b0001;
    localparam [3:0] LCD_BOOT1  = 4'b0010;
    localparam [3:0] LCD_BOOT2  = 4'b0011;
    localparam [3:0] LCD_FUNC   = 4'b0100;
    localparam [3:0] LCD_ON_CMD = 4'b0101;
    localparam [3:0] LCD_CLEAR  = 4'b0110;
    localparam [3:0] LCD_ENTRY  = 4'b0111;
    localparam [3:0] LCD_ADDR   = 4'b1100;
    localparam [3:0] LCD_CHAR   = 4'b1111;

    localparam [7:0] CMD_CLEAR          = 8'h01;
    localparam [7:0] CMD_ENTRY_MODE     = 8'h06;
    localparam [7:0] CMD_DISPLAY_CTRL   = 8'h0c;
    localparam [7:0] CMD_FUNC_SET       = 8'h38;
    localparam [7:0] CMD_SET_DDRAM_ADDR = 8'h80;
    localparam [7:0] CMD_BOOT_FUNC      = 8'h30;

    // CPU-visible shadow text buffer, one byte per LCD cell.
    reg [7:0] text_ram [0:31];
    reg [4:0] lcd_index;
    reg [3:0] lcd_state;
    reg [1:0] lcd_phase;
    reg [23:0] lcd_wait;
    integer i;

    wire write_op       = (core_op == 3'b000) || (core_op == 3'b001) || (core_op == 3'b010);
    wire lcd_page       = core_addr[31] && (core_addr[31:8] == 24'h800000);
    wire lcd_status_sel = lcd_page && (core_addr[7:0] == 8'h00);
    wire lcd_ctrl_sel   = lcd_page && (core_addr[7:0] == 8'h04);
    wire lcd_text_sel   = lcd_page && (core_addr[7:5] == 3'b001);
    wire lcd_clear_req  = lcd_ctrl_sel && core_we && core_wdata[0];
    wire boot_state     = (lcd_state == LCD_BOOT0) || (lcd_state == LCD_BOOT1) || (lcd_state == LCD_BOOT2);
    wire lcd_step       = (lcd_wait == 24'd0);
    wire lcd_advance    = (lcd_phase == 2'd3) && lcd_step;
    wire [7:0] scan_lcd_byte = text_ram[lcd_index];
    wire [7:0] cpu_lcd_byte  = text_ram[core_addr[4:0]];
    wire [7:0] lcd_addr_base = lcd_index[4] ? (CMD_SET_DDRAM_ADDR + 8'h40) : CMD_SET_DDRAM_ADDR;

    assign mmio_hit = lcd_status_sel || lcd_ctrl_sel || lcd_text_sel;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1) text_ram[i] <= 8'h20;
        end else begin
            if (lcd_clear_req) begin
                for (i = 0; i < 32; i = i + 1) text_ram[i] <= 8'h20;
            end else if (lcd_text_sel && core_we && write_op) begin
                text_ram[core_addr[4:0]] <= core_wdata[7:0];
            end
        end
    end

    // Four-phase LCD transaction timing: setup, pulse, hold, and inter-command
    // wait. The boot states use longer waits to satisfy the HD44780 power-on
    // sequence.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lcd_index <= 5'd0;
            lcd_state <= LCD_BOOT0;
            lcd_phase <= 2'd0;
            lcd_wait  <= 24'd5000000;
        end else begin
            if (lcd_step) begin
                case (lcd_phase)
                    2'd0: begin lcd_phase <= 2'd1; lcd_wait <= 24'd5000; end
                    2'd1: begin lcd_phase <= 2'd2; lcd_wait <= 24'd5000; end
                    2'd2: begin lcd_phase <= 2'd3; lcd_wait <= 24'd5000; end
                    2'd3: begin
                        lcd_phase <= 2'd1;
                        if (!boot_state) begin
                            lcd_wait <= (lcd_state == LCD_CLEAR) ? 24'd300000 : 24'd50000;
                        end else begin
                            case (lcd_state)
                                LCD_BOOT0, LCD_BOOT1: lcd_wait <= 24'd500000;
                                LCD_BOOT2:           lcd_wait <= 24'd100000;
                                default:             lcd_wait <= 24'd50000;
                            endcase
                        end

                        case (lcd_state)
                            LCD_BOOT0:  lcd_state <= LCD_BOOT1;
                            LCD_BOOT1:  lcd_state <= LCD_BOOT2;
                            LCD_BOOT2:  lcd_state <= LCD_FUNC;
                            LCD_FUNC:   lcd_state <= LCD_ON_CMD;
                            LCD_ON_CMD: lcd_state <= LCD_CLEAR;
                            LCD_CLEAR:  lcd_state <= LCD_ENTRY;
                            LCD_ENTRY:  lcd_state <= LCD_ADDR;
                            LCD_ADDR:   lcd_state <= LCD_CHAR;
                            LCD_CHAR: begin
                                lcd_state <= LCD_ADDR;
                                if (lcd_index == 5'd31) lcd_index <= 5'd0;
                                else                    lcd_index <= lcd_index + 5'd1;
                            end
                            default: lcd_state <= LCD_FUNC;
                        endcase
                    end
                endcase
            end else begin
                lcd_wait <= lcd_wait - 24'd1;
            end
        end
    end

    always @(*) begin
        case (lcd_state)
            LCD_BOOT0,
            LCD_BOOT1,
            LCD_BOOT2: lcd_data = CMD_BOOT_FUNC;
            LCD_FUNC:   lcd_data = CMD_FUNC_SET;
            LCD_ON_CMD: lcd_data = CMD_DISPLAY_CTRL;
            LCD_CLEAR:  lcd_data = CMD_CLEAR;
            LCD_ENTRY:  lcd_data = CMD_ENTRY_MODE;
            LCD_ADDR:   lcd_data = lcd_addr_base + {4'b0000, lcd_index[3:0]};
            LCD_CHAR:   lcd_data = scan_lcd_byte;
            default:    lcd_data = CMD_FUNC_SET;
        endcase
    end

    always @(*) begin
        lcd_blon = 1'b0;
        lcd_on   = 1'b1;
        lcd_rw   = 1'b0;
        lcd_rs   = (lcd_state == LCD_CHAR);
        lcd_en   = (lcd_phase == 2'd2);
    end

    always @(*) begin
        core_rdata = 32'd0;
        if (lcd_status_sel) begin
            core_rdata = {29'd0, (lcd_phase == 2'd3), (lcd_state == LCD_ADDR), (lcd_state == LCD_CLEAR)};
        end else if (lcd_ctrl_sel) begin
            core_rdata = {26'd0, lcd_index, lcd_clear_req};
        end else if (lcd_text_sel) begin
            core_rdata = {24'd0, cpu_lcd_byte};
        end

        case (core_op)
            3'b000, 3'b100: core_rdata = {{24{core_rdata[7]}}, core_rdata[7:0]};
            3'b001, 3'b101: core_rdata = {{16{core_rdata[15]}}, core_rdata[15:0]};
            default: ;
        endcase
    end
endmodule

/**
 * PS/2 keyboard MMIO front-end. Raw scan-code bytes are buffered by the
 * receiver/FIFO and exposed through a small status/data register pair.
 *
 * @port clk        System clock
 * @port rst        Reset signal
 * @port core_addr  CPU/MMIO address
 * @port core_wdata CPU/MMIO write data
 * @port core_op    CPU load/store width selector
 * @port core_we    CPU write enable
 * @port ps2_clk    PS/2 clock input
 * @port ps2_dat    PS/2 data input
 * @port core_rdata MMIO readback word
 * @port mmio_hit   High when the keyboard MMIO window is selected
 */
module PS2_KEYBOARD_DRIVER(
    input         clk,
    input         rst,
    input  [31:0] core_addr,
    input  [31:0] core_wdata,
    input  [2:0]  core_op,
    input         core_we,
    input         ps2_clk,
    input         ps2_dat,
    output reg [31:0] core_rdata,
    output        mmio_hit
);
    wire kbd_page       = core_addr[31] && (core_addr[31:8] == 24'h800000);
    wire kbd_status_sel = kbd_page && (core_addr[7:0] == 8'h80);
    wire kbd_data_sel   = kbd_page && (core_addr[7:0] == 8'h84);
    wire kbd_read_level = kbd_data_sel && !core_we;
    reg  kbd_read_prev;
    wire kbd_pop        = kbd_read_level && !kbd_read_prev;
    wire kbd_overflow_clr = kbd_status_sel && core_we && core_wdata[1];
    wire [7:0] kbd_data_byte;
    wire kbd_ready;
    wire kbd_overflow;

    assign mmio_hit = kbd_status_sel || kbd_data_sel;

    PS2_KEYBOARD ps2_core(
        .clk(clk),
        .rst(rst),
        .ps2_clk(ps2_clk),
        .ps2_dat(ps2_dat),
        .pop(kbd_pop),
        .clr_overflow(kbd_overflow_clr),
        .data(kbd_data_byte),
        .ready(kbd_ready),
        .overflow(kbd_overflow)
    );

    // Turn a level-sensitive MMIO read of the keyboard data register into a
    // one-cycle FIFO pop pulse. This avoids dropping multiple bytes if the CPU
    // happens to expose the same read address across more than one cycle.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            kbd_read_prev <= 1'b0;
        end else begin
            kbd_read_prev <= kbd_read_level;
        end
    end

    always @(*) begin
        core_rdata = 32'd0;
        if (kbd_status_sel) core_rdata = {30'd0, kbd_overflow, kbd_ready};
        if (kbd_data_sel)   core_rdata = kbd_ready ? {24'd0, kbd_data_byte} : 32'd0;

        case (core_op)
            3'b000, 3'b100: core_rdata = {{24{core_rdata[7]}}, core_rdata[7:0]};
            3'b001, 3'b101: core_rdata = {{16{core_rdata[15]}}, core_rdata[15:0]};
            default: ;
        endcase
    end
endmodule

/**
 * PS/2 Keyboard Receiver
 * This component samples the PS/2 clock/data pair, assembles 11-bit PS/2
 * frames, and pushes valid scan-code bytes into a small FIFO for software.
 * The receiver:
 * - synchronizes the asynchronous PS/2 pins into the system clock domain
 * - samples data on synchronized falling edges of `ps2_clk`
 * - checks the frame start/stop bits before accepting a byte
 * - buffers received bytes so MMIO polling does not lose short bursts
 *
 * @port clk           System clock
 * @port rst           Reset signal
 * @port ps2_clk       PS/2 clock input
 * @port ps2_dat       PS/2 data input
 * @port pop           Pop one byte from the receive FIFO
 * @port clr_overflow  Clear the sticky overflow flag
 * @port data          Oldest buffered scan-code byte
 * @port ready         High when a byte is available
 * @port overflow      Sticky overflow flag
 */
module PS2_KEYBOARD(
    input       clk,
    input       rst,
    input       ps2_clk,
    input       ps2_dat,
    input       pop,
    input       clr_overflow,
    output [7:0] data,
    output      ready,
    output      overflow
);
    reg ps2_clk_meta, ps2_clk_sync, ps2_clk_prev;
    reg ps2_dat_meta, ps2_dat_sync;
    reg [3:0] bit_count;
    reg [10:0] frame_shift;

    wire ps2_fall       = ps2_clk_prev && !ps2_clk_sync;
    wire [10:0] next_shift = {ps2_dat_sync, frame_shift[10:1]};
    wire frame_done     = ps2_fall && (bit_count == 4'd10);
    wire frame_valid    = frame_done && !next_shift[0] && next_shift[10];
    wire [7:0] frame_byte = next_shift[8:1];

    BYTE_FIFO #(.capacity(2)) fifo(
        .clk(clk),
        .rst(rst),
        .push(frame_valid),
        .din(frame_byte),
        .pop(pop),
        .clr_overflow(clr_overflow),
        .dout(data),
        .ready(ready),
        .full(),
        .overflow(overflow)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ps2_clk_meta <= 1'b1;
            ps2_clk_sync <= 1'b1;
            ps2_clk_prev <= 1'b1;
            ps2_dat_meta <= 1'b1;
            ps2_dat_sync <= 1'b1;
        end else begin
            ps2_clk_meta <= ps2_clk;
            ps2_clk_sync <= ps2_clk_meta;
            ps2_clk_prev <= ps2_clk_sync;
            ps2_dat_meta <= ps2_dat;
            ps2_dat_sync <= ps2_dat_meta;
        end
    end

    // Shift one frame: start, 8 data bits (LSB-first), parity, stop.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bit_count    <= 4'd0;
            frame_shift  <= 11'd0;
        end else begin
            if (ps2_fall) begin
                frame_shift <= next_shift;
                if (frame_done) bit_count <= 4'd0;
                else            bit_count <= bit_count + 4'd1;
            end
        end
    end
endmodule

/**
 * Tiny byte FIFO used by the PS/2 front-end. Overflow is sticky until software
 * clears it through MMIO.
 *
 * @port clk           System clock
 * @port rst           Reset signal
 * @port push          Push a new byte into the FIFO
 * @port din           Input byte
 * @port pop           Pop the oldest byte
 * @port clr_overflow  Clear the sticky overflow flag
 * @port dout          Oldest buffered byte
 * @port ready         FIFO non-empty flag
 * @port full          FIFO full flag
 * @port overflow      Sticky overflow flag
 */
module BYTE_FIFO #(
    parameter capacity = 2
)(
    input        clk,
    input        rst,
    input        push,
    input  [7:0] din,
    input        pop,
    input        clr_overflow,
    output [7:0] dout,
    output       ready,
    output       full,
    output reg   overflow
);
    localparam DEPTH = (1 << capacity);

    reg [7:0] mem [0:DEPTH-1];
    reg [capacity-1:0] rd_ptr;
    reg [capacity-1:0] wr_ptr;
    reg [capacity:0]   count;
    integer i;

    wire push_ok = push && !full;
    wire pop_ok  = pop && ready;

    assign dout  = mem[rd_ptr];
    assign ready = (count != 0);
    assign full  = (count == DEPTH);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < DEPTH; i = i + 1) mem[i] <= 8'h00;
        end else if (push_ok) begin
            mem[wr_ptr] <= din;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_ptr <= {capacity{1'b0}};
            wr_ptr <= {capacity{1'b0}};
            count <= {(capacity+1){1'b0}};
        end else begin
            if (push_ok) begin
                wr_ptr <= wr_ptr + {{(capacity-1){1'b0}}, 1'b1};
            end
            if (pop_ok) begin
                rd_ptr <= rd_ptr + {{(capacity-1){1'b0}}, 1'b1};
            end
            case ({push_ok, pop_ok})
                2'b01: count <= count - {{capacity{1'b0}}, 1'b1};
                2'b10: count <= count + {{capacity{1'b0}}, 1'b1};
                default: ;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            overflow <= 1'b0;
        end else if (clr_overflow) begin
            overflow <= 1'b0;
        end else if (push && full) begin
            overflow <= 1'b1;
        end
    end
endmodule

/**
 * VGA text-mode display for a 16:9-friendly 88'h45 character surface.
 *
 * The physical output remains standard 648'h480@60Hz for monitor compatibility
 * from a 25 MHz pixel clock, but the visible content is rendered into a
 * centered 648'h360 window. That produces the right 16:9 geometry on widescreen
 * panels while staying within the board's simple clocking setup.
 *
 * MMIO / memory map:
 * - 8'h80000100: status register
 * - 8'h00018000..8'h00018E0F: CPU-writable text window mirrored by the wrapper
 *   for VGA scanout (88'h45 bytes, top-left first)
 *
 * @port clk         System clock
 * @port rst         Reset signal
 * @port core_addr   CPU/MMIO address
 * @port core_wdata  CPU/MMIO write data
 * @port core_op     CPU load/store width selector
 * @port core_we     CPU write enable
 * @port scan_char   Character byte fetched from video RAM
 * @port core_rdata  MMIO readback word
 * @port mmio_hit    High when the VGA MMIO status register is selected
 * @port scan_addr   Address into text/video RAM for the current cell
 * @port vga_r       VGA red channel
 * @port vga_g       VGA green channel
 * @port vga_b       VGA blue channel
 * @port vga_blank_n VGA blanking control
 * @port vga_clk     VGA pixel clock
 * @port vga_hs      VGA horizontal sync
 * @port vga_sync_n  VGA composite sync
 * @port vga_vs      VGA vertical sync
 */
module VGA_DRIVER(
    input         clk,
    input         rst,
    input  [31:0] core_addr,
    input  [31:0] core_wdata,
    input  [2:0]  core_op,
    input         core_we,
    input  [7:0]  scan_char,
    output reg [31:0] core_rdata,
    output        mmio_hit,
    output [11:0] scan_addr,
    output reg [7:0] vga_r,
    output reg [7:0] vga_g,
    output reg [7:0] vga_b,
    output reg       vga_blank_n,
    output           vga_clk,
    output reg       vga_hs,
    output reg       vga_sync_n,
    output reg       vga_vs
);
    reg pixel_clk;
    reg [9:0] h_count;
    reg [9:0] v_count;
    reg [7:0] scan_char_q;
    reg [2:0] glyph_col_q;
    reg [3:0] glyph_row_q;
    reg active_video_q;
    reg text_active_q;
    wire [7:0] glyph_row_bits;
    wire glyph_bit;

    wire vga_status_sel = core_addr[31] && (core_addr == 32'h80000100);
    wire active_video = (h_count < 10'd640) && (v_count < 10'd480);
    wire text_band = (v_count >= 10'd16) && (v_count < 10'd464);
    wire text_active = active_video && text_band;
    wire [9:0] text_y = v_count - 10'd16;
    wire [6:0] cell_x = h_count[9:3];
    wire [4:0] cell_y = text_y[8:4];
    wire [2:0] glyph_col = h_count[2:0];
    wire [3:0] glyph_row_sel = text_y[3:0];

    assign mmio_hit = vga_status_sel;
    assign scan_addr = {cell_y, 6'b000000} + {cell_y, 4'b0000} + cell_x;
    assign vga_clk = pixel_clk;
    assign glyph_bit = glyph_row_bits[glyph_col_q];

    VGA_GLYPH_ROW font_rom(
        .ch(scan_char_q),
        .row(glyph_row_q),
        .bits(glyph_row_bits)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pixel_clk <= 1'b0;
        end else begin
            pixel_clk <= ~pixel_clk;
        end
    end

    // Divide the 50 MHz board clock by two for the 25 MHz pixel pipeline.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
        end else if (!pixel_clk) begin
            if (h_count == 10'd799) begin
                h_count <= 10'd0;
                if (v_count == 10'd524) v_count <= 10'd0;
                else                    v_count <= v_count + 10'd1;
            end else begin
                h_count <= h_count + 10'd1;
            end
        end
    end

    // Align the scanned character byte with glyph row/column selectors so the
    // output stays free of sparkle artifacts.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            scan_char_q <= 8'h20;
            glyph_col_q <= 3'd0;
            glyph_row_q <= 4'd0;
            active_video_q <= 1'b0;
            text_active_q <= 1'b0;
        end else if (!pixel_clk) begin
            scan_char_q    <= scan_char;
            glyph_col_q    <= glyph_col;
            glyph_row_q    <= glyph_row_sel;
            active_video_q <= active_video;
            text_active_q  <= text_active;
        end
    end

    always @(*) begin
        vga_hs = ~((h_count >= 10'd656) && (h_count < 10'd752));
        vga_vs = ~((v_count >= 10'd490) && (v_count < 10'd492));
        vga_blank_n = active_video_q;
        vga_sync_n = 1'b0;
        if (text_active_q && glyph_bit) begin
            vga_r = 8'hff;
            vga_g = 8'hff;
            vga_b = 8'hff;
        end else if (active_video_q) begin
            vga_r = 8'h18;
            vga_g = 8'h18;
            vga_b = 8'h40;
        end else begin
            vga_r = 8'h00;
            vga_g = 8'h00;
            vga_b = 8'h00;
        end

        core_rdata = vga_status_sel ? 32'h000002d0 : 32'd0;
        case (core_op)
            3'b000, 3'b100: core_rdata = {{24{core_rdata[7]}}, core_rdata[7:0]};
            3'b001, 3'b101: core_rdata = {{16{core_rdata[15]}}, core_rdata[15:0]};
            default: ;
        endcase
    end
endmodule

/**
 * 8x16 character ROM used by the VGA text pipeline.
 *
 * The contents are initialized directly from Verilog source so the baseline
 * remains self-contained, mirroring how the font table lives inside fpga.nx.
 *
 * @port ch    Character code
 * @port row   Glyph row index
 * @port bits  8-bit glyph row bitmap
 */
module VGA_GLYPH_ROW(
    input  [7:0] ch,
    input  [3:0] row,
    output [7:0] bits
);
    reg [7:0] mem [0:255][0:15] = '{
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0000
        '{8'h00, 8'h00, 8'h7E, 8'h81, 8'hA5, 8'h81, 8'h81, 8'hBD, 8'h99, 8'h81, 8'h81, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0001
        '{8'h00, 8'h00, 8'h7E, 8'hFF, 8'hDB, 8'hFF, 8'hFF, 8'hC3, 8'hE7, 8'hFF, 8'hFF, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0002
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h6C, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'h7C, 8'h38, 8'h10, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0003
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h10, 8'h38, 8'h7C, 8'hFE, 8'h7C, 8'h38, 8'h10, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0004
        '{8'h00, 8'h00, 8'h00, 8'h18, 8'h3C, 8'h3C, 8'hE7, 8'hE7, 8'hE7, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0005
        '{8'h00, 8'h00, 8'h00, 8'h18, 8'h3C, 8'h7E, 8'hFF, 8'hFF, 8'h7E, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0006
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h3C, 8'h3C, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0007
        '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hE7, 8'hC3, 8'hC3, 8'hE7, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF}, // U+0008
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h3C, 8'h66, 8'h42, 8'h42, 8'h66, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0009
        '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hC3, 8'h99, 8'hBD, 8'hBD, 8'h99, 8'hC3, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF}, // U+000A
        '{8'h00, 8'h00, 8'h1E, 8'h0E, 8'h1A, 8'h32, 8'h78, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h78, 8'h00, 8'h00, 8'h00, 8'h00}, // U+000B
        '{8'h00, 8'h00, 8'h3C, 8'h66, 8'h66, 8'h66, 8'h66, 8'h3C, 8'h18, 8'h7E, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+000C
        '{8'h00, 8'h00, 8'h3F, 8'h33, 8'h3F, 8'h30, 8'h30, 8'h30, 8'h30, 8'h70, 8'hF0, 8'hE0, 8'h00, 8'h00, 8'h00, 8'h00}, // U+000D
        '{8'h00, 8'h00, 8'h7F, 8'h63, 8'h7F, 8'h63, 8'h63, 8'h63, 8'h63, 8'h67, 8'hE7, 8'hE6, 8'hC0, 8'h00, 8'h00, 8'h00}, // U+000E
        '{8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'hDB, 8'h3C, 8'hE7, 8'h3C, 8'hDB, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+000F
        '{8'h00, 8'h80, 8'hC0, 8'hE0, 8'hF0, 8'hF8, 8'hFE, 8'hF8, 8'hF0, 8'hE0, 8'hC0, 8'h80, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0010
        '{8'h00, 8'h02, 8'h06, 8'h0E, 8'h1E, 8'h3E, 8'hFE, 8'h3E, 8'h1E, 8'h0E, 8'h06, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0011
        '{8'h00, 8'h00, 8'h18, 8'h3C, 8'h7E, 8'h18, 8'h18, 8'h18, 8'h7E, 8'h3C, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0012
        '{8'h00, 8'h00, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h00, 8'h66, 8'h66, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0013
        '{8'h00, 8'h00, 8'h7F, 8'hDB, 8'hDB, 8'hDB, 8'h7B, 8'h1B, 8'h1B, 8'h1B, 8'h1B, 8'h1B, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0014
        '{8'h00, 8'h7C, 8'hC6, 8'h60, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'h6C, 8'h38, 8'h0C, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00}, // U+0015
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0016
        '{8'h00, 8'h00, 8'h18, 8'h3C, 8'h7E, 8'h18, 8'h18, 8'h18, 8'h7E, 8'h3C, 8'h18, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0017
        '{8'h00, 8'h00, 8'h18, 8'h3C, 8'h7E, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0018
        '{8'h00, 8'h00, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h7E, 8'h3C, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0019
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h0C, 8'hFE, 8'h0C, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+001A
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h30, 8'h60, 8'hFE, 8'h60, 8'h30, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+001B
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC0, 8'hC0, 8'hC0, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+001C
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h28, 8'h6C, 8'hFE, 8'h6C, 8'h28, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+001D
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h10, 8'h38, 8'h38, 8'h7C, 8'h7C, 8'hFE, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+001E
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'hFE, 8'h7C, 8'h7C, 8'h38, 8'h38, 8'h10, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+001F
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0020 ( )
        '{8'h00, 8'h00, 8'h18, 8'h3C, 8'h3C, 8'h3C, 8'h18, 8'h18, 8'h18, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0021 (!)
        '{8'h00, 8'h66, 8'h66, 8'h66, 8'h24, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0022 (")
        '{8'h00, 8'h00, 8'h00, 8'h6C, 8'h6C, 8'hFE, 8'h6C, 8'h6C, 8'h6C, 8'hFE, 8'h6C, 8'h6C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0023 (#)
        '{8'h18, 8'h18, 8'h7C, 8'hC6, 8'hC2, 8'hC0, 8'h7C, 8'h06, 8'h06, 8'h86, 8'hC6, 8'h7C, 8'h18, 8'h18, 8'h00, 8'h00}, // U+0024 ($)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'hC2, 8'hC6, 8'h0C, 8'h18, 8'h30, 8'h60, 8'hC6, 8'h86, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0025 (%)
        '{8'h00, 8'h00, 8'h38, 8'h6C, 8'h6C, 8'h38, 8'h76, 8'hDC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0026 (&)
        '{8'h00, 8'h30, 8'h30, 8'h30, 8'h60, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0027 (')
        '{8'h00, 8'h00, 8'h0C, 8'h18, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h18, 8'h0C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0028 (()
        '{8'h00, 8'h00, 8'h30, 8'h18, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h18, 8'h30, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0029 ())
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h66, 8'h3C, 8'hFF, 8'h3C, 8'h66, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+002A (*)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h7E, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+002B (+)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h18, 8'h30, 8'h00, 8'h00, 8'h00}, // U+002C (,)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+002D (-)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+002E (.)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h02, 8'h06, 8'h0C, 8'h18, 8'h30, 8'h60, 8'hC0, 8'h80, 8'h00, 8'h00, 8'h00, 8'h00}, // U+002F (/)
        '{8'h00, 8'h00, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'hD6, 8'hD6, 8'hC6, 8'hC6, 8'h6C, 8'h38, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0030 (0)
        '{8'h00, 8'h00, 8'h18, 8'h38, 8'h78, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0031 (1)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'h06, 8'h0C, 8'h18, 8'h30, 8'h60, 8'hC0, 8'hC6, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0032 (2)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'h06, 8'h06, 8'h3C, 8'h06, 8'h06, 8'h06, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0033 (3)
        '{8'h00, 8'h00, 8'h0C, 8'h1C, 8'h3C, 8'h6C, 8'hCC, 8'hFE, 8'h0C, 8'h0C, 8'h0C, 8'h1E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0034 (4)
        '{8'h00, 8'h00, 8'hFE, 8'hC0, 8'hC0, 8'hC0, 8'hFC, 8'h06, 8'h06, 8'h06, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0035 (5)
        '{8'h00, 8'h00, 8'h38, 8'h60, 8'hC0, 8'hC0, 8'hFC, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0036 (6)
        '{8'h00, 8'h00, 8'hFE, 8'hC6, 8'h06, 8'h06, 8'h0C, 8'h18, 8'h30, 8'h30, 8'h30, 8'h30, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0037 (7)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0038 (8)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'h7E, 8'h06, 8'h06, 8'h06, 8'h0C, 8'h78, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0039 (9)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+003A (:)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h30, 8'h00, 8'h00, 8'h00, 8'h00}, // U+003B (;)
        '{8'h00, 8'h00, 8'h00, 8'h06, 8'h0C, 8'h18, 8'h30, 8'h60, 8'h30, 8'h18, 8'h0C, 8'h06, 8'h00, 8'h00, 8'h00, 8'h00}, // U+003C (<)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7E, 8'h00, 8'h00, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+003D (=)
        '{8'h00, 8'h00, 8'h00, 8'h60, 8'h30, 8'h18, 8'h0C, 8'h06, 8'h0C, 8'h18, 8'h30, 8'h60, 8'h00, 8'h00, 8'h00, 8'h00}, // U+003E (>)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'h0C, 8'h18, 8'h18, 8'h18, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+003F (?)
        '{8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hDE, 8'hDE, 8'hDE, 8'hDC, 8'hC0, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0040 (@)
        '{8'h00, 8'h00, 8'h10, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'hFE, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0041 (A)
        '{8'h00, 8'h00, 8'hFC, 8'h66, 8'h66, 8'h66, 8'h7C, 8'h66, 8'h66, 8'h66, 8'h66, 8'hFC, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0042 (B)
        '{8'h00, 8'h00, 8'h3C, 8'h66, 8'hC2, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'hC2, 8'h66, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0043 (C)
        '{8'h00, 8'h00, 8'hF8, 8'h6C, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h6C, 8'hF8, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0044 (D)
        '{8'h00, 8'h00, 8'hFE, 8'h66, 8'h62, 8'h68, 8'h78, 8'h68, 8'h60, 8'h62, 8'h66, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0045 (E)
        '{8'h00, 8'h00, 8'hFE, 8'h66, 8'h62, 8'h68, 8'h78, 8'h68, 8'h60, 8'h60, 8'h60, 8'hF0, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0046 (F)
        '{8'h00, 8'h00, 8'h3C, 8'h66, 8'hC2, 8'hC0, 8'hC0, 8'hDE, 8'hC6, 8'hC6, 8'h66, 8'h3A, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0047 (G)
        '{8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hFE, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0048 (H)
        '{8'h00, 8'h00, 8'h3C, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0049 (I)
        '{8'h00, 8'h00, 8'h1E, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'hCC, 8'hCC, 8'hCC, 8'h78, 8'h00, 8'h00, 8'h00, 8'h00}, // U+004A (J)
        '{8'h00, 8'h00, 8'hE6, 8'h66, 8'h66, 8'h6C, 8'h78, 8'h78, 8'h6C, 8'h66, 8'h66, 8'hE6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+004B (K)
        '{8'h00, 8'h00, 8'hF0, 8'h60, 8'h60, 8'h60, 8'h60, 8'h60, 8'h60, 8'h62, 8'h66, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+004C (L)
        '{8'h00, 8'h00, 8'hC6, 8'hEE, 8'hFE, 8'hFE, 8'hD6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+004D (M)
        '{8'h00, 8'h00, 8'hC6, 8'hE6, 8'hF6, 8'hFE, 8'hDE, 8'hCE, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+004E (N)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+004F (O)
        '{8'h00, 8'h00, 8'hFC, 8'h66, 8'h66, 8'h66, 8'h7C, 8'h60, 8'h60, 8'h60, 8'h60, 8'hF0, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0050 (P)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hD6, 8'hDE, 8'h7C, 8'h0C, 8'h0E, 8'h00, 8'h00}, // U+0051 (Q)
        '{8'h00, 8'h00, 8'hFC, 8'h66, 8'h66, 8'h66, 8'h7C, 8'h6C, 8'h66, 8'h66, 8'h66, 8'hE6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0052 (R)
        '{8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'h60, 8'h38, 8'h0C, 8'h06, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0053 (S)
        '{8'h00, 8'h00, 8'h7E, 8'h7E, 8'h5A, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0054 (T)
        '{8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0055 (U)
        '{8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h6C, 8'h38, 8'h10, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0056 (V)
        '{8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hD6, 8'hD6, 8'hD6, 8'hFE, 8'hEE, 8'h6C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0057 (W)
        '{8'h00, 8'h00, 8'hC6, 8'hC6, 8'h6C, 8'h7C, 8'h38, 8'h38, 8'h7C, 8'h6C, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0058 (X)
        '{8'h00, 8'h00, 8'h66, 8'h66, 8'h66, 8'h66, 8'h3C, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0059 (Y)
        '{8'h00, 8'h00, 8'hFE, 8'hC6, 8'h86, 8'h0C, 8'h18, 8'h30, 8'h60, 8'hC2, 8'hC6, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+005A (Z)
        '{8'h00, 8'h00, 8'h3C, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+005B ([)
        '{8'h00, 8'h00, 8'h00, 8'h80, 8'hC0, 8'hE0, 8'h70, 8'h38, 8'h1C, 8'h0E, 8'h06, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00}, // U+005C (\)
        '{8'h00, 8'h00, 8'h3C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+005D (])
        '{8'h10, 8'h38, 8'h6C, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+005E (^)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h00, 8'h00}, // U+005F (_)
        '{8'h00, 8'h30, 8'h18, 8'h0C, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0060 (`)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h78, 8'h0C, 8'h7C, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0061 (a)
        '{8'h00, 8'h00, 8'hE0, 8'h60, 8'h60, 8'h78, 8'h6C, 8'h66, 8'h66, 8'h66, 8'h66, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0062 (b)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC0, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0063 (c)
        '{8'h00, 8'h00, 8'h1C, 8'h0C, 8'h0C, 8'h3C, 8'h6C, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0064 (d)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hFE, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0065 (e)
        '{8'h00, 8'h00, 8'h1C, 8'h36, 8'h32, 8'h30, 8'h78, 8'h30, 8'h30, 8'h30, 8'h30, 8'h78, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0066 (f)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h76, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h7C, 8'h0C, 8'hCC, 8'h78, 8'h00}, // U+0067 (g)
        '{8'h00, 8'h00, 8'hE0, 8'h60, 8'h60, 8'h6C, 8'h76, 8'h66, 8'h66, 8'h66, 8'h66, 8'hE6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0068 (h)
        '{8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h38, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0069 (i)
        '{8'h00, 8'h00, 8'h06, 8'h06, 8'h00, 8'h0E, 8'h06, 8'h06, 8'h06, 8'h06, 8'h06, 8'h06, 8'h66, 8'h66, 8'h3C, 8'h00}, // U+006A (j)
        '{8'h00, 8'h00, 8'hE0, 8'h60, 8'h60, 8'h66, 8'h6C, 8'h78, 8'h78, 8'h6C, 8'h66, 8'hE6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+006B (k)
        '{8'h00, 8'h00, 8'h38, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+006C (l)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hEC, 8'hFE, 8'hD6, 8'hD6, 8'hD6, 8'hD6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+006D (m)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hDC, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h00, 8'h00, 8'h00, 8'h00}, // U+006E (n)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+006F (o)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hDC, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h7C, 8'h60, 8'h60, 8'hF0, 8'h00}, // U+0070 (p)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h76, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h7C, 8'h0C, 8'h0C, 8'h1E, 8'h00}, // U+0071 (q)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hDC, 8'h76, 8'h66, 8'h60, 8'h60, 8'h60, 8'hF0, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0072 (r)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'h60, 8'h38, 8'h0C, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0073 (s)
        '{8'h00, 8'h00, 8'h10, 8'h30, 8'h30, 8'hFC, 8'h30, 8'h30, 8'h30, 8'h30, 8'h36, 8'h1C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0074 (t)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0075 (u)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h6C, 8'h38, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0076 (v)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC6, 8'hC6, 8'hD6, 8'hD6, 8'hD6, 8'hFE, 8'h6C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0077 (w)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC6, 8'h6C, 8'h38, 8'h38, 8'h38, 8'h6C, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0078 (x)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7E, 8'h06, 8'h0C, 8'hF8, 8'h00}, // U+0079 (y)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'hCC, 8'h18, 8'h30, 8'h60, 8'hC6, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+007A (z)
        '{8'h00, 8'h00, 8'h0E, 8'h18, 8'h18, 8'h18, 8'h70, 8'h18, 8'h18, 8'h18, 8'h18, 8'h0E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+007B ({)
        '{8'h00, 8'h00, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+007C (|)
        '{8'h00, 8'h00, 8'h70, 8'h18, 8'h18, 8'h18, 8'h0E, 8'h18, 8'h18, 8'h18, 8'h18, 8'h70, 8'h00, 8'h00, 8'h00, 8'h00}, // U+007D (})
        '{8'h00, 8'h76, 8'hDC, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+007E (~)
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h10, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'hC6, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+007F
        '{8'h00, 8'h00, 8'h3C, 8'h66, 8'hC2, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'hC2, 8'h66, 8'h3C, 8'h18, 8'h70, 8'h00, 8'h00}, // U+0080
        '{8'h00, 8'h00, 8'hCC, 8'h00, 8'h00, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0081
        '{8'h00, 8'h0C, 8'h18, 8'h30, 8'h00, 8'h7C, 8'hC6, 8'hFE, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0082
        '{8'h00, 8'h10, 8'h38, 8'h6C, 8'h00, 8'h78, 8'h0C, 8'h7C, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0083
        '{8'h00, 8'h00, 8'hCC, 8'h00, 8'h00, 8'h78, 8'h0C, 8'h7C, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0084
        '{8'h00, 8'h60, 8'h30, 8'h18, 8'h00, 8'h78, 8'h0C, 8'h7C, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0085
        '{8'h00, 8'h38, 8'h6C, 8'h38, 8'h00, 8'h78, 8'h0C, 8'h7C, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0086
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC0, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h18, 8'h70, 8'h00, 8'h00}, // U+0087
        '{8'h00, 8'h10, 8'h38, 8'h6C, 8'h00, 8'h7C, 8'hC6, 8'hFE, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0088
        '{8'h00, 8'h00, 8'hC6, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hFE, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0089
        '{8'h00, 8'h60, 8'h30, 8'h18, 8'h00, 8'h7C, 8'hC6, 8'hFE, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+008A
        '{8'h00, 8'h00, 8'h66, 8'h00, 8'h00, 8'h38, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+008B
        '{8'h00, 8'h18, 8'h3C, 8'h66, 8'h00, 8'h38, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+008C
        '{8'h00, 8'h60, 8'h30, 8'h18, 8'h00, 8'h38, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+008D
        '{8'h00, 8'hC6, 8'h00, 8'h10, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'hFE, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+008E
        '{8'h38, 8'h6C, 8'h38, 8'h10, 8'h38, 8'h6C, 8'hC6, 8'hFE, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+008F
        '{8'h0C, 8'h18, 8'h00, 8'hFE, 8'h66, 8'h62, 8'h68, 8'h78, 8'h68, 8'h62, 8'h66, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0090
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hEC, 8'h36, 8'h36, 8'h7E, 8'hD8, 8'hD8, 8'h6E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0091
        '{8'h00, 8'h00, 8'h3E, 8'h6C, 8'hCC, 8'hCC, 8'hFE, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0092
        '{8'h00, 8'h10, 8'h38, 8'h6C, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0093
        '{8'h00, 8'h00, 8'hC6, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0094
        '{8'h00, 8'h60, 8'h30, 8'h18, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0095
        '{8'h00, 8'h30, 8'h78, 8'hCC, 8'h00, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0096
        '{8'h00, 8'h60, 8'h30, 8'h18, 8'h00, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0097
        '{8'h00, 8'h00, 8'hC6, 8'h00, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7E, 8'h06, 8'h0C, 8'h78, 8'h00}, // U+0098
        '{8'h00, 8'hC6, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+0099
        '{8'h00, 8'hC6, 8'h00, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+009A
        '{8'h00, 8'h18, 8'h18, 8'h7C, 8'hC6, 8'hC0, 8'hC0, 8'hC0, 8'hC6, 8'h7C, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+009B
        '{8'h00, 8'h38, 8'h6C, 8'h64, 8'h60, 8'hF0, 8'h60, 8'h60, 8'h60, 8'h60, 8'hE6, 8'hFC, 8'h00, 8'h00, 8'h00, 8'h00}, // U+009C
        '{8'h00, 8'h00, 8'h66, 8'h66, 8'h3C, 8'h18, 8'h7E, 8'h18, 8'h7E, 8'h18, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+009D
        '{8'h00, 8'hF8, 8'hCC, 8'hCC, 8'hF8, 8'hC4, 8'hCC, 8'hDE, 8'hCC, 8'hCC, 8'hCC, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+009E
        '{8'h00, 8'h0E, 8'h1B, 8'h18, 8'h18, 8'h18, 8'h7E, 8'h18, 8'h18, 8'h18, 8'hD8, 8'h70, 8'h00, 8'h00, 8'h00, 8'h00}, // U+009F
        '{8'h00, 8'h18, 8'h30, 8'h60, 8'h00, 8'h78, 8'h0C, 8'h7C, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A0
        '{8'h00, 8'h0C, 8'h18, 8'h30, 8'h00, 8'h38, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A1
        '{8'h00, 8'h18, 8'h30, 8'h60, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A2
        '{8'h00, 8'h18, 8'h30, 8'h60, 8'h00, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'hCC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A3
        '{8'h00, 8'h00, 8'h76, 8'hDC, 8'h00, 8'hDC, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A4
        '{8'h76, 8'hDC, 8'h00, 8'hC6, 8'hE6, 8'hF6, 8'hFE, 8'hDE, 8'hCE, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A5
        '{8'h00, 8'h00, 8'h3C, 8'h6C, 8'h6C, 8'h3E, 8'h00, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A6
        '{8'h00, 8'h00, 8'h38, 8'h6C, 8'h6C, 8'h38, 8'h00, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A7
        '{8'h00, 8'h00, 8'h30, 8'h30, 8'h00, 8'h30, 8'h30, 8'h60, 8'hC0, 8'hC6, 8'hC6, 8'h7C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A8
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00A9
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'h06, 8'h06, 8'h06, 8'h06, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00AA
        '{8'h00, 8'h60, 8'hE0, 8'h62, 8'h66, 8'h6C, 8'h18, 8'h30, 8'h60, 8'hDC, 8'h86, 8'h0C, 8'h18, 8'h3E, 8'h00, 8'h00}, // U+00AB
        '{8'h00, 8'h60, 8'hE0, 8'h62, 8'h66, 8'h6C, 8'h18, 8'h30, 8'h66, 8'hCE, 8'h9A, 8'h3F, 8'h06, 8'h06, 8'h00, 8'h00}, // U+00AC
        '{8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h18, 8'h18, 8'h18, 8'h3C, 8'h3C, 8'h3C, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00AD
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h36, 8'h6C, 8'hD8, 8'h6C, 8'h36, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00AE
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hD8, 8'h6C, 8'h36, 8'h6C, 8'hD8, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00AF
        '{8'h11, 8'h44, 8'h11, 8'h44, 8'h11, 8'h44, 8'h11, 8'h44, 8'h11, 8'h44, 8'h11, 8'h44, 8'h11, 8'h44, 8'h11, 8'h44}, // U+00B0
        '{8'h55, 8'hAA, 8'h55, 8'hAA, 8'h55, 8'hAA, 8'h55, 8'hAA, 8'h55, 8'hAA, 8'h55, 8'hAA, 8'h55, 8'hAA, 8'h55, 8'hAA}, // U+00B1
        '{8'hDD, 8'h77, 8'hDD, 8'h77, 8'hDD, 8'h77, 8'hDD, 8'h77, 8'hDD, 8'h77, 8'hDD, 8'h77, 8'hDD, 8'h77, 8'hDD, 8'h77}, // U+00B2
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00B3
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hF8, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00B4
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hF8, 8'h18, 8'hF8, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00B5
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hF6, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00B6
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00B7
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hF8, 8'h18, 8'hF8, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00B8
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hF6, 8'h06, 8'hF6, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00B9
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00BA
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'h06, 8'hF6, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00BB
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hF6, 8'h06, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00BC
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00BD
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hF8, 8'h18, 8'hF8, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00BE
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hF8, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00BF
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h1F, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00C0
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00C1
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00C2
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h1F, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00C3
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00C4
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hFF, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00C5
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h1F, 8'h18, 8'h1F, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00C6
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h37, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00C7
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h37, 8'h30, 8'h3F, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00C8
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h3F, 8'h30, 8'h37, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00C9
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hF7, 8'h00, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00CA
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h00, 8'hF7, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00CB
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h37, 8'h30, 8'h37, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00CC
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h00, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00CD
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hF7, 8'h00, 8'hF7, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00CE
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hFF, 8'h00, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00CF
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00D0
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h00, 8'hFF, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00D1
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00D2
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h3F, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00D3
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h1F, 8'h18, 8'h1F, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00D4
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h1F, 8'h18, 8'h1F, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00D5
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h3F, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00D6
        '{8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'hFF, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36}, // U+00D7
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hFF, 8'h18, 8'hFF, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00D8
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hF8, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00D9
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h1F, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00DA
        '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF}, // U+00DB
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF}, // U+00DC
        '{8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF0}, // U+00DD
        '{8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F, 8'h0F}, // U+00DE
        '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00DF
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h76, 8'hDC, 8'hD8, 8'hD8, 8'hD8, 8'hDC, 8'h76, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E0
        '{8'h00, 8'h00, 8'h78, 8'hCC, 8'hCC, 8'hCC, 8'hD8, 8'hCC, 8'hC6, 8'hC6, 8'hC6, 8'hCC, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E1
        '{8'h00, 8'h00, 8'hFE, 8'hC6, 8'hC6, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'hC0, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E2
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'h6C, 8'h6C, 8'h6C, 8'h6C, 8'h6C, 8'h6C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E3
        '{8'h00, 8'h00, 8'hFE, 8'hC6, 8'h60, 8'h30, 8'h18, 8'h18, 8'h30, 8'h60, 8'hC6, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E4
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7E, 8'hD8, 8'hD8, 8'hD8, 8'hD8, 8'hD8, 8'h70, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E5
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h66, 8'h7C, 8'h60, 8'h60, 8'hC0, 8'h00}, // U+00E6
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h76, 8'hDC, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E7
        '{8'h00, 8'h00, 8'h7E, 8'h18, 8'h3C, 8'h66, 8'h66, 8'h66, 8'h66, 8'h3C, 8'h18, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E8
        '{8'h00, 8'h00, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'hFE, 8'hC6, 8'hC6, 8'hC6, 8'h6C, 8'h38, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00E9
        '{8'h00, 8'h00, 8'h38, 8'h6C, 8'hC6, 8'hC6, 8'hC6, 8'h6C, 8'h6C, 8'h6C, 8'h6C, 8'hEE, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00EA
        '{8'h00, 8'h00, 8'h1E, 8'h30, 8'h18, 8'h0C, 8'h3E, 8'h66, 8'h66, 8'h66, 8'h66, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00EB
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h7E, 8'hDB, 8'hDB, 8'hDB, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00EC
        '{8'h00, 8'h00, 8'h00, 8'h03, 8'h06, 8'h7E, 8'hDB, 8'hDB, 8'hF3, 8'h7E, 8'h60, 8'hC0, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00ED
        '{8'h00, 8'h00, 8'h1C, 8'h30, 8'h60, 8'h60, 8'h7C, 8'h60, 8'h60, 8'h60, 8'h30, 8'h1C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00EE
        '{8'h00, 8'h00, 8'h00, 8'h7C, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'hC6, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00EF
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'hFE, 8'h00, 8'h00, 8'hFE, 8'h00, 8'h00, 8'hFE, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F0
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h7E, 8'h18, 8'h18, 8'h00, 8'h00, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F1
        '{8'h00, 8'h00, 8'h00, 8'h30, 8'h18, 8'h0C, 8'h06, 8'h0C, 8'h18, 8'h30, 8'h00, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F2
        '{8'h00, 8'h00, 8'h00, 8'h0C, 8'h18, 8'h30, 8'h60, 8'h30, 8'h18, 8'h0C, 8'h00, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F3
        '{8'h00, 8'h00, 8'h0E, 8'h1B, 8'h1B, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18}, // U+00F4
        '{8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'h18, 8'hD8, 8'hD8, 8'hD8, 8'h70, 8'h00, 8'h00, 8'h00}, // U+00F5
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h00, 8'h7E, 8'h00, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F6
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h76, 8'hDC, 8'h00, 8'h76, 8'hDC, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F7
        '{8'h00, 8'h38, 8'h6C, 8'h6C, 8'h38, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F8
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00F9
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h18, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00FA
        '{8'h00, 8'h0F, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'h0C, 8'hEC, 8'h6C, 8'h6C, 8'h3C, 8'h1C, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00FB
        '{8'h00, 8'h6C, 8'h36, 8'h36, 8'h36, 8'h36, 8'h36, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00FC
        '{8'h00, 8'h3C, 8'h66, 8'h0C, 8'h18, 8'h32, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00FD
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h7E, 8'h7E, 8'h7E, 8'h7E, 8'h7E, 8'h7E, 8'h7E, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, // U+00FE
        '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}  // U+00FF
    };
    
    assign bits = mem[ch][row];
endmodule
