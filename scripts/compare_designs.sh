#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FPGA_DIR="${REPO_DIR}/fpga"
WORKLOAD_DIR="${REPO_DIR}/workloads"

OUT_DIR="${OUT_DIR:-${REPO_DIR}/reports/compare_$(date +%Y%m%d_%H%M%S)}"
TEST_NAME="${1:-system}"
ACTIVITY_CYCLES="${ACTIVITY_CYCLES:-1000}"

mkdir -p "${OUT_DIR}"

NETX_LOC_FILES=(
    "${REPO_DIR}/src/alu.nx"
    "${REPO_DIR}/src/branch.nx"
    "${REPO_DIR}/src/fpga.nx"
    "${REPO_DIR}/src/rv32i.nx"
)

VERILOG_LOC_FILES=(
    "${REPO_DIR}/verilog_baseline/core.v"
    "${REPO_DIR}/verilog_baseline/fpga.v"
)

ensure_case() {
    local name="$1"

    for dir in "${REPO_DIR}/testcases" "${REPO_DIR}/custom_cases" "${REPO_DIR}/fpga_cases"; do
        if [[ -f "${dir}/${name}.hex" && -f "${dir}/${name}.data" ]]; then
            printf '%s\n' "${dir}"
            return 0
        fi
    done

    local source_file=""
    if [[ -f "${WORKLOAD_DIR}/${name}.c" ]]; then
        source_file="${WORKLOAD_DIR}/${name}.c"
    elif [[ -f "${REPO_DIR}/scripts/${name}.c" ]]; then
        source_file="${REPO_DIR}/scripts/${name}.c"
    fi

    if [[ -n "${source_file}" ]]; then
        local out_dir="${REPO_DIR}/custom_cases"
        if [[ "${name}" == "system" || "${name}" == "lcd" || "${name}" == "vga" ]]; then
            out_dir="${REPO_DIR}/fpga_cases"
        fi
        OUT_DIR="${out_dir}" bash "${REPO_DIR}/scripts/build_tests.sh" "${source_file}" >/dev/null
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

run_activity_flow() {
    local prefix="$1"
    local script_name="$2"
    local activity_dir="${OUT_DIR}/${prefix}.activity"

    rm -rf "${activity_dir}"
    OUT_DIR="${activity_dir}" CYCLES="${ACTIVITY_CYCLES}" \
        bash "${REPO_DIR}/scripts/${script_name}" > "${OUT_DIR}/${prefix}.activity.log" 2>&1
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

sum_lines() {
    awk 'END { print NR }' "$@"
}

sum_decimal_pair() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3fs", a + b }'
}

measure_netx_elapsed_time() {
    local label="$1"
    shift

    local log_file="${OUT_DIR}/${label}.log"

    set +e
    "$@" > "${log_file}" 2>&1
    local status=$?
    set -e

    local elapsed
    elapsed=$(awk '
        /^Elapsed time: / {
            value = $3
            sub(/s$/, "", value)
            total += value
            found = 1
        }
        END {
            if (found) {
                printf "%.3fs", total
            }
        }
    ' "${log_file}")

    if [[ -n "${elapsed}" ]]; then
        printf '%s' "${elapsed}"
    else
        printf 'FAILED(exit %d)' "${status}"
    fi
}

measure_verilog_sim_time() {
    local label="$1"
    shift

    local log_file="${OUT_DIR}/${label}.log"

    set +e
    (
        cd "${REPO_DIR}/verilog_baseline"
        "$@"
    ) > "${log_file}" 2>&1
    local status=$?
    set -e

    local sim_time
    sim_time=$(sed -n 's/^Time Estimated for simulation: \(.*\)$/\1/p' "${log_file}" | tail -n1)

    if [[ -n "${sim_time}" ]]; then
        printf '%s' "${sim_time}"
    else
        printf 'FAILED(exit %d)' "${status}"
    fi
}

CASE_DIR="$(ensure_case "${TEST_NAME}")"
FLOW_CASE_DIR="$(stage_case_for_flow "${CASE_DIR}" "${TEST_NAME}")"
NETX_LOC_TOTAL="$(sum_lines "${NETX_LOC_FILES[@]}")"
VERILOG_LOC_TOTAL="$(sum_lines "${VERILOG_LOC_FILES[@]}")"

echo "[1/4] Running NetX FPGA flow"
PROGRAM_DEVICE=0 bash "${REPO_DIR}/scripts/fpga_flow.sh" lcd "${TEST_NAME}" > "${OUT_DIR}/netx.flow.log" 2>&1
bash "${REPO_DIR}/scripts/power_report.sh" > "${OUT_DIR}/netx.power.log" 2>&1
copy_reports "netx"
run_activity_flow "netx" "activity_power_iverilog.sh"

echo "[2/4] Running Verilog baseline FPGA flow"
CASE_DIR="${FLOW_CASE_DIR}" PROGRAM_DEVICE=0 \
    bash "${REPO_DIR}/scripts/fpga_flow_verilog.sh" "${TEST_NAME}" > "${OUT_DIR}/baseline.flow.log" 2>&1
bash "${REPO_DIR}/scripts/power_report.sh" > "${OUT_DIR}/baseline.power.log" 2>&1
copy_reports "baseline"
run_activity_flow "baseline" "activity_power_iverilog_baseline.sh"

echo "[3/4] Measuring software harness runtimes"
NETX_RUN_TIME="$(measure_netx_elapsed_time "netx.make_run" make run)"
NETX_RAW_TIME="$(measure_netx_elapsed_time "netx.make_raw" make raw)"
NETX_TOTAL_TIME="N/A"
if [[ "${NETX_RUN_TIME}" != FAILED* && "${NETX_RAW_TIME}" != FAILED* ]]; then
    NETX_TOTAL_TIME="$(sum_decimal_pair "${NETX_RUN_TIME%s}" "${NETX_RAW_TIME%s}")"
fi

VERILOG_TEST_TIME="$(measure_verilog_sim_time "baseline.run_tests" ./run_tests.sh)"
VERILOG_CUSTOM_TIME="$(measure_verilog_sim_time "baseline.run_tests_custom" ./run_tests.sh ../custom_cases)"
VERILOG_TOTAL_TIME="N/A"
if [[ "${VERILOG_TEST_TIME}" != FAILED* && "${VERILOG_CUSTOM_TIME}" != FAILED* ]]; then
    VERILOG_TOTAL_TIME="$(sum_decimal_pair "${VERILOG_TEST_TIME%s}" "${VERILOG_CUSTOM_TIME%s}")"
fi

echo "[4/4] Writing summary"
cat > "${OUT_DIR}/summary.txt" <<EOF
Test case: ${TEST_NAME}
Case dir: ${CASE_DIR}
Flow: whole-system
Activity cycles: ${ACTIVITY_CYCLES}
Preferred power metric: activity-based (VCD-fed Quartus Power Analyzer)

NetX FPGA:
  Source LOC: ${NETX_LOC_TOTAL}
  Native simulation time: ${NETX_RUN_TIME}
  Raw simulation time: ${NETX_RAW_TIME}
  Slack: $(extract_slack "${OUT_DIR}/netx.sta.summary")
  Fmax 85C: $(extract_fmax "${OUT_DIR}/netx.sta.rpt")
  Fmax 0C: $(extract_fmax_0c "${OUT_DIR}/netx.sta.rpt")
  Logic elements: $(extract_fit_metric "${OUT_DIR}/netx.fit.summary" "Total logic elements")
  Dedicated logic registers: $(extract_fit_metric "${OUT_DIR}/netx.fit.summary" "    Dedicated logic registers")
  Total registers: $(extract_fit_metric "${OUT_DIR}/netx.fit.summary" "Total registers")
  Activity total power: $(extract_pow_metric "${OUT_DIR}/netx.activity/power.log" "Total Thermal Power Dissipation")
  Activity core dynamic: $(extract_pow_metric "${OUT_DIR}/netx.activity/power.log" "Core Dynamic Thermal Power Dissipation")
  Activity confidence: $(extract_pow_metric "${OUT_DIR}/netx.activity/power.log" "Power Estimation Confidence")

Baseline FPGA:
  Source LOC: ${VERILOG_LOC_TOTAL}
  Simulation time: ${VERILOG_TOTAL_TIME}
  Slack: $(extract_slack "${OUT_DIR}/baseline.sta.summary")
  Fmax 85C: $(extract_fmax "${OUT_DIR}/baseline.sta.rpt")
  Fmax 0C: $(extract_fmax_0c "${OUT_DIR}/baseline.sta.rpt")
  Logic elements: $(extract_fit_metric "${OUT_DIR}/baseline.fit.summary" "Total logic elements")
  Dedicated logic registers: $(extract_fit_metric "${OUT_DIR}/baseline.fit.summary" "    Dedicated logic registers")
  Total registers: $(extract_fit_metric "${OUT_DIR}/baseline.fit.summary" "Total registers")
  Activity total power: $(extract_pow_metric "${OUT_DIR}/baseline.activity/power.log" "Total Thermal Power Dissipation")
  Activity core dynamic: $(extract_pow_metric "${OUT_DIR}/baseline.activity/power.log" "Core Dynamic Thermal Power Dissipation")
  Activity confidence: $(extract_pow_metric "${OUT_DIR}/baseline.activity/power.log" "Power Estimation Confidence")
EOF

cat "${OUT_DIR}/summary.txt"
echo
echo "Artifacts saved under ${OUT_DIR}"
