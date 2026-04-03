/* Linker script for bare-metal RV32I test programs.
 *
 * The CPU uses a Harvard memory layout:
 *   - Instruction memory: byte addresses 0x0000 – 0x1FFFF
 *   - Data memory:        byte addresses 0x0000 – 0x1FFFF
 *
 * The two address spaces overlap numerically but are physically
 * distinct, so .text and .data can both start at address 0 in
 * separate memory regions and be emitted into different init images.
 */

ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 128K
    DMEM (rwx) : ORIGIN = 0x00000000, LENGTH = 128K
}

SECTIONS
{
    .text : {
        /* Put the startup stub first so the reset vector at 0x0 jumps
         * straight into _start. */
        *(.text.start*)
        *(.text*)
    } > IMEM

    .data : {
        *(.sdata*)
        *(.data*)
        *(.rodata*)
        *(.rodata.*)
    } > DMEM

    .bss (NOLOAD) : {
        *(.sbss*)
        *(.bss*)
        *(COMMON)
    } > DMEM

    /DISCARD/ : {
        *(.eh_frame*)
        *(.comment*)
        *(.riscv.attributes)
    }
}
