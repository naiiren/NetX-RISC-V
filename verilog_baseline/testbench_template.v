module testbench;
    localparam [31:0] MAGIC_INSTR = 32'hDEAD10CC;
    reg clock;
    reg reset;
    wire [31:0] imem_addr;
    wire [31:0] instr;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_out;
    wire [31:0] dmem_in;
    wire [2:0] dmem_op;
    wire dmem_wr;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5, hex6, hex7;
    
    // Instantiate the core
    CORE dut (
        .clk(clock),
        .rst(reset),
        .instr(instr),
        .dmem_out(dmem_out),
        .imem_addr(imem_addr),
        .dmem_addr(dmem_addr),
        .dmem_in(dmem_in),
        .dmem_op(dmem_op),
        .dmem_wr(dmem_wr),
        .HEX0(hex0),
        .HEX1(hex1),
        .HEX2(hex2),
        .HEX3(hex3),
        .HEX4(hex4),
        .HEX5(hex5),
        .HEX6(hex6),
        .HEX7(hex7)
    );
    
    // Instantiate instruction memory module
    imem imem_inst (
        .clk(~clock),
        .addr(imem_addr),
        .dataout(instr)
    );
    
    // Instantiate data memory module
    dmem dmem_inst (
        .clk(~clock),
        .wrclk(~clock),
        .addr(dmem_addr),
        .datain(dmem_in),
        .dataout(dmem_out),
        .op(dmem_op),
        .we(dmem_wr)
    );
    
    // Clock generation
    initial begin
        clock = 0;
        forever #5 clock = ~clock;
    end
    
    // Test control
    initial begin
        $write("Running test case: {{TEST_NAME}}");
        $fflush;
        reset = 1'b1;
        @(posedge clock);
        @(negedge clock);
        reset = 1'b0;
        finished_seen = 0;
        drain_cycles = 0;
    end

    reg [31:0] fetched_instr, x10;
    reg finished_seen;
    integer drain_cycles;
    integer cycle = 0;
    always @(posedge clock) begin
        fetched_instr = dut.ifid_instr;
        x10 = dut.myregfile.regs[10];
        cycle = cycle + 1;
        // $display("[cycle %4d] PC=0x%08x INSTR=0x%08x", cycle, imem_addr, fetched_instr);
        // $fflush;
        if (!finished_seen && dut.ifid_valid && (fetched_instr == MAGIC_INSTR)) begin
            finished_seen <= 1'b1;
            drain_cycles <= 128;
        end else if (finished_seen) begin
            drain_cycles <= drain_cycles - 1;
        end

        if (finished_seen && drain_cycles == 0) begin
            if (x10 == 32'h00C0FFEE) begin
                $display("\t-> \033[32mPassed!\033[0m");
                $finish;
            end else begin
                $display("\t-> \033[31mFailed!\033[0m (x10=0x%08x, expected 0x00C0FFEE)", x10);
                $finish;
            end
        end
    end
endmodule

// Instruction Memory Module
module imem (
    input clk,
    input [31:0] addr,
    output reg [31:0] dataout
);
    reg [31:0] mem [0:8191];  // 32KB instruction memory
    integer i;
    
    initial begin
        // Initialize memory to zero
        for (i = 0; i < 8192; i = i + 1) begin
            mem[i] = 32'h00000000;
        end
        
        // Load instruction memory
        $readmemh("{{HEX_FILE}}", mem);
    end
    
    // Instruction memory read
    always @(posedge clk) begin
        dataout = mem[addr[14:2]];
    end
endmodule

// Data Memory Module
module dmem (
    input clk,
    input wrclk,
    input [31:0] addr,
    input [31:0] datain,
    output reg [31:0] dataout,
    input [2:0] op,
    input we
);
    reg [31:0] mem [0:8191];  // 32KB data memory
    integer i;
    
    initial begin
        // Initialize memory to zero
        for (i = 0; i < 8192; i = i + 1) begin
            mem[i] = 32'h00000000;
        end
        
        // Load data memory if provided
        $readmemh("{{DATA_FILE}}", mem, 0, 8191);
    end
    
    // Data memory read output
    reg [31:0] read_data;
    always @(posedge clk) begin
        if (!we) begin
            read_data = mem[addr[14:2]];
            case (op)
                3'b000: begin // LB - load byte with sign extension
                    case (addr[1:0])
                        2'b00: dataout <= {{24{read_data[7]}}, read_data[7:0]};
                        2'b01: dataout <= {{24{read_data[15]}}, read_data[15:8]};
                        2'b10: dataout <= {{24{read_data[23]}}, read_data[23:16]};
                        2'b11: dataout <= {{24{read_data[31]}}, read_data[31:24]};
                    endcase
                end
                3'b001: begin // LH - load halfword with sign extension
                    case (addr[1])
                        1'b0: dataout <= {{16{read_data[15]}}, read_data[15:0]};
                        1'b1: dataout <= {{16{read_data[31]}}, read_data[31:16]};
                    endcase
                end
                3'b010: dataout <= read_data; // LW - load word
                3'b100: begin // LBU - load byte unsigned
                    case (addr[1:0])
                        2'b00: dataout <= {{24'b0, read_data[7:0]}};
                        2'b01: dataout <= {{24'b0, read_data[15:8]}};
                        2'b10: dataout <= {{24'b0, read_data[23:16]}};
                        2'b11: dataout <= {{24'b0, read_data[31:24]}};
                    endcase
                end
                3'b101: begin // LHU - load halfword unsigned
                    case (addr[1])
                        1'b0: dataout <= {{16'b0, read_data[15:0]}};
                        1'b1: dataout <= {{16'b0, read_data[31:16]}};
                    endcase
                end
                default: dataout <= read_data;
            endcase
        end
    end
    
    // Data memory write logic
    always @(posedge wrclk) begin
        if (we) begin
            case (op)
                3'b000: begin // SB - store byte
                    case (addr[1:0])
                        2'b00: mem[addr[14:2]][7:0]   <= datain[7:0];
                        2'b01: mem[addr[14:2]][15:8]  <= datain[7:0];
                        2'b10: mem[addr[14:2]][23:16] <= datain[7:0];
                        2'b11: mem[addr[14:2]][31:24] <= datain[7:0];
                    endcase
                end
                3'b001: begin // SH - store halfword
                    case (addr[1])
                        1'b0: mem[addr[14:2]][15:0]  <= datain[15:0];
                        1'b1: mem[addr[14:2]][31:16] <= datain[15:0];
                    endcase
                end
                3'b010: mem[addr[14:2]] <= datain; // SW - store word
                default: mem[addr[14:2]] <= datain;
            endcase
        end
    end
endmodule
