# boot.S — minimal M-mode bootstrap for reflexrv
#   1. Clear all general-purpose registers (x1-x31)
#   2. Set up the stack pointer (linker-provided _stack_top)
#   3. Install the trap vector (mtvec, Direct mode)
#   4. Open PMP entry 0 to the full address space (RWX, NAPOT)
#   5. Clear stale mip/mie, then jump to main()
#
# See ../rv_privileged_machine_level_isa_cheatsheet.md ("Trap Handling Flow")
# and ../rv_privileged_Smepmp_isa_cheatsheet.md for what each CSR write below
# does.

    .section .text.init
    .global _start
    .align  2

_start:
    # --- 1. Clear all GPRs except x0 (hardwired zero) ---
    li      x1,  0
    li      x2,  0
    li      x3,  0
    li      x4,  0
    li      x5,  0
    li      x6,  0
    li      x7,  0
    li      x8,  0
    li      x9,  0
    li      x10, 0
    li      x11, 0
    li      x12, 0
    li      x13, 0
    li      x14, 0
    li      x15, 0
    li      x16, 0
    li      x17, 0
    li      x18, 0
    li      x19, 0
    li      x20, 0
    li      x21, 0
    li      x22, 0
    li      x23, 0
    li      x24, 0
    li      x25, 0
    li      x26, 0
    li      x27, 0
    li      x28, 0
    li      x29, 0
    li      x30, 0
    li      x31, 0

    # --- 2. Set up the stack pointer (defined in linker.ld) ---
    la      sp, _stack_top

    # --- 3. Install the trap vector (mtvec MODE=0, Direct) ---
    la      t0, trap_handler
    csrw    mtvec, t0

    # --- 4. Open PMP entry 0 to the full address space ---
    #     NAPOT covering all of memory: pmpaddr0 = all 1s
    #     pmpcfg0[7:0]: L=0, A=NAPOT(11), X=1, W=1, R=1 -> 0x0F
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x0F
    csrw    pmpcfg0, t0

    # --- 5. Clear any stale pending/enabled interrupts, then enter main() ---
    csrw    mie, zero
    csrw    mip, zero
    call    main

    # main() should never return; if it does, spin forever
1:
    wfi
    j       1b

# trap_handler — minimal M-mode trap entry point.
#   main only WFI-loops, so nothing is pending yet; extend this with
#   real mcause dispatch once interrupt sources are wired up (see the
#   Machine-Level ISA cheatsheet's "Trap Handling Flow" section).
    .align  2
trap_handler:
    mret