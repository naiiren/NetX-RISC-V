#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

PROJECT="${PROJECT:-rv32i_fpga}"
REVISION="${REVISION:-rv32i_fpga}"
QUARTUS_POW="${QUARTUS_POW:-quartus_pow}"
INPUT_VCD="${INPUT_VCD:-}"
INPUT_SAF="${INPUT_SAF:-}"

POW_ARGS=()
if [[ -n "${INPUT_VCD}" && -n "${INPUT_SAF}" ]]; then
    echo "Set only one of INPUT_VCD or INPUT_SAF."
    exit 1
fi
if [[ -n "${INPUT_VCD}" ]]; then
    POW_ARGS+=("--input_vcd=${INPUT_VCD}" "--use_vectorless_estimation=off")
fi
if [[ -n "${INPUT_SAF}" ]]; then
    POW_ARGS+=("--input_saf=${INPUT_SAF}" "--use_vectorless_estimation=off")
fi

cd "${FPGA_DIR}"

echo "[1/2] Running Quartus Power Analyzer"
"${QUARTUS_POW}" "${PROJECT}" -c "${REVISION}" "${POW_ARGS[@]}"

echo "[2/2] Power summary"
sed -n '1,40p' "${REVISION}.pow.summary"
