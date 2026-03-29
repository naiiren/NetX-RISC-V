# NetX RV32I System On DE2-115

This repository contains a 5-stage pipelined RV32I CPU written in [NetX](https://github.com/pascal-lab/NetX), a simulator, bare-metal test/demo programs, and an Intel Quartus FPGA wrapper for the Terasic DE2-115 board.

The current FPGA system includes:

- `CORE`: 5-stage pipelined RV32I CPU
- `LCD_DRIVER`: HD44780-compatible on-board LCD driver
- `PS2_KEYBOARD_DRIVER`: PS/2 keyboard MMIO peripheral
- `VGA_DRIVER`: VGA text display pipeline

## Repository Layout

```text
├── _netx.toml
├── Makefile
├── main.cpp
├── src/
│   ├── rv32i.nx
│   ├── alu.nx
│   ├── branch.nx
│   └── fpga.nx
├── scripts/
│   ├── build_tests.sh
│   ├── fpga_flow.sh
│   ├── start.s
│   ├── link.ld
│   ├── lcd.c
│   ├── vga.c
│   └── system.c
├── testcases/
├── custom_cases/
├── fpga_cases/
└── fpga/
    ├── rv32i_fpga.v
    ├── top.v
    ├── io_periph.v
    ├── kbd_periph.v
    ├── vga_periph.v
    ├── ram_a.v
    ├── ram_b.v
    ├── ram_c.v
    ├── rv32i_fpga.qsf
    ├── rv32i_fpga.qpf
    └── rv32i_fpga.sdc
```

## Build And Simulate

Build the simulator:

```bash
make
```

Run the CPU regression suite:

```bash
make run
```

Useful variants:

```bash
make raw
make debug
make clean
```

## Build Bare-Metal Programs

Build all default custom programs:

```bash
bash scripts/build_tests.sh
```

Build a single program:

```bash
bash scripts/build_tests.sh scripts/netx_system_demo.c
```

Generated outputs are:

- `<name>.hex` for instruction memory
- `<name>.data` for data memory

Default regression outputs go to `custom_cases/`. FPGA demo outputs go to `fpga_cases/`.

## FPGA System

### Top-Level Pieces

The DE2-115 FPGA build is split across:

- [src/fpga.nx](https://github.com/naiiren/NetX-RISC-V/blob/main/src/fpga.nx)
  - `LCD_DRIVER`
  - `PS2_KEYBOARD_DRIVER`
  - `VGA_DRIVER`
- [fpga/rv32i_fpga.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/rv32i_fpga.v)
  - board wrapper
  - memory adapters
  - peripheral wiring
- generated NetX Verilog
  - [fpga/top.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/top.v)
  - [fpga/io_periph.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/io_periph.v)
  - [fpga/kbd_periph.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/kbd_periph.v)
  - [fpga/vga_periph.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/vga_periph.v)

### Memory Layout

The board design currently uses three Quartus RAM/IP blocks:

- [fpga/ram_b.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/ram_b.v)
  - instruction memory
- [fpga/ram_a.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/ram_a.v)
  - CPU data memory
- [fpga/ram_c.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/ram_c.v)
  - VGA text / graphics memory

### Peripherals

- `LCD_DRIVER`
  - drives the on-board HD44780-compatible character LCD
  - maintains a small text shadow RAM for LCD updates
- `PS2_KEYBOARD_DRIVER`
  - exposes keyboard status/data through MMIO
  - uses `PS2_KEYBOARD` to capture scan-code bytes into a FIFO
- `VGA_DRIVER`
  - drives the VGA timing and text rendering path
  - reads display data from dedicated VGA memory

### Build Modes

There are two practical FPGA flow modes:

- core-only test flow
  - uses the CPU plus standard board wrapper
  - good for instruction/custom testcase validation
- system/peripheral flow
  - regenerates and includes the LCD, keyboard, and VGA peripherals
  - used by the interactive demos in `fpga_cases/`

### FPGA Targets

Core testcase flow:

```bash
make fpga TEST=gcd
```

Interactive/demo flows:

```bash
make fpga-lcd
make fpga-vga
make fpga-system
```

### What `scripts/fpga_flow.sh` Does

The FPGA script:

1. regenerates NetX Verilog for the selected build mode
2. updates instruction/data memory initialization files
3. reuses the Quartus build when possible
4. runs Quartus compile/program steps for the board

In peripheral mode it regenerates:

- [fpga/io_periph.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/io_periph.v)
- [fpga/kbd_periph.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/kbd_periph.v)
- [fpga/vga_periph.v](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/vga_periph.v)

### Quartus Project Files

The Quartus project lives under [fpga/](https://github.com/naiiren/NetX-RISC-V/tree/main/fpga):

- [rv32i_fpga.qsf](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/rv32i_fpga.qsf)
  - pin assignments and file list
- [rv32i_fpga.qpf](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/rv32i_fpga.qpf)
  - Quartus project descriptor
- [rv32i_fpga.sdc](https://github.com/naiiren/NetX-RISC-V/blob/main/fpga/rv32i_fpga.sdc)
  - timing constraints

## Demo Programs

The main interactive demo is the Scheme-style system demo:

```bash
make fpga-system
```

This demo currently uses:

- VGA for the REPL display and logo
- LCD for compact status/debug information
- PS/2 keyboard input
