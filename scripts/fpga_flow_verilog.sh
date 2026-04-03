#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"
BASELINE_DIR="${REPO_DIR}/verilog_baseline"
QSF_FILE="${FPGA_DIR}/rv32i_fpga.qsf"

QUARTUS_SH="quartus_sh"
QUARTUS_CDB="quartus_cdb"
QUARTUS_ASM="quartus_asm"
QUARTUS_PGM="quartus_pgm"

PROJECT="${PROJECT:-rv32i_fpga}"
REVISION="${REVISION:-rv32i_fpga}"
CABLE="${CABLE:-1}"
MODE="${MODE:-jtag}"
CASE_DIR="${CASE_DIR:-${REPO_DIR}/custom_cases}"
PROGRAM_DEVICE="${PROGRAM_DEVICE:-1}"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <test-name>"
    exit 1
fi

TEST_NAME="$1"

if [[ "${CASE_DIR}" == "${REPO_DIR}/custom_cases" ]]; then
    if [[ ! -f "${CASE_DIR}/${TEST_NAME}.hex" && -f "${REPO_DIR}/fpga_cases/${TEST_NAME}.hex" ]]; then
        CASE_DIR="${REPO_DIR}/fpga_cases"
    fi
fi

if [[ ! -f "${CASE_DIR}/${TEST_NAME}.hex" ]]; then
    echo "Missing test image: ${CASE_DIR}/${TEST_NAME}.hex"
    echo "Build it first with scripts/build_tests.sh or the matching make target."
    exit 1
fi

if [[ ! -f "${CASE_DIR}/${TEST_NAME}.data" ]]; then
    echo "Missing test data image: ${CASE_DIR}/${TEST_NAME}.data"
    echo "Build it first with scripts/build_tests.sh or the matching make target."
    exit 1
fi

TMP_DATA="$(mktemp)"
TMP_AWK="$(mktemp)"
TMP_OUT1="$(mktemp)"
TMP_OUT2="$(mktemp)"
trap 'rm -f "${TMP_DATA}" "${TMP_AWK}" "${TMP_OUT1}" "${TMP_OUT2}"' EXIT

write_if_changed() {
    local src="$1"
    local dst="$2"

    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        return 1
    fi

    cp "${src}" "${dst}"
    return 0
}

set_active_sources() {
    local tmp_qsf
    local changed=0

    tmp_qsf="$(mktemp)"
    awk '
        /# BEGIN_ACTIVE_SOURCES/ {
            print
            print "set_global_assignment -name VERILOG_FILE rv32i_fpga.v"
            print "set_global_assignment -name VERILOG_FILE core.v"
            print "set_global_assignment -name VERILOG_FILE verilog_periph.v"
            in_block = 1
            next
        }
        /# END_ACTIVE_SOURCES/ {
            in_block = 0
            print
            next
        }
        !in_block { print }
    ' "${QSF_FILE}" > "${tmp_qsf}"

    if ! cmp -s "${tmp_qsf}" "${QSF_FILE}"; then
        mv "${tmp_qsf}" "${QSF_FILE}"
        changed=1
    else
        rm -f "${tmp_qsf}"
    fi

    return "${changed}"
}

echo "[1/3] Syncing handwritten Verilog baseline into the FPGA build tree"
NEED_FULL_COMPILE=0

if set_active_sources; then
    NEED_FULL_COMPILE=1
fi

if [[ -f "${FPGA_DIR}/top.v" || -f "${FPGA_DIR}/io_periph.v" || -f "${FPGA_DIR}/kbd_periph.v" || -f "${FPGA_DIR}/vga_periph.v" ]]; then
    rm -f "${FPGA_DIR}/top.v" "${FPGA_DIR}/io_periph.v" "${FPGA_DIR}/kbd_periph.v" "${FPGA_DIR}/vga_periph.v"
    NEED_FULL_COMPILE=1
fi

if write_if_changed "${BASELINE_DIR}/core.v" "${FPGA_DIR}/core.v"; then
    NEED_FULL_COMPILE=1
fi

if write_if_changed "${BASELINE_DIR}/fpga.v" "${FPGA_DIR}/verilog_periph.v"; then
    NEED_FULL_COMPILE=1
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
        echo "  -> Full compile (baseline HDL changed or no existing SOF)"
        "${QUARTUS_SH}" --flow compile "${PROJECT}" -c "${REVISION}"
    else
        echo "  -> Fast image update (reuse existing fit)"
        "${QUARTUS_CDB}" "${PROJECT}" -c "${REVISION}" --update_mif
        "${QUARTUS_ASM}" "${PROJECT}" -c "${REVISION}"
    fi
)

if [[ "${PROGRAM_DEVICE}" == "1" ]]; then
    "${QUARTUS_PGM}" -m "${MODE}" -c "${CABLE}" -o "p;${FPGA_DIR}/${PROJECT}.sof"
else
    echo "  -> Skipping board programming (PROGRAM_DEVICE=${PROGRAM_DEVICE})"
fi

echo
echo "Done."
echo "  Flow       : verilog-baseline"
echo "  Test image : ${TEST_NAME}"
echo "  Case dir   : ${CASE_DIR}"
echo "  SOF        : ${FPGA_DIR}/${PROJECT}.sof"
echo "  Cable      : ${CABLE}"
