#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"

OUT_DIR="${OUT_DIR:-${REPO_DIR}/reports/compare_$(date +%Y%m%d_%H%M%S)}"
TEST_NAME="${1:-system}"

mkdir -p "${OUT_DIR}"

ensure_case() {
    local name="$1"

    for dir in "${REPO_DIR}/testcases" "${REPO_DIR}/custom_cases" "${REPO_DIR}/fpga_cases"; do
        if [[ -f "${dir}/${name}.hex" && -f "${dir}/${name}.data" ]]; then
            printf '%s\n' "${dir}"
            return 0
        fi
    done

    if [[ -f "${REPO_DIR}/scripts/${name}.c" ]]; then
        local out_dir="${REPO_DIR}/custom_cases"
        if [[ "${name}" == "system" || "${name}" == "lcd" || "${name}" == "vga" ]]; then
            out_dir="${REPO_DIR}/fpga_cases"
        fi
        OUT_DIR="${out_dir}" bash "${REPO_DIR}/scripts/build_tests.sh" "${REPO_DIR}/scripts/${name}.c" >/dev/null
        printf '%s\n' "${out_dir}"
        return 0
    fi

    echo "Unable to resolve case '${name}' in testcases/, custom_cases/, or fpga_cases/."
    exit 1
}

write_if_changed() {
    local src="$1"
    local dst="$2"

    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        return 1
    fi

    cp "${src}" "${dst}"
    return 0
}

stage_case_for_flow() {
    local src_dir="$1"
    local name="$2"
    local target_dir="${REPO_DIR}/fpga_cases"

    mkdir -p "${target_dir}"
    write_if_changed "${src_dir}/${name}.hex" "${target_dir}/${name}.hex" || true
    write_if_changed "${src_dir}/${name}.data" "${target_dir}/${name}.data" || true
    printf '%s\n' "${target_dir}"
}

copy_reports() {
    local prefix="$1"

    cp "${FPGA_DIR}/rv32i_fpga.sta.summary" "${OUT_DIR}/${prefix}.sta.summary"
    cp "${FPGA_DIR}/rv32i_fpga.sta.rpt" "${OUT_DIR}/${prefix}.sta.rpt"
    cp "${FPGA_DIR}/rv32i_fpga.fit.summary" "${OUT_DIR}/${prefix}.fit.summary"
    cp "${FPGA_DIR}/rv32i_fpga.pow.summary" "${OUT_DIR}/${prefix}.pow.summary"
}

extract_slack() {
    awk '
        /Type  : Slow .* Setup '\''CLOCK_50'\''/ { want=1; next }
        want && /Slack :/ { print $3; exit }
    ' "$1"
}

extract_fmax() {
    awk -F';' '
        /^; Slow .* Model Fmax Summary/ { in_fmax=1; next }
        in_fmax && /^; [0-9.]+ MHz/ && /CLOCK_50/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            print $2;
            exit;
        }
    ' "$1"
}

extract_fmax_0c() {
    awk -F';' '
        /^; Slow 1200mV 0C Model Fmax Summary/ { in_fmax=1; next }
        in_fmax && /^; [0-9.]+ MHz/ && /CLOCK_50/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            print $2;
            exit;
        }
    ' "$1"
}

extract_fit_metric() {
    local key="$2"
    sed -n "s/^${key} : \\(.*\\)$/\\1/p" "$1" | head -n1
}

extract_pow_metric() {
    local key="$2"
    sed -n "s/^${key} : \\(.*\\)$/\\1/p" "$1" | head -n1
}

CASE_DIR="$(ensure_case "${TEST_NAME}")"
FLOW_CASE_DIR="$(stage_case_for_flow "${CASE_DIR}" "${TEST_NAME}")"
echo "[1/3] Running NetX FPGA flow"
bash "${REPO_DIR}/scripts/fpga_flow.sh" lcd "${TEST_NAME}" >/dev/null
bash "${REPO_DIR}/scripts/power_report.sh" > "${OUT_DIR}/netx.power.log" 2>&1
copy_reports "netx"

echo "[2/3] Running Verilog baseline FPGA flow"
CASE_DIR="${FLOW_CASE_DIR}" bash "${REPO_DIR}/scripts/fpga_flow_verilog.sh" "${TEST_NAME}" >/dev/null
bash "${REPO_DIR}/scripts/power_report.sh" > "${OUT_DIR}/baseline.power.log" 2>&1
copy_reports "baseline"

echo "[3/3] Writing summary"
cat > "${OUT_DIR}/summary.txt" <<EOF
Test case: ${TEST_NAME}
Case dir: ${CASE_DIR}
Flow: whole-system

NetX FPGA:
  Slack: $(extract_slack "${OUT_DIR}/netx.sta.summary")
  Fmax 85C: $(extract_fmax "${OUT_DIR}/netx.sta.rpt")
  Fmax 0C: $(extract_fmax_0c "${OUT_DIR}/netx.sta.rpt")
  Logic elements: $(extract_fit_metric "${OUT_DIR}/netx.fit.summary" "Total logic elements")
  Dedicated logic registers: $(extract_fit_metric "${OUT_DIR}/netx.fit.summary" "    Dedicated logic registers")
  Total registers: $(extract_fit_metric "${OUT_DIR}/netx.fit.summary" "Total registers")
  Total power: $(extract_pow_metric "${OUT_DIR}/netx.pow.summary" "Total Thermal Power Dissipation")
  Core dynamic power: $(extract_pow_metric "${OUT_DIR}/netx.pow.summary" "Core Dynamic Thermal Power Dissipation")
  Confidence: $(extract_pow_metric "${OUT_DIR}/netx.pow.summary" "Power Estimation Confidence")

Baseline FPGA:
  Slack: $(extract_slack "${OUT_DIR}/baseline.sta.summary")
  Fmax 85C: $(extract_fmax "${OUT_DIR}/baseline.sta.rpt")
  Fmax 0C: $(extract_fmax_0c "${OUT_DIR}/baseline.sta.rpt")
  Logic elements: $(extract_fit_metric "${OUT_DIR}/baseline.fit.summary" "Total logic elements")
  Dedicated logic registers: $(extract_fit_metric "${OUT_DIR}/baseline.fit.summary" "    Dedicated logic registers")
  Total registers: $(extract_fit_metric "${OUT_DIR}/baseline.fit.summary" "Total registers")
  Total power: $(extract_pow_metric "${OUT_DIR}/baseline.pow.summary" "Total Thermal Power Dissipation")
  Core dynamic power: $(extract_pow_metric "${OUT_DIR}/baseline.pow.summary" "Core Dynamic Thermal Power Dissipation")
  Confidence: $(extract_pow_metric "${OUT_DIR}/baseline.pow.summary" "Power Estimation Confidence")
EOF

cat "${OUT_DIR}/summary.txt"
echo
echo "Artifacts saved under ${OUT_DIR}"
