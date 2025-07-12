# NetX-RV32I Single Cycle CPU Core

This project uses [NetX](https://github.com/pascal-lab/NetX), the schematic hardware description language, to implement a single-cycle RISC-V RV32I CPU core following the design from [NJU ProjectN Lecture Notes](https://nju-projectn.github.io/dlco-lecture-note/index.html). The design is tested using the [official RISC-V test suite](https://github.com/riscv/riscv-tests), ensuring compliance with the RV32I instruction set architecture.

This project demonstrates how NetX's schematic model can be used to design digital systems where code is arranged to resemble the actual schematic diagram, making the design easier to understand and maintain.

## Architecture Overview

The CPU core follows the classic single-cycle RISC-V design:

![schematic](https://nju-projectn.github.io/dlco-lecture-note/_images/rv32isingle.png)

The design supports the following RV32I instructions:

- **R-Type**: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
- **I-Type**: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI, LB, LH, LW, LBU, LHU, JALR
- **S-Type**: SB, SH, SW
- **B-Type**: BEQ, BNE, BLT, BGE, BLTU, BGEU
- **U-Type**: LUI, AUIPC
- **J-Type**: JAL

## Project Structure

```
├── _netx.toml          # Project configuration file
├── rv32i.nx            # Main CPU core implementation
├── main.cpp            # C++ test harness and simulation driver
├── Makefile            # Build configuration
├── testcases/          # Instruction test cases
│   ├── *.hex           # Initial contents of the instruction memory
│   └── *.data          # Initial contents of the data memory
└── build/              # Build artifacts and outputs
```

## Getting Started

### Prerequisites

- [NetX](https://github.com/pascal-lab/NetX) compiler and simulator
- C++23 compatible compiler (clang++ recommended)

### Running Tests

Run the complete test suite:

```bash
make run
```

This will compile the NetX design and run it through all test cases using the C++ test harness.


## Development

### Core Components

The project consists of two main components:

- **`_netx.toml`**: Project configuration file specifying the main source file and dependencies on the [NetX-std](https://github.com/pascal-lab/NetX-std) library
- **`rv32i.nx`**: Main source file containing the schematic description of the CPU core, organized into the following components, each corresponding to a specific part of the CPU architecture:
  
  - Instruction Decoder
  - Register File (32×32-bit registers)
  - Arithmetic Logic Unit (ALU)
  - Immediate Generator
  - Branch Condition Logic
  - Program Counter (PC) logic
  - Memory Interface
  
  Note that the instruction memory and data memory are not implemented within the core itself, as the design targets on-chip memory for deployment. Instead, the core provides memory interfaces that can be connected to either on-chip memory blocks or simulated memory modules.

### Test Framework

The project includes a comprehensive C++ test harness (`main.cpp`) that:
- Implements a simulated memory system that interfaces with the NetX core design. The memory is initialized with test program data from the hex files in the `testcases/` directory
- Provides simulation stimuli to the CPU core, including clock generation and reset control
- Validates execution results against expected outputs (the x10 register should contain the value `0x00C0FFEE` after successful test program execution)

## FPGA Deployment

This project can be synthesized for FPGA implementation using the NetX toolchain. To generate Verilog code for synthesis:

```bash
nx dump _netx.toml --top CORE -o out.v
```

This command generates low-level Verilog code for the CPU core, which can then be synthesized using your preferred FPGA toolchain. The design has been successfully tested on the Terasic DE2-115 FPGA development platform using the DE2-115 System Builder and Intel Quartus Prime Lite Edition.

![FPGA](https://github.com/naiiren/NetX-RISC-V/blob/main/FPGA.jpg)
