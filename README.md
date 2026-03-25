# NetX RV32I Pipelined CPU

This repository contains a 5-stage pipelined RV32I CPU written in [NetX](https://github.com/pascal-lab/NetX), together with a C++ simulation harness, bare-metal C test programs, and an Intel Quartus FPGA wrapper for the Terasic DE2-115 platform.

The current core includes:

- 5 pipeline stages: `IF`, `ID`, `EX`, `MEM`, `WB`
- hazard handling and operand forwarding
- a small BTB-style branch predictor

The project is regression-tested against both the standard RV32I instruction tests and a set of larger custom C programs.

## Repository Layout

```text
├── _netx.toml          # NetX project configuration
├── Makefile            # Main build/test/FPGA entry points
├── main.cpp            # C++ simulator / test harness
├── src/
│   ├── rv32i.nx        # Top-level pipelined RV32I core
│   ├── alu.nx          # ALU and adder implementation
│   ├── branch.nx       # Branch predictor and branch comparison logic
│   └── fpga.nx         # FPGA-facing NetX helpers
├── testcases/          # Standard RV32I instruction tests
├── scripts/
│   ├── build_tests.sh  # Builds custom bare-metal C tests
│   ├── fpga_flow.sh    # End-to-end FPGA compile/program flow
│   ├── start.s         # Bare-metal startup stub
│   ├── link.ld         # Linker script for custom tests
│   └── *.c             # Custom benchmark / stress tests
├── custom_cases/       # Generated custom test images
├── fpga/
│   ├── rv32i_fpga.v    # Board wrapper and data-memory adapter
│   ├── ram_a.v         # Quartus-generated data memory IP
│   ├── ram_b.v         # Quartus-generated instruction memory IP
│   ├── rv32i_fpga.qsf  # Quartus project settings
│   ├── rv32i_fpga.qpf  # Quartus project file
│   ├── rv32i_fpga.sdc  # Timing constraints
│   └── unnamed.qsys    # Qsys system file used by the FPGA project
└── FPGA.jpg            # Board photo
```

## Prerequisites

For simulation:

- NetX compiler
- C++23 compiler
- `make`

For building custom bare-metal tests:

- `clang` with `riscv32-unknown-elf` target support
- `llvm-objcopy`
- `llvm-objdump`
- `python3`

For FPGA flow:

- Intel Quartus Prime Lite / Standard command-line tools
- `quartus_sh`
- `quartus_pgm`

## Simulation Workflow

Build the simulator:

```bash
make
```

Run the full regression suite:

```bash
make run
```

This runs:

- all standard tests in `testcases/`, i.e., the standard RV32I instruction tests
- all generated custom tests in `custom_cases/`, including `sort`, `poly`, `fib`, `gcd`, `prime`, and `matrix`, which are intended to stress recursion, stack traffic, loops and branches, load/store behavior, and predictor/redirect logic.

Other useful targets:

```bash
make raw      # disable native optimizations in the simulator
make debug    # enable trace output from main.cpp
make clean
```

## Custom Test Programs

Custom programs live in `scripts/` and are built into `custom_cases/`.

Build all default custom tests:

```bash
bash scripts/build_tests.sh
```

Build a single named test:

```bash
bash scripts/build_tests.sh gcd
```

Build directly from a source path:

```bash
bash scripts/build_tests.sh scripts/gcd.c
```

The generated outputs are:

- `custom_cases/<name>.hex` for instruction memory
- `custom_cases/<name>.data` for data memory

These images are what the simulator and FPGA flow consume.

## FPGA Flow

The FPGA project targets the DE2-115 wrapper in `fpga/rv32i_fpga.v`.

The wrapper currently:

- instantiates `CORE`
- uses `ram_b` for instruction memory
- uses `ram_a` plus a byte-enable adapter for data memory
- exposes `x10` on the seven-segment displays through the core output ports

Run the full FPGA flow for a prebuilt test image:

```bash
bash scripts/fpga_flow.sh gcd
```

This script:

1. regenerates `fpga/top.v` from NetX with `nx dump verilog`
2. converts `custom_cases/<test>.{hex,data}` into Quartus `.mif` files
3. runs a full Quartus compile
4. programs the board with `quartus_pgm`

If the custom image does not exist yet, build it first:

```bash
bash scripts/build_tests.sh gcd
bash scripts/fpga_flow.sh gcd
```

Also, a makefile target is available for the same flow:

```bash
make fpga TEST=gcd
```

![FPGA](https://github.com/naiiren/NetX-RISC-V/blob/main/FPGA.jpg)
