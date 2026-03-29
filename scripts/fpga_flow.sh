#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

NX="${NX:-nx}"
QUARTUS_SH="quartus_sh"
QUARTUS_CDB="quartus_cdb"
QUARTUS_ASM="quartus_asm"
QUARTUS_PGM="quartus_pgm"

PROJECT="${PROJECT:-rv32i_fpga}"
REVISION="${REVISION:-rv32i_fpga}"
TOP_MODULE="${TOP_MODULE:-CORE}"
CABLE="${CABLE:-1}"
MODE="${MODE:-jtag}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 [core|lcd] <test-name>"
    exit 1
fi

if [[ $# -eq 1 ]]; then
    FLOW_MODE="core"
    TEST_NAME="$1"
else
    FLOW_MODE="$1"
    TEST_NAME="$2"
fi

if [[ "${FLOW_MODE}" != "core" && "${FLOW_MODE}" != "lcd" ]]; then
    echo "Invalid mode: ${FLOW_MODE}"
    echo "Expected one of: core, lcd"
    exit 1
fi

TMP_DATA="$(mktemp)"
TMP_AWK="$(mktemp)"
TMP_OUT1="$(mktemp)"
TMP_OUT2="$(mktemp)"
TMP_OUT3="$(mktemp)"
TMP_OUT4="$(mktemp)"
trap 'rm -f "${TMP_DATA}" "${TMP_AWK}" "${TMP_OUT1}" "${TMP_OUT2}" "${TMP_OUT3}" "${TMP_OUT4}"' EXIT

write_if_changed() {
    local src="$1"
    local dst="$2"

    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        return 1
    fi

    cp "${src}" "${dst}"
    return 0
}

CASE_DIR="${REPO_DIR}/custom_cases"
if [[ "${FLOW_MODE}" == "lcd" ]]; then
    CASE_DIR="${REPO_DIR}/fpga_cases"
fi

if [[ ! -f "${CASE_DIR}/${TEST_NAME}.hex" ]]; then
    echo "Missing test image: ${CASE_DIR}/${TEST_NAME}.hex"
    echo "Build it first with the matching make target or scripts/build_tests.sh."
    exit 1
fi

if [[ ! -f "${CASE_DIR}/${TEST_NAME}.data" ]]; then
    echo "Missing test data image: ${CASE_DIR}/${TEST_NAME}.data"
    echo "Build it first with the matching make target or scripts/build_tests.sh."
    exit 1
fi

echo "[1/3] Regenerating FPGA HDL from NetX"
NEED_FULL_COMPILE=0

"${NX}" dump verilog "${REPO_DIR}/_netx.toml" --top "${TOP_MODULE}" -o "${TMP_OUT1}"
if write_if_changed "${TMP_OUT1}" "${FPGA_DIR}/top.v"; then
    NEED_FULL_COMPILE=1
fi

if [[ "${FLOW_MODE}" == "lcd" ]]; then
    "${NX}" dump verilog "${REPO_DIR}/_netx.toml" --top "LCD_DRIVER" -o "${TMP_OUT2}"
    if write_if_changed "${TMP_OUT2}" "${FPGA_DIR}/io_periph.v"; then
        NEED_FULL_COMPILE=1
    fi

    "${NX}" dump verilog "${REPO_DIR}/_netx.toml" --top "PS2_KEYBOARD_DRIVER" -o "${TMP_OUT3}"
    if write_if_changed "${TMP_OUT3}" "${FPGA_DIR}/kbd_periph.v"; then
        NEED_FULL_COMPILE=1
    fi

    "${NX}" dump verilog "${REPO_DIR}/_netx.toml" --top "VGA_DRIVER" -o "${TMP_OUT4}"
    if write_if_changed "${TMP_OUT4}" "${FPGA_DIR}/vga_periph.v"; then
        NEED_FULL_COMPILE=1
    fi
else
    cat > "${TMP_OUT2}" <<'VERILOG'
module LCD_DRIVER(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] core_addr,
    input  wire [31:0] core_wdata,
    input  wire [2:0]  core_op,
    input  wire        core_we,
    input  wire [15:0] otg_data_in,
    input  wire        otg_int,
    output wire [31:0] core_rdata,
    output wire        mmio_hit,
    output wire [7:0]  lcd_data,
    output wire        lcd_blon,
    output wire        lcd_en,
    output wire        lcd_on,
    output wire        lcd_rs,
    output wire        lcd_rw,
    output wire [1:0]  otg_addr,
    output wire        otg_cs_n,
    output wire [15:0] otg_data_out,
    output wire        otg_data_oe,
    output wire        otg_rd_n,
    output wire        otg_rst_n,
    output wire        otg_we_n
);
assign core_rdata  = 32'd0;
assign mmio_hit    = 1'b0;
assign lcd_data    = 8'd0;
assign lcd_blon    = 1'b1;
assign lcd_en      = 1'b0;
assign lcd_on      = 1'b1;
assign lcd_rs      = 1'b0;
assign lcd_rw      = 1'b0;
assign otg_addr    = 2'b00;
assign otg_cs_n    = 1'b1;
assign otg_data_out = 16'd0;
assign otg_data_oe = 1'b0;
assign otg_rd_n    = 1'b1;
assign otg_rst_n   = 1'b1;
assign otg_we_n    = 1'b1;
endmodule
VERILOG
    if write_if_changed "${TMP_OUT2}" "${FPGA_DIR}/io_periph.v"; then
        NEED_FULL_COMPILE=1
    fi

    cat > "${TMP_OUT3}" <<'VERILOG'
module PS2_KEYBOARD_DRIVER(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] core_addr,
    input  wire [31:0] core_wdata,
    input  wire [2:0]  core_op,
    input  wire        core_we,
    input  wire        ps2_clk,
    input  wire        ps2_dat,
    output wire [31:0] core_rdata,
    output wire        mmio_hit
);
assign core_rdata = 32'd0;
assign mmio_hit   = 1'b0;
endmodule
VERILOG
    if write_if_changed "${TMP_OUT3}" "${FPGA_DIR}/kbd_periph.v"; then
        NEED_FULL_COMPILE=1
    fi

    cat > "${TMP_OUT4}" <<'VERILOG'
