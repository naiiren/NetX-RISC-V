/**
 * RV32I Core
 *
 * This component implements a 5-stage pipelined RV32I core with basic branch prediction and bypassing.
 * It interfaces with external instruction and data memory and includes a simple control path for handling hazards and redirects.
 * The design includes the following pipeline stages:
 * - IF: Instruction fetch with PC generation and branch prediction.
 * - ID: Instruction decode, register read, and decode-time branch prediction.
 * - EX: ALU execution and branch resolution.
 * - MEM: Data memory access.
 * - WB: Register file writeback.
 *
 * @port clk         Clock signal
 * @port rst         Reset signal
 * @port instr       Instruction input from instruction memory
 * @port dmem_out    Data output from data memory
 * @port imem_addr   Address output to instruction memory
 * @port dmem_addr   Address output to data memory
 * @port dmem_in     Data input to data memory
 * @port dmem_op     Memory operation code output to data memory
 * @port dmem_wr     Data memory write enable output
 * @port HEX0        Seven-segment digit 0
 * @port HEX1        Seven-segment digit 1
 * @port HEX2        Seven-segment digit 2
 * @port HEX3        Seven-segment digit 3
 * @port HEX4        Seven-segment digit 4
 * @port HEX5        Seven-segment digit 5
 * @port HEX6        Seven-segment digit 6
 * @port HEX7        Seven-segment digit 7
 */
module CORE(
  input         clk,
  input         rst,
  input  [31:0] instr,
  input  [31:0] dmem_out,
  output [31:0] imem_addr,
  output [31:0] dmem_addr,
  output [31:0] dmem_in,
  output [2:0]  dmem_op,
  output        dmem_wr,
  output [6:0]  HEX0,
  output [6:0]  HEX1,
  output [6:0]  HEX2,
  output [6:0]  HEX3,
  output [6:0]  HEX4,
  output [6:0]  HEX5,
  output [6:0]  HEX6,
  output [6:0]  HEX7
);

localparam [31:0] NOP = 32'h00000013;

reg [31:0] PC;
wire [31:0] pc_plus4 = PC + 32'd4;

// Pipeline registers. Keeping the stage boundaries explicit makes the
// forwarding, stalling, and redirect logic easier to line up with the NetX
// implementation and with timing reports.
reg         ifid_valid;
reg [31:0]  ifid_pc;
reg [31:0]  ifid_instr;

reg         idex_valid;
reg [31:0]  idex_pc;
reg         idex_pred_taken;
reg [31:0]  idex_pred_target;
reg [31:0]  idex_ra;
reg [31:0]  idex_rb;
reg [31:0]  idex_imm;
reg [4:0]   idex_rs1;
reg [4:0]   idex_rs2;
reg [4:0]   idex_rd;
reg         idex_reg_wr;
reg [2:0]   idex_branch;
reg         idex_mem_to_reg;
reg         idex_mem_wr;
reg [2:0]   idex_mem_op;
reg         idex_a_src;
reg [1:0]   idex_b_src;
reg [3:0]   idex_alu_ctr;

reg         exmem_valid;
reg [31:0]  exmem_result;
reg [31:0]  exmem_store_data;
reg [4:0]   exmem_rd;
reg         exmem_reg_wr;
reg         exmem_mem_to_reg;
reg         exmem_mem_wr;
reg [2:0]   exmem_mem_op;

reg         memwb_valid;
reg [31:0]  memwb_result;
reg [31:0]  memwb_mem_data;
reg [4:0]   memwb_rd;
reg         memwb_reg_wr;
reg         memwb_mem_to_reg;

wire [31:0] wb_result = memwb_mem_to_reg ? memwb_mem_data : memwb_result;

wire [31:0] id_instr = ifid_instr;
wire [6:0]  id_op = id_instr[6:0];
wire [2:0]  id_func3 = id_instr[14:12];
wire [6:0]  id_func7 = id_instr[31:25];
wire [4:0]  id_rs1 = id_instr[19:15];
wire [4:0]  id_rs2 = id_instr[24:20];
wire [4:0]  id_rd = id_instr[11:7];

wire [2:0] id_ext_op;
wire       id_reg_wr;
wire [2:0] id_branch;
wire       id_mem_to_reg;
wire       id_mem_wr;
wire [2:0] id_mem_op;
wire       id_a_src;
wire [1:0] id_b_src;
wire [3:0] id_alu_ctr;
wire       id_rs1_used;
wire       id_rs2_used;

INSTR_DECODER instrDecoder(
  .op_i(id_op),
  .func3(id_func3),
  .func7(id_func7[5]),
  .ExtOP(id_ext_op),
  .RegWr(id_reg_wr),
  .Rs1Used(id_rs1_used),
  .Rs2Used(id_rs2_used),
  .Branch(id_branch),
  .MemtoReg(id_mem_to_reg),
  .MemWr(id_mem_wr),
  .MemOP(id_mem_op),
  .ALUAsrc(id_a_src),
  .ALUBsrc(id_b_src),
  .ALUctr(id_alu_ctr)
);

