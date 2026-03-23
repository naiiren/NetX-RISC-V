#!/usr/bin/env bash
# build_tests.sh – compile custom test programs for the NetX RV32I harness.
#
# Produces build artifacts in scripts/ and copies runtime images
#   <name>.hex  (instruction memory image)
#   <name>.data (data memory image, zero-initialised)
# into custom_cases/ so `rv32i_test --dir custom_cases` can run them.
#
# Usage:
#   cd <repo_root>
#   bash scripts/build_tests.sh
#   bash scripts/build_tests.sh gcd
#   bash scripts/build_tests.sh scripts/gcd.c
#
# Requirements:
#   clang (with riscv32-unknown-elf target support)
#   llvm-objcopy
#   python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_DIR}/custom_cases"

CLANG="${CLANG:-clang}"
OBJCOPY="${OBJCOPY:-llvm-objcopy-20}"
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
    -T "${SCRIPT_DIR}/link.ld"
)

TEST_NAMES=(
    sort
    poly
    fib
    gcd
    prime
    matrix
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
        printf '%s\n' "${SCRIPT_DIR}/${arg}.c"
    fi
}

build_test() {
    local name="$1"
    local sources=("${@:2}")

    echo "==> Building ${name} ..."

    local elf="${SCRIPT_DIR}/${name}.elf"
    local bin="${SCRIPT_DIR}/${name}.bin"
    local hex="${SCRIPT_DIR}/${name}.hex"
    local dat="${SCRIPT_DIR}/${name}.data"
    local out_hex="${OUT_DIR}/${name}.hex"
    local out_dat="${OUT_DIR}/${name}.data"

    mkdir -p "${OUT_DIR}"

    "${CLANG}" "${CFLAGS[@]}" "${sources[@]}" -o "${elf}"

    local rodata_size
    rodata_size=$(llvm-objdump-20 -h "${elf}" 2>/dev/null \
        | awk '/\.rodata/ {print $3; found=1} END {if (!found) print "0"}')
    if [[ "${rodata_size}" != "0" && "${rodata_size}" != "00000000" ]]; then
        echo "WARNING: ${name}.elf has non-empty .rodata (${rodata_size} bytes)."
        echo "         Load instructions cannot reach instruction memory –"
        echo "         constant-pool accesses will silently read zero from data memory."
    fi

    "${OBJCOPY}" -O binary --only-section=.text "${elf}" "${bin}"

    "${PYTHON}" "${SCRIPT_DIR}/bin2hex.py" "${bin}" > "${hex}"

    printf '@00000000\n' > "${dat}"

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
        "${SCRIPT_DIR}/start.s" \
        "${source_file}"
    BUILT_NAMES+=("${name}")
done

for name in "${BUILT_NAMES[@]}"; do
    rm -f \
        "${SCRIPT_DIR}/${name}.elf" \
        "${SCRIPT_DIR}/${name}.bin" \
        "${SCRIPT_DIR}/${name}.hex" \
        "${SCRIPT_DIR}/${name}.data"
done
echo "Cleaned generated custom test artifacts."
