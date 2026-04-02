#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

PROJECT="${PROJECT:-rv32i_fpga}"
REVISION="${REVISION:-rv32i_fpga}"
QUARTUS_POW="${QUARTUS_POW:-quartus_pow}"

cd "${FPGA_DIR}"

echo "[1/2] Running Quartus Power Analyzer"
"${QUARTUS_POW}" "${PROJECT}" -c "${REVISION}"

echo "[2/2] Power summary"
sed -n '1,40p' "${REVISION}.pow.summary"