wire [31:0] id_imm;
IMM_SELECTOR immSelector(
  .ext_op(id_ext_op),
  .instr(id_instr),
  .imm(id_imm)
);

wire [31:0] rf_busA;
wire [31:0] rf_busB;
wire [31:0] x10;
REG_FILE myregfile(
  .clk(clk),
  .rst(rst),
  .rd_addr_a(id_rs1),
  .rd_addr_b(id_rs2),
  .wr_addr(memwb_rd),
  .wr_en(memwb_valid && memwb_reg_wr),
  .din(wb_result),
  .dout_a(rf_busA),
  .dout_b(rf_busB),
  .x10(x10)
);

// Decode-stage bypassing matches the NetX core: values can come from either
// EX/MEM or MEM/WB before the instruction is admitted into ID/EX.
wire exmem_fwd_ok = exmem_valid && exmem_reg_wr && (exmem_rd != 5'd0) && !exmem_mem_to_reg;
wire memwb_fwd_ok = memwb_valid && memwb_reg_wr && (memwb_rd != 5'd0);

wire exmem_bypass_rs1 = exmem_fwd_ok && id_rs1_used && (exmem_rd == id_rs1);
wire exmem_bypass_rs2 = exmem_fwd_ok && id_rs2_used && (exmem_rd == id_rs2);
wire wb_bypass_rs1    = memwb_fwd_ok && id_rs1_used && (memwb_rd == id_rs1);
wire wb_bypass_rs2    = memwb_fwd_ok && id_rs2_used && (memwb_rd == id_rs2);

wire [31:0] id_ra_eff = exmem_bypass_rs1 ? exmem_result : (wb_bypass_rs1 ? wb_result : rf_busA);
wire [31:0] id_rb_eff = exmem_bypass_rs2 ? exmem_result : (wb_bypass_rs2 ? wb_result : rf_busB);

wire [31:0] pred_target;
wire        pred_taken;
wire [31:0] id_jump_target = pred_target;
BRANCH_PREDICTOR predictor(
  .clk(clk),
  .rst(rst),
  .valid(ifid_valid),
  .branch(id_branch),
  .pc(ifid_pc),
  .imm(id_imm),
  .update_valid(idex_valid),
  .update_branch(idex_branch),
  .update_pc(idex_pc),
  .update_taken(ex_actual_taken),
  .update_target(ex_branch_target),
  .pred_taken(pred_taken),
  .pred_target(pred_target)
);

// Control-flow instructions are held back until their operands are stable.
// This keeps branch/jump redirect decisions out of the general ALU-forwarding
// cone, mirroring the cleaned-up NetX version.
wire id_is_ctrl_flow = |id_branch;
wire idex_has_rd = idex_valid && idex_reg_wr && (idex_rd != 5'd0);
wire exmem_load_has_rd = exmem_valid && exmem_mem_to_reg && (exmem_rd != 5'd0);

wire ctrl_dep_rs1 = idex_has_rd && id_rs1_used && (idex_rd == id_rs1);
wire ctrl_dep_rs2 = idex_has_rd && id_rs2_used && (idex_rd == id_rs2);
wire ctrl_wait_exmem_rs1 = exmem_load_has_rd && id_rs1_used && (exmem_rd == id_rs1);
wire ctrl_wait_exmem_rs2 = exmem_load_has_rd && id_rs2_used && (exmem_rd == id_rs2);
wire ctrl_flow_stall = ifid_valid && id_is_ctrl_flow &&
                       (ctrl_dep_rs1 || ctrl_dep_rs2 || ctrl_wait_exmem_rs1 || ctrl_wait_exmem_rs2);

wire load_use_rs1 = id_rs1_used && (idex_rd != 5'd0) && (idex_rd == id_rs1);
wire load_use_rs2 = id_rs2_used && (idex_rd != 5'd0) && (idex_rd == id_rs2);
wire load_use_stall = ifid_valid && idex_valid && idex_mem_to_reg && (load_use_rs1 || load_use_rs2);

wire front_stall = load_use_stall || ctrl_flow_stall;
wire id_redirect = pred_taken;
wire id_redirect_eff = id_redirect && !front_stall;

wire fwd_rs1_from_exmem = exmem_fwd_ok && (exmem_rd == idex_rs1);
wire fwd_rs2_from_exmem = exmem_fwd_ok && (exmem_rd == idex_rs2);
wire fwd_rs1_from_memwb = memwb_fwd_ok && (memwb_rd == idex_rs1);
wire fwd_rs2_from_memwb = memwb_fwd_ok && (memwb_rd == idex_rs2);

wire [31:0] ex_ra_fwd = fwd_rs1_from_exmem ? exmem_result : (fwd_rs1_from_memwb ? wb_result : idex_ra);
wire [31:0] ex_rb_fwd = fwd_rs2_from_exmem ? exmem_result : (fwd_rs2_from_memwb ? wb_result : idex_rb);

wire [31:0] ex_alu_a = idex_a_src ? idex_pc : ex_ra_fwd;
wire [31:0] ex_alu_b = (idex_b_src == 2'b00) ? ex_rb_fwd :
                       (idex_b_src == 2'b01) ? idex_imm :
                                               32'd4;
wire [31:0] ex_result;
wire ex_zero;
wire ex_less;
ALU alu_u(
  .a(ex_alu_a),
  .b(ex_alu_b),
  .alu_ctl(idex_alu_ctr),
  .result(ex_result),
  .zero(ex_zero),
  .less(ex_less)
);

wire ex_ctrl_eq;
wire ex_ctrl_ltu;
wire ex_ctrl_lts;
BRANCH_COMPARE branchCompare(
  .a(idex_ra),
  .b(idex_rb),
  .eq(ex_ctrl_eq),
  .ltu(ex_ctrl_ltu),
  .lts(ex_ctrl_lts)
);

wire ex_is_jal  = (idex_branch == 3'b001);
wire ex_is_jalr = (idex_branch == 3'b010);
wire ex_is_cond = idex_branch[2];
wire ex_cond_taken = (idex_branch[1:0] == 2'b00) ? ex_ctrl_eq :
                     (idex_branch[1:0] == 2'b01) ? ~ex_ctrl_eq :
                     (idex_branch[1:0] == 2'b10) ? (idex_branch[0] ? ex_ctrl_ltu : ex_ctrl_lts) :
                                                    ~(idex_branch[0] ? ex_ctrl_ltu : ex_ctrl_lts);
wire ex_actual_taken = ex_is_jal || ex_is_jalr || (ex_is_cond && ex_cond_taken);
wire [31:0] ex_branch_base = ex_is_jalr ? idex_ra : idex_pc;
wire [31:0] ex_branch_target = ex_branch_base + idex_imm;
wire [31:0] ex_fallthrough_pc = idex_pc + 32'd4;
wire [31:0] ex_correct_pc = ex_actual_taken ? ex_branch_target : ex_fallthrough_pc;
wire [31:0] ex_predicted_pc = idex_pred_taken ? idex_pred_target : ex_fallthrough_pc;
wire ex_redirect = idex_valid && (ex_predicted_pc != ex_correct_pc);
reg ex_flush;
wire redirect_flush = id_redirect_eff || ex_redirect;
wire if_flush = redirect_flush || ex_flush;
wire idex_flush = front_stall || ex_redirect || ex_flush;
wire [31:0] next_fetch_pc = front_stall ? PC :
                            ex_redirect ? ex_correct_pc :
                            id_redirect_eff ? pred_target :
                            pc_plus4;

wire [6:0] ssd0;
wire [6:0] ssd1;
wire [6:0] ssd2;
wire [6:0] ssd3;
wire [6:0] ssd4;
wire [6:0] ssd5;
wire [6:0] ssd6;
wire [6:0] ssd7;

assign imem_addr = rst ? 32'd0 : PC;
assign dmem_addr = exmem_valid ? exmem_result : 32'd0;
assign dmem_in = exmem_valid ? exmem_store_data : 32'd0;
assign dmem_op = exmem_valid ? exmem_mem_op : 3'b010;
assign dmem_wr = exmem_valid && exmem_mem_wr;
assign HEX0 = ssd0;
assign HEX1 = ssd1;
assign HEX2 = ssd2;
assign HEX3 = ssd3;
assign HEX4 = ssd4;
assign HEX5 = ssd5;
assign HEX6 = ssd6;
assign HEX7 = ssd7;

HEX_TO_7SEG hex0(.num(x10[3:0]),   .code(ssd0));
HEX_TO_7SEG hex1(.num(x10[7:4]),   .code(ssd1));
HEX_TO_7SEG hex2(.num(x10[11:8]),  .code(ssd2));
HEX_TO_7SEG hex3(.num(x10[15:12]), .code(ssd3));
HEX_TO_7SEG hex4(.num(x10[19:16]), .code(ssd4));
HEX_TO_7SEG hex5(.num(x10[23:20]), .code(ssd5));
HEX_TO_7SEG hex6(.num(x10[27:24]), .code(ssd6));
HEX_TO_7SEG hex7(.num(x10[31:28]), .code(ssd7));

always @(posedge clk) begin
  if (rst) begin
    PC <= 32'd0;
    ex_flush <= 1'b0;
  end else begin
    PC <= next_fetch_pc;
    ex_flush <= redirect_flush;
  end
end

always @(posedge clk) begin
  if (rst) begin
    memwb_valid <= 1'b0;
    memwb_result <= 32'd0;
    memwb_mem_data <= 32'd0;
    memwb_rd <= 5'd0;
    memwb_reg_wr <= 1'b0;
    memwb_mem_to_reg <= 1'b0;
  end else begin
    memwb_valid <= exmem_valid;
    memwb_result <= exmem_result;
    memwb_mem_data <= dmem_out;
    memwb_rd <= exmem_rd;
    memwb_reg_wr <= exmem_reg_wr;
    memwb_mem_to_reg <= exmem_mem_to_reg;
  end
end

always @(posedge clk) begin
  if (rst) begin
    exmem_valid <= 1'b0;
    exmem_result <= 32'd0;
    exmem_store_data <= 32'd0;
    exmem_rd <= 5'd0;
    exmem_reg_wr <= 1'b0;
    exmem_mem_to_reg <= 1'b0;
    exmem_mem_wr <= 1'b0;
    exmem_mem_op <= 3'b010;
  end else begin
    exmem_valid <= idex_valid;
    exmem_result <= ex_result;
    exmem_store_data <= ex_rb_fwd;
    exmem_rd <= idex_rd;
    exmem_reg_wr <= idex_reg_wr;
    exmem_mem_to_reg <= idex_mem_to_reg;
    exmem_mem_wr <= idex_mem_wr;
    exmem_mem_op <= idex_mem_op;
  end
end

always @(posedge clk) begin
  if (rst) begin
    idex_valid <= 1'b0;
    idex_pc <= 32'd0;
    idex_pred_taken <= 1'b0;
    idex_pred_target <= 32'd0;
    idex_ra <= 32'd0;
    idex_rb <= 32'd0;
    idex_imm <= 32'd0;
    idex_rs1 <= 5'd0;
    idex_rs2 <= 5'd0;
    idex_rd <= 5'd0;
    idex_reg_wr <= 1'b0;
    idex_branch <= 3'b000;
    idex_mem_to_reg <= 1'b0;
    idex_mem_wr <= 1'b0;
    idex_mem_op <= 3'b010;
    idex_a_src <= 1'b0;
    idex_b_src <= 2'b00;
    idex_alu_ctr <= 4'b0000;
  end else if (idex_flush) begin
    idex_valid <= 1'b0;
    idex_pc <= 32'd0;
    idex_pred_taken <= 1'b0;
    idex_pred_target <= 32'd0;
    idex_ra <= 32'd0;
    idex_rb <= 32'd0;
    idex_imm <= 32'd0;
    idex_rs1 <= 5'd0;
    idex_rs2 <= 5'd0;
    idex_rd <= 5'd0;
    idex_reg_wr <= 1'b0;
    idex_branch <= 3'b000;
    idex_mem_to_reg <= 1'b0;
    idex_mem_wr <= 1'b0;
    idex_mem_op <= 3'b010;
    idex_a_src <= 1'b0;
    idex_b_src <= 2'b00;
    idex_alu_ctr <= 4'b0000;
  end else begin
    idex_valid <= ifid_valid;
    idex_pc <= ifid_pc;
    idex_pred_taken <= id_redirect_eff;
    idex_pred_target <= id_jump_target;
    idex_ra <= id_ra_eff;
    idex_rb <= id_rb_eff;
    idex_imm <= id_imm;
    idex_rs1 <= id_rs1;
    idex_rs2 <= id_rs2;
    idex_rd <= id_rd;
    idex_reg_wr <= id_reg_wr;
    idex_branch <= id_branch;
    idex_mem_to_reg <= id_mem_to_reg;
    idex_mem_wr <= id_mem_wr;
    idex_mem_op <= id_mem_op;
    idex_a_src <= id_a_src;
    idex_b_src <= id_b_src;
    idex_alu_ctr <= id_alu_ctr;
  end
end

always @(posedge clk) begin
  if (rst) begin
    ifid_valid <= 1'b0;
    ifid_pc <= 32'd0;
    ifid_instr <= NOP;
  end else if (!front_stall) begin
    ifid_valid <= !if_flush;
    ifid_pc <= PC - 32'd4;
    ifid_instr <= instr;
  end
end
endmodule

/**
 * Seven-segment decoder used by the baseline core to expose the debug word in
 * the same style as the NetX CPU.
 *
 * @port num   4-bit input nibble
 * @port code  Active-low seven-segment output
 */
module HEX_TO_7SEG(
    input  [3:0] num,
    output reg [6:0] code
);
always @(*) begin
    case (num)
        4'h0: code = 7'b1000000;
        4'h1: code = 7'b1111001;
        4'h2: code = 7'b0100100;
        4'h3: code = 7'b0110000;
        4'h4: code = 7'b0011001;
        4'h5: code = 7'b0010010;
        4'h6: code = 7'b0000010;
        4'h7: code = 7'b1111000;
        4'h8: code = 7'b0000000;
        4'h9: code = 7'b0010000;
        4'hA: code = 7'b0001000;
        4'hB: code = 7'b0000011;
        4'hC: code = 7'b1000110;
        4'hD: code = 7'b0100001;
        4'hE: code = 7'b0000110;
        4'hF: code = 7'b0001110;
    endcase
end
endmodule

/**
 * Instruction decoder for the baseline RV32I core.
 *
 * This block expands the opcode / funct fields into the same control bundle
 * used by the NetX core: immediate selection, branch class, memory controls,
 * ALU source selects, and ALU operation.
 *
 * @port op        Instruction opcode
 * @port func3     Instruction funct3 field
 * @port func7     Bit 30 / funct7-derived selector for ALU decode
 * @port ExtOP     Immediate-format selector
 * @port RegWr     Register write enable
 * @port Rs1Used   Whether rs1 is consumed by the instruction
 * @port Rs2Used   Whether rs2 is consumed by the instruction
 * @port Branch    Encoded branch/jump class
 * @port MemtoReg  Select load result for writeback
 * @port MemWr     Store enable
 * @port MemOP     Load/store width selector
 * @port ALUAsrc   Select PC vs register for ALU operand A
 * @port ALUBsrc   Select register / immediate / 4 for ALU operand B
 * @port ALUctr    Encoded ALU operation
 */
module INSTR_DECODER(
  input [6:0] op_i,
  input [2:0] func3,
  input       func7,
  output [2:0] ExtOP,
  output      RegWr,
  output      Rs1Used,
  output      Rs2Used,
  output [2:0] Branch,
  output      MemtoReg,
  output      MemWr,
  output [2:0] MemOP,
  output      ALUAsrc,
  output [1:0] ALUBsrc,
  output [3:0] ALUctr
);

reg [20:0] dec;
assign {ExtOP, RegWr, Rs1Used, Rs2Used, Branch, MemtoReg, MemWr, MemOP, ALUAsrc, ALUBsrc, ALUctr} = dec;

always @(*) begin
  dec = 21'b0;
  case (op_i[6:2])
    5'b01101: dec = {3'b001, 1'b1, 1'b0, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0011}; // lui
    5'b00101: dec = {3'b001, 1'b1, 1'b0, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b1, 2'b01, 4'b0000}; // auipc
    5'b00100: begin
      case (func3)
        3'b000: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0000};
        3'b010: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0010};
        3'b011: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b1010};
        3'b100: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0100};
        3'b110: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0110};
        3'b111: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0111};
        3'b001: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0001};
        3'b101: dec = func7
                        ? {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b1101}
                        : {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0101};
      endcase
    end
    5'b01100: begin
      case (func3)
        3'b000: dec = func7
                        ? {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b1000}
                        : {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0000};
        3'b001: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0001};
        3'b010: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0010};
        3'b011: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b1010};
        3'b100: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0100};
        3'b101: dec = func7
                        ? {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b1101}
                        : {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0101};
        3'b110: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0110};
        3'b111: if (!func7) dec = {3'b000, 1'b1, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0111};
      endcase
    end
    5'b11011: dec = {3'b100, 1'b1, 1'b0, 1'b0, 3'b001, 1'b0, 1'b0, 3'b000, 1'b1, 2'b10, 4'b0000}; // jal
    5'b11001: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b010, 1'b0, 1'b0, 3'b000, 1'b1, 2'b10, 4'b0000}; // jalr
    5'b11000: begin
      case (func3)
        3'b000: dec = {3'b011, 1'b0, 1'b1, 1'b1, 3'b100, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0010};
        3'b001: dec = {3'b011, 1'b0, 1'b1, 1'b1, 3'b101, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0010};
        3'b100: dec = {3'b011, 1'b0, 1'b1, 1'b1, 3'b110, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0010};
        3'b101: dec = {3'b011, 1'b0, 1'b1, 1'b1, 3'b111, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b0010};
        3'b110: dec = {3'b011, 1'b0, 1'b1, 1'b1, 3'b110, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b1010};
        3'b111: dec = {3'b011, 1'b0, 1'b1, 1'b1, 3'b111, 1'b0, 1'b0, 3'b000, 1'b0, 2'b00, 4'b1010};
      endcase
    end
    5'b00000: begin
      case (func3)
        3'b000: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b1, 1'b0, 3'b000, 1'b0, 2'b01, 4'b0000};
        3'b001: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b1, 1'b0, 3'b001, 1'b0, 2'b01, 4'b0000};
        3'b010: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b1, 1'b0, 3'b010, 1'b0, 2'b01, 4'b0000};
        3'b100: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b1, 1'b0, 3'b100, 1'b0, 2'b01, 4'b0000};
        3'b101: dec = {3'b000, 1'b1, 1'b1, 1'b0, 3'b000, 1'b1, 1'b0, 3'b101, 1'b0, 2'b01, 4'b0000};
      endcase
    end
    5'b01000: begin
      case (func3)
        3'b000: dec = {3'b010, 1'b0, 1'b1, 1'b1, 3'b000, 1'b0, 1'b1, 3'b000, 1'b0, 2'b01, 4'b0000};
        3'b001: dec = {3'b010, 1'b0, 1'b1, 1'b1, 3'b000, 1'b0, 1'b1, 3'b001, 1'b0, 2'b01, 4'b0000};
        3'b010: dec = {3'b010, 1'b0, 1'b1, 1'b1, 3'b000, 1'b0, 1'b1, 3'b010, 1'b0, 2'b01, 4'b0000};
      endcase
    end
  endcase
