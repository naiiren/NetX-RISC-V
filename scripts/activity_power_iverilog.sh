#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

OUT_DIR="${OUT_DIR:-${REPO_DIR}/reports/activity_iverilog_$(date +%Y%m%d_%H%M%S)}"
SIM_DIR="${SIM_DIR:-${OUT_DIR}/sim}"
SANITIZED_DIR="${SANITIZED_DIR:-${OUT_DIR}/sanitized}"
VCD_FILE="${VCD_FILE:-${OUT_DIR}/activity.vcd}"
VCD_CLEAN_FILE="${VCD_CLEAN_FILE:-${OUT_DIR}/activity_clean.vcd}"
TB_FILE="${TB_FILE:-${OUT_DIR}/activity_tb.v}"
SIM_BIN="${SIM_BIN:-${OUT_DIR}/activity_sim}"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
CYCLES="${CYCLES:-20000}"
HALF_PERIOD_NS="${HALF_PERIOD_NS:-10}"
RESET_CYCLES="${RESET_CYCLES:-2}"

mkdir -p "${OUT_DIR}" "${SIM_DIR}" "${SANITIZED_DIR}"

echo "[1/5] Sanitizing generated RTL for Icarus"
for f in top.v io_periph.v kbd_periph.v vga_periph.v; do
    python3 "${SCRIPT_DIR}/sanitize_iverilog_verilog.py" \
        "${FPGA_DIR}/${f}" "${SANITIZED_DIR}/${f}"
done
cp "${FPGA_DIR}/rv32i_fpga.v" "${SANITIZED_DIR}/rv32i_fpga.v"

awk '
    BEGIN {
        for (i = 0; i < 32768; ++i) mem[i] = "00000000";
    }
    /^[0-9A-Fa-f]+[[:space:]]*:[[:space:]]*[0-9A-Fa-f]+;/ {
        gsub(/[[:space:]]/, "", $0);
        split($0, parts, ":");
        sub(/;$/, "", parts[2]);
        addr = strtonum("0x" parts[1]);
        mem[addr] = toupper(parts[2]);
    }
    END {
        for (i = 0; i < 32768; ++i) print mem[i];
    }
' "${FPGA_DIR}/_instr.mif" > "${SIM_DIR}/_instr.hex"

awk '
    BEGIN {
        for (i = 0; i < 32768; ++i) mem[i] = "00000000";
    }
    /^[0-9A-Fa-f]+[[:space:]]*:[[:space:]]*[0-9A-Fa-f]+;/ {
        gsub(/[[:space:]]/, "", $0);
        split($0, parts, ":");
        sub(/;$/, "", parts[2]);
        addr = strtonum("0x" parts[1]);
        mem[addr] = toupper(parts[2]);
    }
    END {
        for (i = 0; i < 32768; ++i) print mem[i];
    }
' "${FPGA_DIR}/_data.mif" > "${SIM_DIR}/_data.hex"

cat > "${SANITIZED_DIR}/ram_a.v" <<'RAMA'
module ram_a (
    input  [3:0]  byteena_a,
    input  [31:0] data,
    input  [14:0] rdaddress,
    input         rdclock,
    input  [14:0] wraddress,
    input         wrclock,
    input         wren,
    output reg [31:0] q
);
    reg [31:0] mem [0:32767];
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 32'h00000000;
        $readmemh("_data.hex", mem);
    end
    always @(posedge wrclock) begin
        if (wren) begin
            if (byteena_a[0]) mem[wraddress][7:0]   <= data[7:0];
            if (byteena_a[1]) mem[wraddress][15:8]  <= data[15:8];
            if (byteena_a[2]) mem[wraddress][23:16] <= data[23:16];
            if (byteena_a[3]) mem[wraddress][31:24] <= data[31:24];
        end
    end
    always @(posedge rdclock) begin
        q <= mem[rdaddress];
    end
endmodule
RAMA

cat > "${SANITIZED_DIR}/ram_b.v" <<'RAMB'
module ram_b (
    input  [14:0] address,
    input         clock,
    input  [31:0] data,
    input         wren,
    output reg [31:0] q
);
    reg [31:0] mem [0:32767];
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 32'h00000000;
        $readmemh("_instr.hex", mem);
    end
    always @(posedge clock) begin
        if (wren) mem[address] <= data;
        q <= mem[address];
    end
endmodule
RAMB

cat > "${SANITIZED_DIR}/ram_c.v" <<'RAMC'
module ram_c (
    input  [11:0] address_a,
    input  [11:0] address_b,
    input         clock,
    input  [7:0]  data_a,
    input  [7:0]  data_b,
    input         wren_a,
    input         wren_b,
    output reg [7:0] q_a,
    output reg [7:0] q_b
);
    reg [7:0] mem [0:4095];
    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'h00;
    end
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        if (wren_b) mem[address_b] <= data_b;
        q_a <= wren_a ? data_a : mem[address_a];
        q_b <= wren_b ? data_b : mem[address_b];
    end
endmodule
RAMC

