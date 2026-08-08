/* main.c — control lands here after boot.S clears registers, installs
 * mtvec, and opens PMP. This minimal main does nothing but wait for
 * an interrupt.
 *
 * This is the intended extension point for real firmware logic:
 * enable specific interrupt sources in mie, register real dispatch
 * in the trap handler (see boot.S / trap_handler), and replace the
 * body of the loop below with actual application code.
 */

static inline void wfi(void)
{
    __asm__ volatile ("wfi");
}

void main(void)
{
    for (;;) {
        wfi();
    }
}