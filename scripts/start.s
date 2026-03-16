/* Bare-metal startup for RV32I test programs.
 * Sets up the stack pointer and calls main().
 * After main() returns a0 holds the result; we then
 * execute the magic instruction that the test harness
 * samples to decide pass/fail.
 */
    .section .text.start,"ax"
    .global  _start
_start:
    /* Stack pointer = 0x7FF0 (16-byte aligned, top of 32 KB data memory).
     * lui sp, 8   -> sp = 0x8000
     * addi sp, -16 -> sp = 0x7FF0
     */
    lui   sp, 8
    addi  sp, sp, -16

    /* Zero frame pointer for clean stack walks. */
    addi  fp, zero, 0

    jal   ra, main            /* return value ends up in a0 */

    .word 0xDEAD10CC          /* magic sentinel: harness reads a0 here */

1:  j     1b                  /* should never be reached */