end
endmodule

/**
 * Immediate generator matching the NetX IMM selector.
 *
 * `ExtOP` selects one of the standard RISC-V immediate encodings:
 * I, U, S, B, or J.
 *
 * @port ExtOP  Immediate-format selector
 * @port instr  Raw 32-bit instruction word
 * @port imm    Decoded immediate value
 */
module IMM_SELECTOR(
  input [2:0] ext_op,
  input [31:0] instr,
  output reg [31:0] imm
);
always @(*) begin
  case (ext_op)
    3'b000: imm = {{20{instr[31]}}, instr[31:20]};
    3'b001: imm = {instr[31:12], 12'b0};
    3'b010: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    3'b011: imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
    3'b100: imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
    default: imm = 32'h00000000;
  endcase
end
endmodule

/**
  * Branch Predictor
  *
  * Branch predictor with a tiny BTB and 2-bit saturating counters.
  * Direct JAL is predicted taken in decode. Conditional branches use BTB state.
  * JALR remains EX-resolved.
  *
  * @port clk           System clock
  * @port rst           Reset signal
  * @port valid         Decode-stage instruction valid
  * @port branch        Decode-stage branch/jump class
  * @port pc            Decode-stage PC
  * @port imm           Decode-stage immediate for direct-target prediction
  * @port update_valid  EX-stage predictor training valid
  * @port update_branch EX-stage branch/jump class
  * @port update_pc     EX-stage PC being trained
  * @port update_taken  Actual taken/not-taken outcome
  * @port update_target Actual resolved target address
  * @port pred_taken    Predicted taken bit for the decode-stage instruction
  * @port pred_target   Predicted target address
  */