cat > "${TB_FILE}" <<'TB'
`timescale 1ns / 1ps
module testbench;
  reg CLOCK_50 = 0;
  reg CLOCK2_50 = 0;
  reg CLOCK3_50 = 0;
  reg [3:0] KEY = 4'hf;
  reg [17:0] SW = 18'h1;
  wire [8:0] LEDG;
  wire [17:0] LEDR;
  wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;
  wire LCD_BLON, LCD_EN, LCD_ON, LCD_RS, LCD_RW;
  wire [7:0] LCD_DATA;
  wire PS2_CLK, PS2_CLK2, PS2_DAT, PS2_DAT2;
  wire [7:0] VGA_B, VGA_G, VGA_R;
  wire VGA_BLANK_N, VGA_CLK, VGA_HS, VGA_SYNC_N, VGA_VS;

  rv32i_fpga dut (
    .CLOCK_50(CLOCK_50),
    .CLOCK2_50(CLOCK2_50),
    .CLOCK3_50(CLOCK3_50),
    .LEDG(LEDG),
    .LEDR(LEDR),
    .KEY(KEY),
    .SW(SW),
    .HEX0(HEX0),
    .HEX1(HEX1),
    .HEX2(HEX2),
    .HEX3(HEX3),
    .HEX4(HEX4),
    .HEX5(HEX5),
    .HEX6(HEX6),
    .HEX7(HEX7),
    .LCD_BLON(LCD_BLON),
    .LCD_DATA(LCD_DATA),
    .LCD_EN(LCD_EN),
    .LCD_ON(LCD_ON),
    .LCD_RS(LCD_RS),
    .LCD_RW(LCD_RW),
    .PS2_CLK(PS2_CLK),
    .PS2_CLK2(PS2_CLK2),
    .PS2_DAT(PS2_DAT),
    .PS2_DAT2(PS2_DAT2),
    .VGA_B(VGA_B),
    .VGA_BLANK_N(VGA_BLANK_N),
    .VGA_CLK(VGA_CLK),
    .VGA_G(VGA_G),
    .VGA_HS(VGA_HS),
    .VGA_R(VGA_R),
    .VGA_SYNC_N(VGA_SYNC_N),
    .VGA_VS(VGA_VS)
  );

  always #__HALF_PERIOD_NS__ CLOCK_50 = ~CLOCK_50;
  always #__HALF_PERIOD_NS__ CLOCK2_50 = ~CLOCK2_50;
  always #__HALF_PERIOD_NS__ CLOCK3_50 = ~CLOCK3_50;

  initial begin
    $dumpfile("__VCD_FILE__");
    $dumpvars(0, testbench);
    repeat (__RESET_CYCLES__) @(posedge CLOCK_50);
    SW[0] = 1'b0;
    repeat (__CYCLES__) @(posedge CLOCK_50);
    $display("done ledr=%h hex0=%b", LEDR, HEX0);
    $finish;
  end
endmodule
TB

sed -i \
    -e "s#__VCD_FILE__#${VCD_FILE}#g" \
    -e "s/__HALF_PERIOD_NS__/${HALF_PERIOD_NS}/g" \
    -e "s/__RESET_CYCLES__/${RESET_CYCLES}/g" \
    -e "s/__CYCLES__/${CYCLES}/g" \
    "${TB_FILE}"

echo "[2/5] Compiling whole-system RTL with Icarus"
"${IVERILOG}" -g2005-sv -o "${SIM_BIN}" \
    "${SANITIZED_DIR}/rv32i_fpga.v" \
    "${SANITIZED_DIR}/top.v" \
    "${SANITIZED_DIR}/io_periph.v" \
    "${SANITIZED_DIR}/kbd_periph.v" \
    "${SANITIZED_DIR}/vga_periph.v" \
    "${SANITIZED_DIR}/ram_a.v" \
    "${SANITIZED_DIR}/ram_b.v" \
    "${SANITIZED_DIR}/ram_c.v" \
    "${TB_FILE}" \
    > "${OUT_DIR}/compile.log" 2>&1

echo "[3/5] Running RTL simulation and dumping VCD"
(
    cd "${SIM_DIR}"
    "${VVP}" "${SIM_BIN}" > "${OUT_DIR}/sim.log" 2>&1
)

if [[ ! -f "${VCD_FILE}" ]]; then
    echo "Simulation completed without producing ${VCD_FILE}."
    echo "See ${OUT_DIR}/compile.log and ${OUT_DIR}/sim.log"
    exit 1
fi

awk '
    BEGIN { skip = 0 }
    /^\$dumpall$/ { skip = 1; next }
    skip && /^\$end$/ { skip = 0; next }
    !skip { print }
' "${VCD_FILE}" > "${VCD_CLEAN_FILE}"

echo "[4/5] Running Quartus Power Analyzer with VCD activity"
set +e
INPUT_VCD="${VCD_CLEAN_FILE}" "${SCRIPT_DIR}/power_report.sh" > "${OUT_DIR}/power.log" 2>&1
pow_status=$?
set -e

if [[ "${pow_status}" -ne 0 ]]; then
    echo "Quartus Power Analyzer did not accept the VCD cleanly."
    echo "See ${OUT_DIR}/power.log"
    exit "${pow_status}"
fi

echo "[5/5] Done"
echo "Artifacts:"
echo "  VCD   : ${VCD_FILE}"
echo "  VCD*  : ${VCD_CLEAN_FILE} (Quartus-fed copy)"
echo "  Logs  : ${OUT_DIR}/compile.log, ${OUT_DIR}/sim.log, ${OUT_DIR}/power.log"
