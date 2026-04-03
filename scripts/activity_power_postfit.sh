#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

PROJECT="${PROJECT:-rv32i_fpga}"
REVISION="${REVISION:-rv32i_fpga}"
QUARTUS_EDA="${QUARTUS_EDA:-quartus_eda}"
VSIM="${VSIM:-/opt/altera_lite/25.1std/questa_fse/bin/vsim}"
VLOG="${VLOG:-/opt/altera_lite/25.1std/questa_fse/bin/vlog}"
SIM_LIB_DIR="${SIM_LIB_DIR:-/opt/altera_lite/25.1std/quartus/eda/sim_lib}"
OUT_DIR="${OUT_DIR:-${REPO_DIR}/reports/activity_$(date +%Y%m%d_%H%M%S)}"
NETLIST_DIR="${NETLIST_DIR:-${OUT_DIR}/netlist}"
RUN_DIR="${RUN_DIR:-${OUT_DIR}/sim}"
CYCLES="${CYCLES:-20000}"
HALF_PERIOD_PS="${HALF_PERIOD_PS:-10000}"
RESET_PS="${RESET_PS:-40000}"
VCD_FILE="${VCD_FILE:-${OUT_DIR}/activity.vcd}"
TB_FILE="${TB_FILE:-${OUT_DIR}/activity_tb.v}"
SIM_TIME_PS=$((RESET_PS + (2 * HALF_PERIOD_PS * CYCLES)))

mkdir -p "${OUT_DIR}" "${NETLIST_DIR}" "${RUN_DIR}"

echo "[1/4] Exporting Quartus post-fit functional netlist"
(
    cd "${FPGA_DIR}"
    "${QUARTUS_EDA}" "${PROJECT}" -c "${REVISION}" \
        --simulation --tool=vcs --snapshot=final --functional=on \
        --output_directory="${NETLIST_DIR}"
)

cat > "${TB_FILE}" <<'TB'
`timescale 1 ps / 1 ps
module testbench;
  reg CLOCK_50 = 0;
  reg CLOCK2_50 = 0;
  reg CLOCK3_50 = 0;
  reg [3:0] KEY = 4'hf;
  reg [17:0] SW = 18'h1;
  reg altera_reserved_tms = 0;
  reg altera_reserved_tck = 0;
  reg altera_reserved_tdi = 0;
  wire altera_reserved_tdo;
  wire [8:0] LEDG;
  wire [17:0] LEDR;
  wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;
  wire LCD_BLON, LCD_EN, LCD_ON, LCD_RS, LCD_RW;
  tri [7:0] LCD_DATA;
  tri PS2_CLK, PS2_CLK2, PS2_DAT, PS2_DAT2;
  wire [7:0] VGA_B, VGA_G, VGA_R;
  wire VGA_BLANK_N, VGA_CLK, VGA_HS, VGA_SYNC_N, VGA_VS;

  rv32i_fpga dut (
    .altera_reserved_tms(altera_reserved_tms),
    .altera_reserved_tck(altera_reserved_tck),
    .altera_reserved_tdi(altera_reserved_tdi),
    .altera_reserved_tdo(altera_reserved_tdo),
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

  always #__HALF_PERIOD_PS__ CLOCK_50 = ~CLOCK_50;
  always #__HALF_PERIOD_PS__ CLOCK2_50 = ~CLOCK2_50;
  always #__HALF_PERIOD_PS__ CLOCK3_50 = ~CLOCK3_50;

  initial begin
    #__RESET_PS__;
    SW[0] = 1'b0;
  end
endmodule
TB

sed -i \
    -e "s/__HALF_PERIOD_PS__/${HALF_PERIOD_PS}/g" \
    -e "s/__RESET_PS__/${RESET_PS}/g" \
    "${TB_FILE}"

echo "[2/4] Compiling supported simulator model"
(
    cd "${RUN_DIR}"
    rm -rf work
    "${VSIM%/vsim}/vlib" work >/dev/null
    "${VLOG}" \
        "${SIM_LIB_DIR}/altera_primitives.v" \
        "${SIM_LIB_DIR}/220model.v" \
        "${SIM_LIB_DIR}/sgate.v" \
        "${SIM_LIB_DIR}/cycloneive_atoms.v" \
        "${NETLIST_DIR}/${PROJECT}.vo" \
        "${TB_FILE}" > "${OUT_DIR}/sim.compile.log" 2>&1
)

echo "[3/4] Running post-fit simulation and dumping VCD"
set +e
(
    cd "${RUN_DIR}"
    "${VSIM}" -c testbench \
        -do "vcd file ${VCD_FILE}; vcd add -r /testbench/dut/*; run ${SIM_TIME_PS}ps; quit -f" \
        > "${OUT_DIR}/sim.run.log" 2>&1
)
sim_status=$?
set -e

if [[ "${sim_status}" -ne 0 ]]; then
    echo "Simulation failed. See:"
    echo "  ${OUT_DIR}/sim.compile.log"
    echo "  ${OUT_DIR}/sim.run.log"
    if rg -q "Invalid license environment|Unable to checkout a license" "${OUT_DIR}/sim.run.log"; then
        echo
        echo "The installed Questa binaries need a valid license environment before they can run."
        echo "Once that is configured, rerun this script to produce ${VCD_FILE}."
    fi
    exit "${sim_status}"
fi

echo "[4/4] Running Quartus Power Analyzer with real activity"
INPUT_VCD="${VCD_FILE}" "${SCRIPT_DIR}/power_report.sh" | tee "${OUT_DIR}/power.log"

echo
echo "Artifacts:"
echo "  Netlist : ${NETLIST_DIR}/${PROJECT}.vo"
echo "  VCD     : ${VCD_FILE}"
echo "  Power   : ${OUT_DIR}/power.log"
