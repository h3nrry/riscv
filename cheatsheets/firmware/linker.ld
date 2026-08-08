/* linker.ld — minimal loader script for the reflexrv firmware
 * (boot.S + main.c). Defines a single RAM region and the
 * section-placement table boot.S depends on (_stack_top symbol).
 *
 * Adjust ORIGIN/LENGTH to match your target platform's actual RAM.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    /* _start must land first so the reset vector / entry point is at
     * the base of RAM. */
    .text.init : {
        *(.text.init)
    } > RAM

    .text : {
        *(.text)
        *(.text.*)
    } > RAM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > RAM

    .data : {
        . = ALIGN(8);
        _data_start = .;
        *(.data)
        *(.data.*)
        _data_end = .;
    } > RAM

    .bss : {
        . = ALIGN(8);
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* Reserve a small heap (unused by this minimal example, but kept
     * so main.c can grow into malloc-based firmware without editing
     * the linker script). */
    . = ALIGN(16);
    _heap_start = .;
    . = . + 4K;
    _heap_end = .;

    /* Reserve the boot/interrupt stack; boot.S points sp at _stack_top. */
    . = ALIGN(16);
    _stack_bottom = .;
    . = . + 4K;
    _stack_top = .;

    /* Fail the build early if RAM is exhausted. */
    ASSERT(. <= ORIGIN(RAM) + LENGTH(RAM), "linker.ld: RAM overflow — shrink heap/stack or grow LENGTH(RAM)")
}