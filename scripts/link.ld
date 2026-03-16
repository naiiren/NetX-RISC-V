/* Linker script for bare-metal RV32I test programs.
 *
 * The CPU uses a Harvard memory layout:
 *   - Instruction memory: byte addresses 0x0000 – 0x7FFF
 *     (initialised from the .hex file; not accessible via load/store)
 *   - Data memory:        byte addresses 0x0000 – 0x7FFF
 *     (initialised from the .data file; stack lives here)
 *
 * We therefore place the entire program (startup, code, read-only
 * constants) flat in .text at address 0.  Any genuine .data / .bss
 * cannot be automatically mirrored to data memory, so we discard
 * them – all writable state must live on the stack.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x00000000;

    .text : {
        /* Put the startup stub first so the reset vector at 0x0 jumps
         * straight into _start. */
        *(.text.start*)
        *(.text*)
        /* Place read-only data inside the instruction image.
         * WARNING: this data is NOT reachable via lw/lh/lb because
         * loads go to data memory.  Keep .rodata empty in practice. */
        *(.rodata*)
    }

    /* Discard everything else – no C runtime, no dynamic linking. */
    /DISCARD/ : {
        *(.data*)
        *(.bss*)
        *(.eh_frame*)
        *(.comment*)
        *(.riscv.attributes)
    }
}
