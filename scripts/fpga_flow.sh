#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

NX="${NX:-nx}"
QUARTUS_ROOT="${QUARTUS_ROOT:-/opt/altera_lite/25.1std/quartus}"
QPROGRAMMER_ROOT="${QPROGRAMMER_ROOT:-/opt/altera_lite/25.1std/qprogrammer}"
QUARTUS_SH="${QUARTUS_SH:-${QUARTUS_ROOT}/bin/quartus_sh}"
QUARTUS_PGM="${QUARTUS_PGM:-${QPROGRAMMER_ROOT}/bin/quartus_pgm}"

PROJECT="${PROJECT:-rv32i_fpga}"
REVISION="${REVISION:-rv32i_fpga}"
TOP_MODULE="${TOP_MODULE:-CORE}"
CABLE="${CABLE:-1}"
MODE="${MODE:-jtag}"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <test-name>"
    exit 1
fi

TEST_NAME="$1"
TMP_DATA="$(mktemp)"
TMP_AWK="$(mktemp)"
trap 'rm -f "${TMP_DATA}" "${TMP_AWK}"' EXIT

if [[ ! -f "${REPO_DIR}/custom_cases/${TEST_NAME}.hex" ]]; then
    echo "Missing test image: ${REPO_DIR}/custom_cases/${TEST_NAME}.hex"
    echo "Build it first with: bash scripts/build_tests.sh ${TEST_NAME}"
    exit 1
fi

if [[ ! -f "${REPO_DIR}/custom_cases/${TEST_NAME}.data" ]]; then
    echo "Missing test data image: ${REPO_DIR}/custom_cases/${TEST_NAME}.data"
    echo "Build it first with: bash scripts/build_tests.sh ${TEST_NAME}"
    exit 1
fi

echo "[1/3] Regenerating fpga/top.v from NetX"
"${NX}" dump verilog "${REPO_DIR}/_netx.toml" --top "${TOP_MODULE}" -o "${FPGA_DIR}/top.v"

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
awk -f "${TMP_AWK}" "${REPO_DIR}/custom_cases/${TEST_NAME}.hex" > "${FPGA_DIR}/_instr.mif"

cp "${REPO_DIR}/custom_cases/${TEST_NAME}.data" "${TMP_DATA}"
if [[ "$(wc -l < "${TMP_DATA}")" -eq 1 ]]; then
    printf '00000000\n' >> "${TMP_DATA}"
fi

awk -f "${TMP_AWK}" "${TMP_DATA}" > "${FPGA_DIR}/_data.mif"

echo "[3/3] Running Quartus compile and programming board"
(
    cd "${FPGA_DIR}"
    "${QUARTUS_SH}" --flow compile "${PROJECT}" -c "${REVISION}"
)

"${QUARTUS_PGM}" -m "${MODE}" -c "${CABLE}" -o "p;${FPGA_DIR}/${PROJECT}.sof"

echo
echo "Done."
echo "  Test image : ${TEST_NAME}"
echo "  SOF        : ${FPGA_DIR}/${PROJECT}.sof"
echo "  Cable      : ${CABLE}"