module BRANCH_PREDICTOR(
  input         clk,
  input         rst,
  input         valid,
  input  [2:0]  branch,
  input  [31:0] pc,
  input  [31:0] imm,
  input         update_valid,
  input  [2:0]  update_branch,
  input  [31:0] update_pc,
  input         update_taken,
  input  [31:0] update_target,
  output        pred_taken,
  output [31:0] pred_target
);
reg        btb_valid [0:3];
reg [27:0] btb_tag [0:3];
reg [31:0] btb_target [0:3];
reg [1:0]  btb_ctr [0:3];
integer i;

wire [1:0] q_idx = pc[3:2];
wire [27:0] q_tag = pc[31:4];
wire q_valid = btb_valid[q_idx];
wire [27:0] q_entry_tag = btb_tag[q_idx];
wire [31:0] q_entry_target = btb_target[q_idx];
wire [1:0] q_entry_ctr = btb_ctr[q_idx];
wire q_hit = q_valid && (q_entry_tag == q_tag);
wire q_ctr_taken = q_entry_ctr[1];
wire q_is_jal = (branch == 3'b001);
wire q_is_cond = branch[2];

assign pred_taken = (valid && q_is_jal) || (valid && q_is_cond && q_hit && q_ctr_taken);
assign pred_target = q_is_jal ? (pc + imm) : q_entry_target;

wire [1:0] u_idx = update_pc[3:2];
wire [27:0] u_tag = update_pc[31:4];
wire u_is_control = |update_branch;
wire u_en = update_valid && u_is_control;

// Two-bit saturating counter helpers for conditional branch training.
function [1:0] ctr_inc;
  input [1:0] ctr;
  begin
    case (ctr)
      2'b00: ctr_inc = 2'b01;
      2'b01: ctr_inc = 2'b10;
      default: ctr_inc = 2'b11;
    endcase
  end
endfunction

function [1:0] ctr_dec;
  input [1:0] ctr;
  begin
    case (ctr)
      2'b11: ctr_dec = 2'b10;
      2'b10: ctr_dec = 2'b01;
      default: ctr_dec = 2'b00;
    endcase
  end
endfunction

always @(posedge clk) begin
  if (rst) begin
    for (i = 0; i < 4; i = i + 1) begin
      btb_valid[i] <= 1'b0;
      btb_tag[i] <= 28'd0;
      btb_target[i] <= 32'd0;
      btb_ctr[i] <= 2'b01;
    end
  end else if (u_en) begin
    btb_valid[u_idx] <= 1'b1;
    btb_tag[u_idx] <= u_tag;
    btb_target[u_idx] <= update_target;
    if (btb_valid[u_idx] && (btb_tag[u_idx] == u_tag))
      btb_ctr[u_idx] <= update_taken ? 2'b10 : 2'b01;
    else
      btb_ctr[u_idx] <= update_taken ? ctr_inc(btb_ctr[u_idx]) : ctr_dec(btb_ctr[u_idx]);
  end
end
endmodule

/**
 * Dedicated branch comparator used by control-flow instructions. Keeping these
 * compares separate from the ALU/forwarding datapath matches the cleaned-up
 * NetX control path and shortens the critical cone for branch resolution.
 *
 * @port a    Left comparison operand
 * @port b    Right comparison operand
 * @port eq   Equality result
 * @port ltu  Unsigned less-than result
 * @port lts  Signed less-than result
 */
module BRANCH_COMPARE(
  input  [31:0] a,
  input  [31:0] b,
  output        eq,
  output        ltu,
  output        lts
);
assign eq = (a == b);
assign ltu = (a < b);
assign lts = ($signed(a) < $signed(b));
endmodule

/**
  * Register File
  *
  * This component implements a register file with a specified width and capacity.
  * It supports two asynchronous read ports and one synchronous write port.
  * Register x0 is hardwired to zero and ignores writes.
  *
  * @port clk    Register-file write clock
  * @port RegWr  Write enable
  * @port Ra     Read address A
  * @port Rb     Read address B
  * @port Rw     Write address
  * @port busW   Writeback data
  * @port busA   Read data A
  * @port busB   Read data B
  * @port x10    Debug copy of register x10
  */
module REG_FILE(
  input         clk,
  input         rst,
  input  [4:0]  rd_addr_a,
  input  [4:0]  rd_addr_b,
  input  [4:0]  wr_addr,
  input         wr_en,
  input  [31:0] din,
  output [31:0] dout_a,
  output [31:0] dout_b,
  output [31:0] x10
);
reg [31:0] regs [0:31];
integer i;
initial begin
  for (i = 0; i < 32; i = i + 1)
    regs[i] = 32'h00000000;
end

assign dout_a = (rd_addr_a == 5'd0) ? 32'd0 : regs[rd_addr_a];
assign dout_b = (rd_addr_b == 5'd0) ? 32'd0 : regs[rd_addr_b];
assign x10 = regs[10];

always @(posedge clk) begin
  if (rst) begin
    for (i = 0; i < 32; i = i + 1)
      regs[i] <= 32'h00000000;
  end else begin
    regs[0] <= 32'd0;
    if (wr_en && (wr_addr != 5'd0))
      regs[wr_addr] <= din;
  end
end
endmodule

/**
 * ALU matching the structure of the NetX version.
 *
 * Arithmetic, subtraction, equality/less-than flags, and shift operations are
 * all derived from explicit helper blocks instead of relying on built-in `+`
 * and shift operators alone.
 *
 * @port a          ALU operand A
 * @port b          ALU operand B
 * @port alu_ctl    Encoded ALU operation
 * @port zero       Zero/equality-style result flag
 * @port less       Less-than result flag
 * @port result     Main 32-bit ALU result
 */
module ALU(
  input  [31:0] a,
  input  [31:0] b,
  input  [3:0]  alu_ctl,
  output reg [31:0] result,
  output        zero,
  output        less
);
wire [2:0] opcode = alu_ctl[2:0];
wire shift_arith = alu_ctl[3];
wire shift_right = alu_ctl[2];
wire less_signed = ~alu_ctl[3];
wire cin = alu_ctl[3] | (opcode == 3'b010);

wire [31:0] adder_b = b ^ {32{cin}};
wire [31:0] adder_result;
wire carry;
wire zero_from_adder;
wire overflow;
ADDER32 adder_u(
  .a(a),
  .b(adder_b),
  .cin(cin),
  .sum(adder_result),
  .carry(carry),
  .zero(zero_from_adder),
  .overflow(overflow)
);
wire less_cmp = less_signed ? (overflow ^ adder_result[31]) : (carry ^ cin);

wire [31:0] shift_result;
BARREL_SHIFTER32 shifter_u(
  .din(a),
  .shamt(b[4:0]),
  .dir(shift_right),
  .arith(shift_arith),
  .dout(shift_result)
);

always @(*) begin
  case (opcode)
    3'b000: result = adder_result;
    3'b001: result = shift_result;
    3'b010: result = {31'd0, less_cmp};
    3'b011: result = b;
    3'b100: result = a ^ b;
    3'b101: result = shift_result;
    3'b110: result = a | b;
    3'b111: result = a & b;
    default: result = 32'd0;
  endcase
end
assign zero = zero_from_adder;
assign less = less_cmp;
endmodule

/**
  * Adder Component
  *
  * This component implements a 32-bit adder using a carry-lookahead approach for efficient addition.
  * It takes two 32-bit inputs (a and b) and a carry-in (cin) to produce a 32-bit sum, a carry-out, a zero flag, and an overflow flag.
  * The zero flag indicates if the result of the addition is zero, while the overflow flag indicates if there was an overflow during the addition.
  *
 * The adder is composed of eight 4-bit carry-lookahead adders (CLA) that are chained together to handle the 32-bit addition.
  *
  * @port a         Left addend
  * @port b         Right addend
  * @port cin       Carry input
  * @port sum       32-bit sum
  * @port carry     Carry out
  * @port zero      Sum-is-zero flag
  * @port overflow  Signed overflow flag
  */
module ADDER32(
  input  [31:0] a,
  input  [31:0] b,
  input         cin,
  output [31:0] sum,
  output        carry,
  output        zero,
  output        overflow
);
wire c1, c2, c3, c4, c5, c6, c7;

CLA4 cla0(
  .a(a[3:0]),
  .b(b[3:0]),
  .cin(cin),
  .sum(sum[3:0]),
  .carry(c1)
);
CLA4 cla1(
  .a(a[7:4]),
  .b(b[7:4]),
  .cin(c1),
  .sum(sum[7:4]),
  .carry(c2)
);
CLA4 cla2(
  .a(a[11:8]),
  .b(b[11:8]),
  .cin(c2),
  .sum(sum[11:8]),
  .carry(c3)
);
CLA4 cla3(
  .a(a[15:12]),
  .b(b[15:12]),
  .cin(c3),
  .sum(sum[15:12]),
  .carry(c4)
);
CLA4 cla4(
  .a(a[19:16]),
  .b(b[19:16]),
  .cin(c4),
  .sum(sum[19:16]),
  .carry(c5)
);
CLA4 cla5(
  .a(a[23:20]),
  .b(b[23:20]),
  .cin(c5),
  .sum(sum[23:20]),
  .carry(c6)
);
CLA4 cla6(
  .a(a[27:24]),
  .b(b[27:24]),
  .cin(c6),
  .sum(sum[27:24]),
  .carry(c7)
);
CLA4 cla7(
  .a(a[31:28]),
  .b(b[31:28]),
  .cin(c7),
  .sum(sum[31:28]),
  .carry(carry)
);

assign zero = ~|sum;
assign overflow = ~(a[31] ^ b[31]) & (a[31] ^ sum[31]);
endmodule

/**
  * Carry-Lookahead Adder Component
  *
 * This component implements a 4-bit carry-lookahead adder.
 * It takes two 4-bit inputs (a and b) and a carry-in (cin) to produce a 4-bit sum and a carry-out.
  *
  * @port a      Left addend slice
  * @port b      Right addend slice
  * @port cin    Carry input
 * @port sum    4-bit sum slice
 * @port carry  Carry output
 */
module CLA4(
  input  [3:0] a,
  input  [3:0] b,
  input        cin,
  output [3:0] sum,
  output       carry
);
wire [3:0] p;
wire [3:0] g;
wire [4:0] c;

assign p = a | b;
assign g = a & b;
assign c[0] = cin;
assign c[1] = g[0] | (p[0] & c[0]);
assign c[2] = g[1] | (p[1] & g[0]) | (p[1] & p[0] & c[0]);
assign c[3] = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) |
              (p[2] & p[1] & p[0] & c[0]);
assign c[4] = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) |
              (p[3] & p[2] & p[1] & g[0]) |
              (p[3] & p[2] & p[1] & p[0] & c[0]);

assign sum[0] = a[0] ^ b[0] ^ c[0];
assign sum[1] = a[1] ^ b[1] ^ c[1];
assign sum[2] = a[2] ^ b[2] ^ c[2];
assign sum[3] = a[3] ^ b[3] ^ c[3];
assign carry = c[4];
endmodule

/**
 * 32-bit barrel shifter used by the ALU for SLL / SRL / SRA.
 *
 * The shift is implemented as a staged 1/2/4/8/16-bit network so the structure
 * matches the explicit NetX shifter rather than relying on a single Verilog
 * shift operator.
 *
 * @port din    Input word
 * @port shamt  Shift amount
 * @port dir    Shift direction: 0 left, 1 right
 * @port arith  Arithmetic right-shift enable
 * @port dout   Shifted output word
 */
module BARREL_SHIFTER32(
  input  [31:0] din,
  input  [4:0]  shamt,
  input         dir,
  input         arith,
  output [31:0] dout
);
wire sign_bit = arith ? din[31] : 1'b0;
wire [31:0] stage0 = shamt[0]
  ? (dir ? {{1{sign_bit}}, din[31:1]} : {din[30:0], 1'b0})
  : din;
wire [31:0] stage1 = shamt[1]
  ? (dir ? {{2{sign_bit}}, stage0[31:2]} : {stage0[29:0], 2'b0})
  : stage0;
wire [31:0] stage2 = shamt[2]
  ? (dir ? {{4{sign_bit}}, stage1[31:4]} : {stage1[27:0], 4'b0})
  : stage1;
wire [31:0] stage3 = shamt[3]
  ? (dir ? {{8{sign_bit}}, stage2[31:8]} : {stage2[23:0], 8'b0})
  : stage2;
wire [31:0] stage4 = shamt[4]
  ? (dir ? {{16{sign_bit}}, stage3[31:16]} : {stage3[15:0], 16'b0})
  : stage3;

assign dout = stage4;
endmodule
