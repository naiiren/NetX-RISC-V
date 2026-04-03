#!/usr/bin/env bash
# build_tests.sh – compile custom test programs for the NetX RV32I harness.
#
# Produces temporary build artifacts in scripts/ and copies runtime images
#   <name>.hex  (instruction memory image)
#   <name>.data (data memory image)
# into custom_cases/ so `rv32i_test --dir custom_cases` can run them.
#
# Usage:
#   cd <repo_root>
#   bash scripts/build_tests.sh
#   bash scripts/build_tests.sh gcd
#   bash scripts/build_tests.sh workloads/gcd.c
#
# Requirements:
#   clang (with riscv32-unknown-elf target support)
#   llvm-objcopy
#   python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKLOAD_DIR="${REPO_DIR}/workloads"
OUT_DIR="${OUT_DIR:-${REPO_DIR}/custom_cases}"

CLANG="${CLANG:-clang}"
OBJCOPY="${OBJCOPY:-llvm-objcopy-20}"
OBJDUMP="${OBJDUMP:-llvm-objdump-20}"
PYTHON="${PYTHON:-python3}"

# Common clang flags for bare-metal RV32I
CFLAGS=(
    -target riscv32-unknown-elf
    -march=rv32i
    -mabi=ilp32
    -O0
    -nostdlib
    -nostartfiles
    -fno-stack-protector
    -fno-exceptions
    -T "${WORKLOAD_DIR}/link.ld"
    -Wl,--no-check-sections
)

TEST_NAMES=(
    sort
    poly
    fib
    gcd
    prime
    matrix
    switch
)

resolve_test_name() {
    local arg="$1"

    if [[ "${arg}" == *.c ]]; then
        basename "${arg}" .c
    else
        printf '%s\n' "${arg}"
    fi
}

resolve_test_source() {
    local arg="$1"

    if [[ "${arg}" == *.c ]]; then
        if [[ "${arg}" = /* ]]; then
            printf '%s\n' "${arg}"
        else
            printf '%s\n' "${REPO_DIR}/${arg}"
        fi
    else
        if [[ -f "${WORKLOAD_DIR}/${arg}.c" ]]; then
            printf '%s\n' "${WORKLOAD_DIR}/${arg}.c"
        else
            printf '%s\n' "${SCRIPT_DIR}/${arg}.c"
        fi
    fi
}

build_test() {
    local name="$1"
    local sources=("${@:2}")

    echo "==> Building ${name} ..."

    local elf="${SCRIPT_DIR}/${name}.elf"
    local text_bin="${SCRIPT_DIR}/${name}.text.bin"
    local data_bin="${SCRIPT_DIR}/${name}.data.bin"
    local hex="${SCRIPT_DIR}/${name}.hex"
    local dat="${SCRIPT_DIR}/${name}.data"
    local out_hex="${OUT_DIR}/${name}.hex"
    local out_dat="${OUT_DIR}/${name}.data"

    mkdir -p "${OUT_DIR}"

    "${CLANG}" "${CFLAGS[@]}" "${sources[@]}" -o "${elf}"

    "${OBJCOPY}" -O binary --only-section=.text "${elf}" "${text_bin}"
    "${PYTHON}" "${SCRIPT_DIR}/bin2hex.py" "${text_bin}" > "${hex}"

    local data_sections=()
    while read -r section_name; do
        data_sections+=("--only-section=${section_name}")
    done < <("${OBJDUMP}" -h "${elf}" 2>/dev/null | awk '
        $2 == ".data" || $2 == ".sdata" || $2 == ".rodata" || $2 ~ /^\.rodata\./ { print $2 }
    ')

    if [[ ${#data_sections[@]} -eq 0 ]]; then
        printf '@00000000\n' > "${dat}"
    else
        local data_addr
        data_addr=$("${OBJDUMP}" -h "${elf}" 2>/dev/null | awk '
            $2 == ".data" || $2 == ".sdata" || $2 == ".rodata" || $2 ~ /^\.rodata\./ {
                addr = strtonum("0x" $4);
                if (!found || addr < min) {
                    min = addr;
                    found = 1;
                }
            }
            END {
                if (found) {
                    printf "%u\n", min;
                } else {
                    print "0";
                }
            }
        ')

        "${OBJCOPY}" -O binary "${data_sections[@]}" "${elf}" "${data_bin}"
        "${PYTHON}" "${SCRIPT_DIR}/bin2hex.py" "${data_bin}" "$(( data_addr >> 2 ))" > "${dat}"
    fi

    cp "${hex}" "${out_hex}"
    cp "${dat}" "${out_dat}"

    echo "    -> ${out_hex}"
    echo "    -> ${out_dat}"
}

if [[ $# -gt 0 ]]; then
    TEST_ARGS=("$@")
else
    TEST_ARGS=("${TEST_NAMES[@]}")
fi

BUILT_NAMES=()
for arg in "${TEST_ARGS[@]}"; do
    name="$(resolve_test_name "${arg}")"
    source_file="$(resolve_test_source "${arg}")"

    if [[ ! -f "${source_file}" ]]; then
        echo "Missing test source: ${source_file}"
        exit 1
    fi

    echo "Generated ${name}.elf, ${name}.bin, ${name}.hex, ${name}.data"
    build_test "${name}" \
        "${WORKLOAD_DIR}/start.s" \
        "${source_file}"
    BUILT_NAMES+=("${name}")
done

for name in "${BUILT_NAMES[@]}"; do
    rm -f \
        "${SCRIPT_DIR}/${name}.elf" \
        "${SCRIPT_DIR}/${name}.text.bin" \
        "${SCRIPT_DIR}/${name}.data.bin" \
        "${SCRIPT_DIR}/${name}.hex" \
        "${SCRIPT_DIR}/${name}.data"
done
echo "Cleaned generated custom test artifacts."