module VGA_DRIVER(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] core_addr,
    input  wire [31:0] core_wdata,
    input  wire [2:0]  core_op,
    input  wire        core_we,
    input  wire [7:0]  scan_char,
    output wire [31:0] core_rdata,
    output wire        mmio_hit,
    output wire [11:0] scan_addr,
    output wire [7:0] vga_r,
    output wire [7:0] vga_g,
    output wire [7:0] vga_b,
    output wire       vga_blank_n,
    output wire       vga_clk,
    output wire       vga_hs,
    output wire       vga_sync_n,
    output wire       vga_vs
);
assign core_rdata   = 32'd0;
assign mmio_hit     = 1'b0;
assign scan_addr    = 12'd0;
assign vga_r       = 8'd0;
assign vga_g       = 8'd0;
assign vga_b       = 8'd0;
assign vga_blank_n = 1'b0;
assign vga_clk     = 1'b0;
assign vga_hs      = 1'b1;
assign vga_sync_n  = 1'b0;
assign vga_vs      = 1'b1;
endmodule
VERILOG
    if write_if_changed "${TMP_OUT4}" "${FPGA_DIR}/vga_periph.v"; then
        NEED_FULL_COMPILE=1
    fi
fi

cat > "${TMP_AWK}" <<'AWK'
BEGIN {
    print "WIDTH=32;";
    print "DEPTH=32768;";
    print "";
    print "ADDRESS_RADIX=HEX;";
    print "DATA_RADIX=HEX;";
    print "";
    print "CONTENT BEGIN";
    addr = 0;
}
/^@/ {
    addr = strtonum("0x" substr($0, 2));
    next;
}
/^[0-9A-Fa-f]+$/ {
    printf("%X : %s;\n", addr, toupper($0));
    addr++;
}
END {
    print "END;";
}
AWK

echo "[2/3] Preparing memory images for Quartus RAM init"
awk -f "${TMP_AWK}" "${CASE_DIR}/${TEST_NAME}.hex" > "${TMP_OUT1}"
write_if_changed "${TMP_OUT1}" "${FPGA_DIR}/_instr.mif" || true

cp "${CASE_DIR}/${TEST_NAME}.data" "${TMP_DATA}"
if [[ "$(wc -l < "${TMP_DATA}")" -eq 1 ]]; then
    printf '00000000\n' >> "${TMP_DATA}"
fi

awk -f "${TMP_AWK}" "${TMP_DATA}" > "${TMP_OUT2}"
write_if_changed "${TMP_OUT2}" "${FPGA_DIR}/_data.mif" || true

echo "[3/3] Running Quartus compile and programming board"
(
    cd "${FPGA_DIR}"
    if [[ ! -f "${PROJECT}.sof" ]]; then
        NEED_FULL_COMPILE=1
    fi

    if [[ "${NEED_FULL_COMPILE}" -eq 1 ]]; then
        echo "  -> Full compile (HDL changed or no existing SOF)"
        "${QUARTUS_SH}" --flow compile "${PROJECT}" -c "${REVISION}"
    else
        echo "  -> Fast image update (reuse existing fit)"
        "${QUARTUS_CDB}" "${PROJECT}" -c "${REVISION}" --update_mif
        "${QUARTUS_ASM}" "${PROJECT}" -c "${REVISION}"
    fi
)

"${QUARTUS_PGM}" -m "${MODE}" -c "${CABLE}" -o "p;${FPGA_DIR}/${PROJECT}.sof"

echo
echo "Done."
echo "  Mode       : ${FLOW_MODE}"
echo "  Test image : ${TEST_NAME}"
echo "  SOF        : ${FPGA_DIR}/${PROJECT}.sof"
echo "  Cable      : ${CABLE}"
