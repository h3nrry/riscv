# RISC-V Low-Power Design — 100 Q&A + 25 RTL Coding Exercises

A study/reference set covering low-power design techniques applicable to RISC-V CPU implementation: power fundamentals, clock gating, power gating, DVFS, low-power microarchitecture, memory design, RTL coding practices, RISC-V-specific low-power features, verification (UPF), and system-level SoC techniques — followed by 25 hands-on RTL coding exercises with Verilog solutions.

## Table of Contents

1. [Power Fundamentals](#a-power-fundamentals-q1-q10) (Q1–Q10)
2. [Clock Gating](#b-clock-gating-q11-q22) (Q11–Q22)
3. [Power Gating & Multi-Threshold CMOS](#c-power-gating--multi-threshold-cmos-q23-q34) (Q23–Q34)
4. [Voltage & Frequency Scaling (DVFS/DVS)](#d-voltage--frequency-scaling-dvfsdvs-q35-q44) (Q35–Q44)
5. [Low-Power Microarchitecture Techniques](#e-low-power-microarchitecture-techniques-q45-q56) (Q45–Q56)
6. [Low-Power Memory Design](#f-low-power-memory-design-q57-q66) (Q57–Q66)
7. [RTL / Design Coding Techniques for Low Power](#g-rtl--design-coding-techniques-for-low-power-q67-q76) (Q67–Q76)
8. [RISC-V Specific Low-Power Features](#h-risc-v-specific-low-power-features-q77-q86) (Q77–Q86)
9. [Low-Power Verification (UPF/CPF)](#i-low-power-verification-upfcpf-q87-q94) (Q87–Q94)
10. [System-Level / SoC Low-Power Techniques](#j-system-level--soc-low-power-techniques-q95-q100) (Q95–Q100)
11. [RTL Coding Exercises](#rtl-coding-exercises-rtl1-rtl25) (RTL1–RTL25)

---

## A. Power Fundamentals (Q1–Q10)

**Q1. What are the two main components of power dissipation in a CMOS digital circuit?**
Dynamic power, consumed when transistors switch state (charging/discharging capacitance) and from short-circuit current during transitions, and static (leakage) power, consumed continuously even when transistors are idle, due to subthreshold leakage, gate leakage, and other off-state currents.

**Q2. What is the standard equation for CMOS dynamic power, and what does each term represent?**
P_dynamic = α × C × V² × f, where α is the switching activity factor (fraction of gates/nets toggling per cycle), C is the total switched capacitance, V is supply voltage, and f is clock frequency. This equation is the reason voltage reduction is such a powerful lever — power scales with the square of voltage.

**Q3. Why does reducing supply voltage have a quadratically larger effect on dynamic power than reducing frequency?**
Because voltage appears squared in the dynamic power equation while frequency appears linearly — halving voltage cuts dynamic power to roughly a quarter, while halving frequency only cuts it in half (and also halves throughput), which is why voltage scaling is prioritized over pure frequency scaling wherever timing margins allow it.

**Q4. What is leakage (static) power, and why has it become a larger fraction of total power in modern process nodes?**
Leakage power is current that flows through a transistor even when it is nominally "off," due to physical effects like subthreshold conduction, gate oxide tunneling, and junction leakage. As process nodes have shrunk, thinner gate oxides and lower threshold voltages (needed to keep transistors fast at lower supply voltages) have made leakage current proportionally much larger, to the point that in advanced nodes it can rival or exceed dynamic power for otherwise-idle logic.

**Q5. What is the difference between power and energy, and why does this distinction matter for battery-powered RISC-V designs?**
Power is the instantaneous rate of energy consumption (watts), while energy is power integrated over time (joules) — the actual quantity that drains a battery. A design that runs at high power for a short burst and then sleeps can consume less total energy than one that runs at low power continuously for a long time, so battery-life-critical designs (like Nano-tier microcontrollers) often optimize for energy-per-task ("race to sleep") rather than minimizing instantaneous power alone.

**Q6. What is "race to idle" (or "race to sleep"), and why is it a common strategy for low-power microcontroller cores?**
It's the strategy of running at the highest efficient performance to finish a task as quickly as possible, then entering a low-power sleep/idle state for the remaining time, rather than running slower for longer at lower power. Because sleep-state power is often orders of magnitude lower than active power, minimizing total active time frequently saves more total energy than a slower, power-throttled execution of the same task.

**Q7. What is switching activity factor (α), and what design choices influence it?**
It's the average fraction of a circuit's nodes that transition (0→1 or 1→0) per clock cycle. It's influenced by workload characteristics (data patterns, instruction mix), microarchitectural choices (how much redundant computation happens even on unused paths), and RTL coding style (e.g., whether unused datapath branches are allowed to toggle even when their result is discarded).

**Q8. What is short-circuit power, and when is it significant?**
Short-circuit power arises briefly during a logic gate's transition, when both the pull-up (PMOS) and pull-down (NMOS) networks are partially conducting simultaneously, creating a brief direct current path from supply to ground. It becomes significant when input signal transition times (slew rates) are slow relative to the gate's switching threshold, which is why timing/slew constraints in synthesis and place-and-route also have power implications, not just timing implications.

**Q9. What is the "power wall," and how does it relate to why low-power design became a first-class design concern rather than an afterthought?**
The power wall refers to the point where continuing to increase clock frequency and transistor density (per classic Dennard scaling assumptions) stopped yielding proportional performance gains without unacceptable power/heat consequences, because voltage scaling could no longer keep pace with density scaling. This forced the industry to treat power as a primary design constraint alongside performance and area, rather than something addressed only at the end of a design flow.

**Q10. What is Energy-Delay Product (EDP), and why is it a useful combined metric for evaluating low-power design tradeoffs?**
EDP = Energy × Delay (or execution time), a single figure of merit that penalizes designs that save energy only by becoming proportionally slower (since delay is also in the product) and penalizes designs that are fast but energy-hungry. It's useful because pure energy minimization alone can favor an unrealistically slow design, while pure performance maximization can favor an unrealistically power-hungry one — EDP (and variants like Energy-Delay² Product) balance both concerns for a given target application.

---

## B. Clock Gating (Q11–Q22)

**Q11. What is clock gating, at a conceptual level?**
Clock gating disables (stops toggling) the clock signal feeding a register, register bank, or entire functional block when that logic doesn't need to update on a given cycle, preventing unnecessary switching activity in the clock tree and downstream sequential logic — a major contributor to dynamic power since the clock is typically the highest-toggling, highest-capacitance net in a synchronous design.

**Q12. Why is clock gating considered one of the highest-leverage low-power techniques in digital design?**
Because the clock network itself (clock tree buffers, clock pins on every flip-flop) often accounts for a disproportionately large fraction of total dynamic power in a synchronous chip — commonly cited estimates range from 20-45% of total dynamic power — so preventing clock toggling on idle logic directly removes a large, easily targeted power cost without altering functional behavior.

**Q13. What is an Integrated Clock Gating (ICG) cell, and why is it preferred over gating the clock with a plain AND gate?**
An ICG cell combines a transparent latch (or equivalent glitch-free enable-capture logic) with the gating AND gate, so the enable signal is captured and held stable for the full low phase of the clock before gating — preventing glitches on the gated clock output that a naive combinational AND-gate approach could produce if the enable signal changes asynchronously relative to the clock edge.

**Q14. Why would a plain combinational AND gate used to gate a clock risk producing a glitch?**
If the enable signal transitions while the clock is high, a combinational AND gate would immediately pass that transition through to the gated clock output, potentially creating a spurious extra clock edge (glitch) that could cause downstream flip-flops to capture data incorrectly — the latch inside a proper ICG cell prevents this by only allowing the enable to take effect while the clock is already low.

**Q15. What is the difference between "fine-grained" and "coarse-grained" clock gating?**
Fine-grained clock gating gates individual registers or small groups of registers based on very specific enable conditions (e.g., a single pipeline register only clocked when its stage is active). Coarse-grained clock gating gates an entire functional block or clock domain (e.g., the whole multiplier unit, or an entire unused peripheral) based on a broader "is this block needed at all right now" condition, trading some potential power savings for simpler control logic and less clock-tree fragmentation.

**Q16. How does clock gating interact with pipeline stall logic (e.g., a load-use hazard stall)?**
The same "bubble insertion" control signals that hold a pipeline register's value during a stall (rather than advancing it) are natural candidates to also gate that register's clock during the stalled cycle — since the register isn't supposed to change anyway, gating its clock during the stall saves the switching power of re-writing the identical value, in addition to the functional stall behavior.

**Q17. What is "clock gating efficiency," and how is it typically measured or estimated?**
It's the percentage of clock cycles (or clock-tree power) actually saved by gating, relative to an ungated baseline — often estimated during RTL/gate-level simulation by measuring what fraction of registers had their clock enable de-asserted (i.e., were held stable) across a representative workload, then correlating that with power estimation tools.

**Q18. Why is automatic clock gating insertion (a synthesis tool feature) often preferred over hand-instantiating ICG cells everywhere in RTL?**
Automatic clock gating insertion (common in modern synthesis tools) analyzes RTL for common patterns like `if (enable) reg <= data; else reg <= reg;` (a register holding its own value) and automatically infers and inserts ICG cells at those points, reducing designer effort, ensuring consistent application across a large design, and letting the tool make gating-granularity tradeoffs during optimization rather than requiring every instance to be hand-coded.

**Q19. What RTL coding pattern typically triggers automatic clock-gating inference by synthesis tools?**
A register that is conditionally updated and otherwise explicitly holds its previous value, e.g.:
```verilog
always @(posedge clk) begin
    if (enable)
        data_reg <= data_in;
    // implicit else: data_reg holds its value
end
```
Synthesis tools recognize this "enable-controlled hold" pattern and can automatically convert it into a clock-gated register rather than a register with a feedback mux, saving both area and power compared to the naive mux-based implementation.

**Q20. Why is a clock-gated register generally more power-efficient than a functionally equivalent register with a feedback multiplexer holding its own output?**
A feedback-mux implementation still toggles the register's clock every cycle and still re-writes (and thus internally switches some capacitance for) the same value, whereas clock gating stops the clock itself from toggling at that register, eliminating essentially all of that register's dynamic power for the held cycle rather than just avoiding an externally visible value change.

**Q21. What risk does clock gating introduce for timing/verification, and how is it typically mitigated?**
Clock gating adds a functional dependency between the enable-generation logic and the clock tree, meaning bugs in the enable logic (e.g., gating the clock incorrectly during a cycle that actually needed to update) can cause silent functional failures that are easy to miss in purely functional (non-gated) RTL simulation. This is mitigated by simulating with clock-gating models enabled, using formal/low-power-aware verification tools, and applying UPF-based low-power verification flows that explicitly check gating behavior.

**Q22. Why might a low-end microcontroller-class core (like a Nano tier) rely more heavily on coarse-grained clock gating (whole blocks) than fine-grained per-register gating?**
Fine-grained gating adds ICG cells and enable-generation logic at many points, which costs area and design/verification complexity — overhead that a minimal-area, cost-sensitive MCU-class core may not be able to afford relative to the power savings gained, so coarse block-level gating (e.g., gating an entire unused peripheral or the whole core during WFI) often gives the best power-savings-per-design-effort tradeoff at that tier.

---

## C. Power Gating & Multi-Threshold CMOS (Q23–Q34)

**Q23. What is power gating, and how does it differ from clock gating?**
Power gating completely cuts off the supply voltage to a block of logic (using header/footer switch transistors) when it's not needed, eliminating both dynamic AND static (leakage) power for that block. Clock gating only stops switching activity (dynamic power) — the logic remains powered and continues to leak, so power gating is a strictly more aggressive (and higher-savings, higher-overhead) technique.

**Q24. What is a power switch (header/footer transistor), and what role does it play in power gating?**
A power switch is a large transistor (typically high-Vt, low-leakage) placed between the always-on power supply rail and a switchable "virtual" supply rail feeding a block of logic; turning the switch off disconnects the block from power, and turning it on reconnects it. Headers use PMOS switches on the VDD side; footers use NMOS switches on the ground side.

**Q25. What is a "virtual VDD" (or virtual ground) rail in a power-gated design?**
It's the internal supply rail that actually feeds the gated logic block, distinct from the always-on real VDD/VSS rails — it only carries power when the associated power switch is enabled, and its voltage sags to near-zero (or floats) when the switch is off, which is exactly the desired power-off behavior for that domain.

**Q26. What is an isolation cell, and why is it required at the boundary of a power-gated domain?**
An isolation cell clamps the output of a power-gated block to a defined, stable logic value (0, 1, or a held/latched value) whenever that block's power is off, preventing its outputs from floating to an undefined or intermediate voltage that could cause spurious switching, excessive leakage, or even damage in the still-powered logic receiving those signals.

**Q27. What is a retention flip-flop (or "balloon" flip-flop), and what problem does it solve?**
A retention flip-flop contains a small, always-on shadow storage element (often a low-leakage latch) that saves its data before the main flip-flop's power domain is shut off, and restores that data when the domain powers back up — solving the problem of losing register state entirely across a power-gating cycle, without needing to power an entire block continuously just to preserve a few bits of context.

**Q28. Why can't ordinary flip-flops simply be power-gated the same way as combinational logic?**
Ordinary flip-flops lose their stored state the moment power is removed, so if a design needs to resume exactly where it left off after waking from a power-gated sleep, the flops holding architecturally important state (e.g., register file contents, PC, control state) either need retention capability or must have their state explicitly saved to always-on memory before power-down and restored afterward.

**Q29. What is Multi-Threshold CMOS (MTCMOS), and how does it relate to power gating?**
MTCMOS is a standard-cell library technique that provides both low-Vt (fast but leaky) and high-Vt (slower but low-leakage) transistor variants in the same process. It relates to power gating because the header/footer power-switch transistors themselves are typically implemented in high-Vt cells (to minimize leakage through the switch when it's supposed to be "off"), while the timing-critical logic inside the gated domain may still use low-Vt cells for speed.

**Q30. What is the tradeoff between using high-Vt versus low-Vt cells in a given logic path?**
High-Vt cells switch more slowly (higher delay) but leak significantly less current when idle; low-Vt cells switch faster but leak more. Designers typically use low-Vt cells only on genuinely timing-critical paths and high-Vt cells everywhere else (a technique often automated via "Vt swapping" during synthesis/optimization), balancing overall leakage against meeting the clock frequency target.

**Q31. What is "power-up sequencing," and why does it matter when re-enabling a power-gated domain?**
Power-up sequencing is the controlled, staged process of re-energizing a power-gated domain — typically ramping the power switch on gradually (or in stages) rather than instantaneously, because an abrupt full-current inrush when a large domain powers up simultaneously can cause a significant voltage droop on the shared power grid, potentially disturbing other still-active domains.

**Q32. What is a power state machine (or power management FSM), and what does it typically control?**
It's a dedicated control FSM (often part of an on-chip Power Management Unit) that sequences the steps of entering and exiting a low-power state: asserting isolation, triggering state retention/save, disabling the clock, then powering down; and in reverse for wake-up — power-up, wait for stable rails, release reset, restore retained state, disable isolation, and re-enable the clock, all in the correct order to avoid glitches or corrupted state.

**Q33. Why is the order of operations (isolate → retain → clock-gate → power-gate, and the reverse on wake) important rather than doing all steps simultaneously?**
Performing steps out of order can cause failures — e.g., removing power before isolation is active would let the domain's outputs float into downstream logic; releasing isolation before power/clock are stable on wake-up could feed unstable transient signals to other domains. The sequencing exists specifically to guarantee that at every intermediate moment, the rest of the chip only ever sees well-defined signal values from the domain being powered down or up.

**Q34. What additional leakage-reduction technique, distinct from full power gating, can be applied to SRAM/register-file arrays specifically, and why is it used instead of full shutdown there?**
Data-retention low-voltage modes (sometimes called "sleep mode" or "drowsy mode" for SRAM) reduce — but don't eliminate — the supply voltage to a memory array, cutting leakage substantially while still retaining stored data, unlike full power gating which would lose the data. This is used for memory specifically because content preservation without a separate save/restore mechanism is often more valuable there than the additional leakage savings of a full power-off.

---

## D. Voltage & Frequency Scaling (DVFS/DVS) (Q35–Q44)

**Q35. What is Dynamic Voltage and Frequency Scaling (DVFS)?**
DVFS is a runtime technique that adjusts both the supply voltage and clock frequency of a processor (typically together, since a lower voltage can only reliably support a lower maximum frequency) based on current performance demand, trading performance for power savings when full performance isn't needed, and vice versa when it is.

**Q36. Why must voltage and frequency typically be scaled together, rather than frequency alone?**
Because a digital circuit's maximum reliable operating frequency is fundamentally limited by gate delay, which increases as supply voltage decreases — running at a high frequency with insufficiently high voltage risks setup-time violations and incorrect operation, so a lower target frequency is what actually permits safely lowering the voltage (which is where most of the power savings, being quadratic in voltage, actually come from).

**Q37. What is a Dynamic Voltage Scaling (DVS) curve (or V-f curve), and what does it define for a chip?**
It's a characterization curve, typically determined through silicon characterization and specified in a chip's power management data, mapping each supported frequency to the minimum safe voltage needed to operate reliably at that frequency across process, voltage, and temperature (PVT) variation — the operating points a DVFS controller is allowed to select between.

**Q38. What is Adaptive Voltage Scaling (AVS), and how does it differ from a fixed DVFS lookup table?**
AVS uses real-time feedback (e.g., from on-chip critical-path replica circuits or performance monitors) to dynamically fine-tune the actual supply voltage for a given frequency, compensating for process variation, temperature, and aging on a per-chip or per-moment basis, rather than relying on a single conservative fixed voltage that must cover worst-case conditions for every chip — this typically yields additional power savings versus a static DVFS table, at the cost of extra monitoring hardware.

**Q39. Why does a fixed (non-adaptive) DVFS table typically need extra voltage margin compared to what a specific chip actually requires?**
Because a single voltage value in the table must work correctly across all manufactured chips (accounting for process variation), across the full specified temperature range, and across the part's expected lifetime (accounting for aging effects like Negative Bias Temperature Instability), so the table is set conservatively for the worst-case combination even though most individual chips, most of the time, could run correctly at a somewhat lower voltage.

**Q40. What is a voltage regulator's transition/settling time, and why does it matter for how often DVFS can usefully switch operating points?**
It's the time required for the on-chip or off-chip voltage regulator to ramp from one voltage level to another and settle within tolerance; if DVFS transitions are requested more frequently than the regulator can settle, the system either can't actually reach the requested voltage before the next change or wastes time/energy in transition, so the DVFS policy's switching granularity must be matched to the regulator's actual capability.

**Q41. What is the difference between DVFS applied at the whole-chip level versus per-core (or per-domain) DVFS in a multi-core SoC?**
Whole-chip DVFS scales a single shared voltage/frequency for the entire chip, which is simpler but forces even idle or lightly loaded cores/blocks to run at whatever voltage the busiest core currently needs. Per-domain DVFS partitions the chip into independently scalable voltage/frequency domains, allowing, for example, one core to run at high performance while another (or a peripheral) runs at a much lower, more power-efficient point simultaneously — at the cost of additional regulators, level shifters, and control complexity.

**Q42. What is a level shifter, and why is it needed at the boundary between two different DVFS voltage domains?**
A level shifter is a circuit that translates a logic signal from one voltage domain's swing (e.g., 0–0.8V) to another's (e.g., 0–1.0V) so that signals crossing between domains operating at different voltages are interpreted correctly rather than being misread due to a mismatched logic threshold.

**Q43. Why is DVFS generally considered a poor fit for hard real-time, WCET-bounded cores, similar to the earlier reasoning against out-of-order execution?**
Because DVFS deliberately changes the processor's effective execution speed at runtime based on dynamic conditions, the same code sequence can take a different number of wall-clock cycles depending on the currently selected operating point — undermining the fixed, statically analyzable timing that real-time WCET guarantees require, unless the DVFS transitions themselves are tightly controlled and accounted for in the timing analysis (which is uncommon in simple real-time designs).

**Q44. What is race-to-idle combined with DVFS, and how can the two strategies conflict?**
Race-to-idle argues for running as fast as possible to finish quickly and then sleep, while naive DVFS-based power saving argues for slowing down to reduce instantaneous power during a task. The two can conflict because slowing a task down (lower DVFS point) to reduce power may keep the processor active for so much longer that total energy consumed is actually higher than finishing quickly at a higher operating point and then entering a deep sleep state — the correct choice depends on the relative power cost of "active-slow" versus "active-fast + sleep," which is workload- and platform-specific.

---

## E. Low-Power Microarchitecture Techniques (Q45–Q56)

**Q45. How does reducing pipeline depth generally help power, independent of any explicit gating technique?**
A shallower pipeline has fewer pipeline registers (each of which toggles and consumes clock/data switching power every cycle) and typically simpler, less speculative control logic (less branch-prediction hardware, fewer flushed/wasted speculative instructions), directly reducing both the switching activity and the leakage-contributing transistor count relative to a deeper, more aggressively performance-oriented pipeline — part of why the Nano tier deliberately uses only 2-3 stages.

**Q46. Why does avoiding out-of-order execution and wide superscalar issue reduce power significantly, beyond just avoiding wasted speculative work?**
OoO/superscalar structures (reservation stations, reorder buffers, register renaming tables, wide issue/wakeup logic) are inherently power-hungry because they involve broad associative comparisons (content-addressable-memory-like structures) and many parallel functional units that must be kept ready every cycle regardless of whether they're used, a fundamentally higher-overhead style of computation than a simple in-order pipeline performing the same useful work.

**Q47. What is operand isolation, and how does it reduce dynamic power in datapath logic like an ALU or multiplier?**
Operand isolation holds a functional unit's input operands stable (typically by feeding back the previous output or a fixed value through a mux, gated by an enable) whenever that unit's result won't actually be used that cycle, preventing the unit's internal combinational logic from uselessly toggling and burning switching power computing a result nobody needs.

**Q48. Give a concrete example of where operand isolation matters in a RISC-V pipeline.**
A multiplier or divider unit that sits in the datapath but isn't being used by the current instruction (e.g., an ADD instruction executing while the multiplier's inputs would otherwise still be connected to stale/toggling bus values) can have its inputs isolated/frozen, since letting the multiplier's internal logic continue switching on irrelevant data wastes significant dynamic power for zero useful output.

**Q49. Why is a simpler, non-speculative branch predictor (or none at all) sometimes chosen for low-power designs even beyond the WCET-determinism argument?**
Dynamic branch predictors (BTBs, pattern history tables, correlating predictors) require continuously-active storage structures that are read and updated every cycle regardless of whether their predictions are even needed for the current workload, consuming both dynamic (access) power and static (leakage, since the storage must stay powered) power — a cost that a low-power, area-constrained core may not be able to justify against the performance gain, especially if code size/loop structure is simple enough that misprediction penalties are already small.

**Q50. How does reducing datapath bit-width (or using narrower functional units where sufficient) save power?**
Every bit of datapath width adds capacitance that must be charged/discharged on each relevant operation; a narrower ALU, multiplier, or bus directly reduces the total switched capacitance for operations that don't need the full width, though this must be balanced against RISC-V's fixed 32/64-bit register width requirements — the technique applies more to internal implementation choices (e.g., iterative narrow multipliers) than to the externally visible ISA width.

**Q51. What is instruction/decode simplification, and why does it matter for power in microcontroller-class cores?**
Simplification means minimizing the complexity of the decode logic (e.g., using RISC-V's regular, fixed-format encoding directly rather than adding extensive pre-decoding, micro-op translation, or complex control-signal generation trees), since decode logic runs every single cycle for every fetched instruction and its complexity directly multiplies into both dynamic switching power and static leakage from its transistor count.

**Q52. Why might a low-power core deliberately choose a Harvard (separate I/D memory) rather than a von Neumann (unified memory) architecture, from a power perspective specifically?**
Beyond avoiding structural hazards, separate instruction and data memory ports/buses can each be sized, clocked, and power-managed independently and more simply, and avoid arbitration logic (which itself consumes power) that a shared unified memory port would need — though this must be weighed against the area/cost overhead of maintaining two separate memory interfaces.

**Q53. What is "clock tree power," and why is it disproportionately significant compared to its share of total logic?**
The clock tree (the network of buffers distributing the clock signal to every sequential element) toggles every single cycle at the full clock frequency with essentially 100% activity factor (α≈1), unlike most data logic which only toggles when relevant data changes — this near-constant, chip-wide toggling makes the clock tree one of the single largest concentrated sources of dynamic power in a synchronous design, which is exactly why clock gating (Q11-Q22) targets it directly.

**Q54. What is "useless toggling" in RTL, and how can careless coding style introduce it unintentionally?**
Useless toggling refers to signal transitions that don't affect any architecturally visible outcome but still consume switching power — for example, computing a full ALU result speculatively every cycle even when a `mux` immediately downstream will discard it based on some select signal, or driving a bus with a new value every cycle even when the receiving logic won't sample it. Careless RTL (e.g., always assigning a combinational result unconditionally rather than gating its computation with the actual "needed" condition) can introduce substantial hidden switching activity a purely functional simulation would never reveal.

**Q55. Why does a smaller instruction/data cache (or no cache at all, common in MCU-class Nano-tier designs) sometimes represent a better power tradeoff than a larger one, despite potentially more memory stalls?**
Larger caches have more SRAM cells that leak continuously and consume more read/write dynamic power per access due to longer bit-lines/word-lines, so for workloads with a small enough code/data footprint (typical of many microcontroller applications), a smaller cache (or tightly-coupled memory with deterministic single-cycle access) can consume meaningfully less total power while still meeting performance needs, without paying for capacity the workload doesn't use.

**Q56. What is "computation gating" (broader than clock/operand gating), and how does it apply at a microarchitectural level?**
Computation gating is the general principle of preventing any unnecessary work — not just register updates or single-operand toggling, but entire pipeline stages, functional units, or even whole cores — from performing computation when its result isn't needed, extending the same "don't do work nobody asked for" philosophy from the register level (clock gating) up to the block and system level (power gating unused functional units or cores entirely).

---

## F. Low-Power Memory Design (Q57–Q66)

**Q57. Why does SRAM (used for caches, register files, tightly-coupled memory) consume a disproportionate share of a chip's static (leakage) power?**
SRAM cells are built from multiple minimum-sized transistors (typically 6 per bit in a standard 6T cell) held in a bistable state continuously, and a chip may contain millions of these cells — since leakage is roughly proportional to transistor count and each cell leaks even while idle, the sheer density and cell count of SRAM arrays makes them a leakage hotspot relative to their logic-gate-equivalent area.

**Q58. What is a 6T SRAM cell, and what is the general power/area/stability tradeoff versus alternative cell designs (e.g., 8T)?**
A 6T cell uses six transistors (two cross-coupled inverters plus two access transistors) and is the industry-standard, most area-efficient SRAM cell design. An 8T cell adds a separate read port (isolating the read path from the storage nodes), improving read stability and allowing lower minimum operating voltage (better for low-power retention), at the cost of roughly 33% more area per bit — a common area-vs-power-vs-stability tradeoff in memory-heavy low-power designs.

**Q59. What is memory bank/way power gating, and how does it apply to a cache specifically?**
Rather than power-gating an entire cache as one monolithic block, the cache is divided into smaller banks or ways, and only the banks/ways currently holding useful (recently used) data remain powered, while unused or cold banks are power-gated to save leakage — a finer-grained approach that captures power savings on partially-utilized caches without giving up the capacity that is actually in use.

**Q60. What is drowsy (or "sleepy") SRAM, and how does it differ from full power gating of a memory array?**
Drowsy SRAM reduces the supply voltage of an idle memory array to a level just above the minimum needed to retain stored data (a "data-retention voltage," well below the normal read/write operating voltage), significantly cutting leakage power while preserving contents, unlike full power gating which would lose the data entirely — trading some (but not all) leakage savings for the ability to "wake up" quickly without needing to reload data from a backing store.

**Q61. Why is data-retention voltage for SRAM typically well above 0V rather than being able to go all the way to zero while still retaining data?**
Below a certain minimum voltage (the retention voltage), the cross-coupled inverter pair inside an SRAM bit cell can no longer maintain a stable bistable state against noise and leakage imbalances between its two halves, and the stored bit can flip or become indeterminate — the retention voltage is the empirically/characterized minimum voltage at which the cell's bistability is still reliably guaranteed across process and temperature variation.

**Q62. What is memory access power, and what design choices reduce it independent of leakage considerations?**
Memory access (dynamic) power is consumed each time a memory array is actually read or written, dominated by charging/discharging long bit-lines and word-lines, sense-amplifier activation, and address decode logic; it can be reduced by techniques like sub-banking (shorter bit-lines per access), reducing unnecessary speculative/parallel bank reads (only activating the bank actually needed rather than all banks in parallel for a "way-predicted" cache access), and minimizing the number of read/write ports to only what's architecturally required.

**Q63. What is cache way-prediction, and how does it reduce dynamic power for a set-associative cache?**
Way prediction guesses which "way" (out of several possible locations in a set-associative cache) is likely to contain the requested data, based on prior access history, and activates only that predicted way's data array for the access instead of activating all ways in parallel (as a naive set-associative lookup would) and using a tag comparison to select the correct one afterward — since only one way's bit-lines and sense amps switch instead of all of them, this substantially cuts per-access dynamic power at the cost of occasional misprediction penalties (needing a second access if the prediction was wrong).

**Q64. Why might a register file be a particularly attractive target for aggressive low-power techniques in a small in-order core?**
The register file is accessed on essentially every single cycle (at least one read, often a write), making it one of the highest-activity-factor storage structures in the entire core — small savings per access, multiplied by extremely frequent access, can add up to a meaningful fraction of total core power, which is why techniques like write-first bypassing (avoiding redundant reads), minimizing port count to only what's architecturally necessary, and careful physical design of the register file macro are often prioritized.

**Q65. What is the power impact of using a flip-flop-based register file versus an SRAM-based one, and when is each typically chosen?**
Flip-flop-based register files have higher per-bit area and typically somewhat higher per-access dynamic power than dense SRAM, but offer single-cycle, multi-ported random access without the read/write timing constraints of SRAM and no minimum-voltage retention concerns — for a small register file (32 × 32-bit entries, common for RV32I), the total capacity is small enough that flip-flop implementation remains practical and is usually chosen for its simplicity and guaranteed single-cycle multi-port access, while SRAM is reserved for larger structures like caches.

**Q66. What is memory clock gating, and how does it differ from logic clock gating in terms of implementation constraints?**
Memory clock gating stops the clock to an SRAM/memory macro when no access (read or write) is occurring that cycle, similar in principle to logic clock gating, but memory macros are often provided as pre-characterized hard IP blocks (from a memory compiler) with specific, vendor-defined clock-gating and power-down interfaces (chip-select, clock-enable pins) that must be used exactly as specified, rather than allowing arbitrary custom ICG insertion the way general logic does.

---

## G. RTL / Design Coding Techniques for Low Power (Q67–Q76)

**Q67. What RTL coding practice helps synthesis tools automatically infer clock gating, and why does explicit manual muxing sometimes prevent it?**
Coding a register update with a clear, single enable condition (`if (enable) reg <= data;` with an implicit hold otherwise) lets synthesis tools cleanly recognize the clock-gating opportunity. Manually coding an equivalent feedback mux (`reg <= enable ? data : reg;`) can sometimes obscure this pattern from automatic clock-gating inference (depending on the specific tool and its pattern-matching rules), so many low-power design guidelines explicitly recommend the enable-conditional form.

**Q68. Why is it good low-power RTL practice to avoid unconditionally computing values that will be discarded by a later mux?**
If a combinational expression's result is going to be thrown away based on a select signal, computing it anyway still burns switching power for no architectural benefit; restructuring the logic so the computation itself is conditioned on the same select signal (or gating its inputs, per operand isolation) avoids the wasted toggling, though this must be balanced against added logic complexity and potential critical-path impact from the extra conditioning logic.

**Q69. What is a "one-hot" versus "binary" encoding choice for FSM states, and what's the general low-power tradeoff between them?**
One-hot encoding uses one flip-flop per state (only one bit set at a time), typically resulting in simpler, faster next-state logic per transition (fewer bits change per transition) but more total flip-flops. Binary encoding uses the minimum number of bits (log2 of state count) but can require more complex decode logic and, depending on the state transition graph, may cause more bits to toggle per transition — the power-optimal choice depends on the specific FSM's size and transition patterns, and is often something synthesis tools can re-evaluate during optimization.

**Q70. Why does minimizing unnecessary signal width (avoiding overly wide buses/registers "just in case") help both area and power?**
Every bit of width that isn't functionally necessary still requires physical wires, register bits, and logic that all contribute capacitance and potential leakage, even if that width is never actually used for meaningful data — RTL that sizes signals precisely to the actual required range （rather than rounding up "for safety" or convenience) avoids paying this ongoing power/area cost across the design's lifetime.

**Q71. What is the low-power implication of using synchronous versus asynchronous resets in RTL?**
Asynchronous resets require a reset signal to be routed as an additional input to every flip-flop's control logic and often need special reset-tree buffering/synchronization (to avoid reset removal timing issues), adding some area/power overhead versus synchronous resets, which reuse the existing data-path timing; the choice is usually driven more by functional/verification requirements (e.g., needing to reset even without a clock) than pure power optimization, but the power cost of the reset tree is a real, non-zero consideration in a highly power-constrained design.

**Q72. Why is it considered poor low-power RTL practice to drive a bus or memory with "don't care" (X) or default toggling values instead of holding the last value or a defined idle value?**
While `X` values are a simulation-only concept (not physically real in hardware), RTL that doesn't explicitly define a stable idle/hold value for a bus when it's not actively being used can synthesize into logic that ends up toggling unpredictably (following whatever upstream combinational logic happens to compute), wasting power; explicitly holding a bus at its last value or a fixed idle value when inactive (often via the same enable/clock-gating logic already in place) keeps that toggling contained.

**Q73. What is the power implication of finite state machine (FSM) idle-state design, and why should an FSM's idle state typically avoid driving active control signals?**
An FSM's idle (waiting/no-op) state should be coded so that all downstream control signals it drives default to their inactive/safe values, ensuring the rest of the datapath naturally quiesces (many enables de-asserted, many clock gates closed) whenever the FSM has nothing to do, rather than the idle state inadvertently leaving some enable asserted that keeps unrelated logic needlessly active.

**Q74. Why is simulation-based power estimation using switching activity (VCD/SAIF/FSDB files) from realistic workloads important, rather than relying only on static/vectorless power estimates?**
Static or vectorless power estimation tools must assume generic or worst-case toggle rates absent real data, which can significantly over- or under-estimate actual power for a specific design's real usage pattern; capturing actual switching activity from RTL or gate-level simulation running representative workloads and feeding that into a power analysis tool (e.g., via VCD/SAIF/FSDB activity files) gives a much more accurate picture of where real power is being spent, guiding where low-power effort should actually be focused.

**Q75. What is "don't-care" don't-toggle discipline in multiplexer/case-statement RTL, and why does it matter for power?**
It refers to deliberately ensuring that unselected branches of a mux or case statement don't have side effects that cause unrelated logic to toggle — for example, ensuring that in a `case` statement selecting an ALU operation, only the actually-selected operation's result feeds forward, rather than every possible operation being computed in parallel every cycle regardless of which one is selected (unless that parallel computation is specifically desired for timing reasons and justified against its power cost).

**Q76. Why do low-power design guidelines often recommend minimizing "glue logic" and keeping module boundaries clean, from a power perspective specifically (not just maintainability)?**
Excess glue logic (unnecessary buffering, redundant combinational reshaping of signals between modules) adds extra switching nodes that all consume some incremental dynamic power and occupy area that also leaks; clean, minimal interfaces between modules reduce the total gate count a synthesis tool has to work with, which — all else equal — tends to correlate with lower total switching capacitance and leakage across the design.

---

## H. RISC-V Specific Low-Power Features (Q77–Q86)

**Q77. What does the RISC-V `WFI` (Wait For Interrupt) instruction do, and how does it relate to low-power design?**
`WFI` is a hint instruction that tells the hart (hardware thread) it may safely stall/idle until an interrupt (or other wake event) becomes pending, giving the implementation an explicit, ISA-defined signal that it's safe to enter a low-power idle or sleep state — without `WFI`, hardware would have no clean, standard way to know a core is intentionally idle versus just executing a busy-wait loop.

**Q78. Why is `WFI` defined as a "hint" in the RISC-V specification rather than a strict architectural requirement?**
Because the specification allows implementations flexibility in how (or even whether) they actually reduce power in response to `WFI` — a minimal implementation is permitted to simply treat it as a NOP that does nothing special, while a power-optimized implementation can use it to trigger clock gating, power gating, or deeper sleep states; this flexibility lets the same software (using `WFI` correctly) run correctly, just with different power outcomes, across implementations from Nano to Apex.

**Q79. What typically happens at the microarchitectural level when a core executes `WFI` and there's no pending interrupt?**
The core typically gates its own clock (or, in more aggressive implementations, power-gates non-essential logic while retaining the ability to detect a wake event), halting instruction fetch/execution until an interrupt (or a configured wake condition) is detected, at which point the clock/power is restored and execution resumes at the instruction after `WFI`.

**Q80. What is the RISC-V Sstc/Sscofpmf and other privileged-mode extensions' relevance to power management, generally speaking?**
While these specific extensions address timer/counter and performance-monitoring functionality rather than power directly, the broader RISC-V privileged architecture (machine, supervisor, and now increasingly hypervisor-level control and status registers) provides the software-visible hooks — timers, interrupt sources, and control registers — that a power management unit or OS-level power governor needs to schedule wake events, decide when to enter/exit low-power states, and coordinate DVFS transitions.

**Q81. Does the base RISC-V ISA define a standardized set of low-power/sleep states (analogous to ACPI C-states), or is this left to implementers?**
The base ISA and privileged specification define the `WFI` instruction and basic interrupt/trap infrastructure, but do not mandate a specific standardized taxonomy of sleep/low-power states (like ACPI's C0-C6 states) — the specific number, depth, and entry/exit behavior of low-power states is generally left to individual implementations and their associated Power Management Unit design, though industry conventions (often informed by embedded/mobile SoC practice) tend to converge on similar concepts (active, idle/clock-gated, sleep/power-gated-with-retention, deep-sleep/full-power-off).

**Q82. What role does a Power Management Unit (PMU), external to the core itself, typically play in a RISC-V SoC's low-power strategy?**
A PMU is typically a separate hardware block (sometimes itself a small dedicated processor) responsible for sequencing power/clock domain transitions (per Q31-33's power state machine concept), monitoring wake sources, coordinating with voltage regulators for DVFS, and exposing a register/CSR interface that software (an RTOS or bare-metal firmware) can use to request specific power states — the core's `WFI` execution is often just the trigger event that the PMU then acts upon.

**Q83. How might the RISC-V custom extension mechanism (custom-0/custom-1 opcode space, or vendor-specific CSRs) be used for low-power features beyond what the base ISA defines?**
Implementers can define custom instructions or custom CSRs (within RISC-V's reserved encoding space for vendor extensions) to expose implementation-specific low-power controls — e.g., a custom instruction to explicitly request a specific numbered sleep-depth state, or custom CSRs to configure wake-source masks or retention behavior — since the base ISA intentionally doesn't standardize these details, leaving room for implementation-specific innovation while still keeping the base ISA and general-purpose software portable.

**Q84. Why does interrupt latency (discussed earlier for the Pulse real-time tier) become a specific design tension when a core also implements aggressive sleep states?**
Waking from a deeper sleep state (e.g., one involving power gating and state retention/restore) inherently takes longer than waking from a lighter state (e.g., simple clock gating), because power rails must stabilize and retained state must be restored before normal execution can resume — a core aiming for both aggressive power savings and bounded, low interrupt latency must carefully choose which sleep depth to enter based on how soon a wake event is expected, since entering too deep a sleep state can violate a real-time deadline even though it saves more power while idle.

**Q85. What is a Wake-up Interrupt Controller (WIC), and why is it sometimes implemented as a small always-on block separate from the main core?**
A WIC is a minimal, low-power interrupt-detection block that remains powered (in an always-on domain) even while the main core is power-gated, so it can still monitor for wake-triggering interrupt sources and assert a wake request to the PMU — since the main core itself cannot detect an interrupt if it has no power at all, a tiny always-on watcher is needed to bridge that gap.

**Q86. Why does the choice of MPU (memory protection unit, per the Pulse/Nano tiers) versus MMU/TLB (Apex tier) also have secondary low-power implications, beyond the determinism reasons discussed earlier?**
An MPU's simple, small region-comparator logic draws far less static and dynamic power than a full MMU with a TLB (an associative, CAM-like structure that must be powered and searched on essentially every memory access) — so beyond the WCET-determinism argument, the MPU choice for Pulse and Nano also directly supports those tiers' power-efficiency goals, while Apex accepts the MMU/TLB's higher power cost as a tradeoff for the virtual memory capability that general-purpose OS software requires.

---

## I. Low-Power Verification (UPF/CPF) (Q87–Q94)

**Q87. What is UPF (Unified Power Format), and what problem does it solve in a low-power design flow?**
UPF is an industry-standard (IEEE 1801) language for describing a chip's power intent — power domains, supply nets, isolation/retention strategies, and power state tables — separately from the functional RTL. It solves the problem of needing a single, tool-independent, machine-readable specification of power architecture that can be consistently applied across synthesis, simulation, and physical implementation tools, rather than each tool needing its own incompatible power description.

**Q88. What is CPF (Common Power Format), and how does it relate to UPF?**
CPF is an earlier, alternative standard (originally from Cadence, later Si2) for the same general purpose as UPF — describing power intent separately from RTL. The industry has largely converged on UPF (the IEEE-standardized format) as the dominant format in modern flows, though CPF remains relevant in some legacy toolchains and design environments.

**Q89. What is a "power domain" in the context of UPF, and what does defining one actually specify?**
A power domain is a named grouping of RTL logic (a set of module instances) that shares the same supply network and power-management behavior — defining one in UPF specifies which modules/instances belong to it, which supply nets (and voltages) power it, and what power states (on, off, retention, etc.) it can be placed into.

**Q90. What is "low-power simulation" (as distinct from purely functional RTL simulation), and what additional bugs can it catch?**
Low-power simulation uses the UPF power intent alongside the RTL to model the actual electrical effects of power gating and domain transitions during simulation — including forcing outputs of powered-off domains to 'X' (unknown) unless properly isolated, and modeling retention behavior — catching an entire class of bugs (missing isolation, incorrect retention, signals read from an unpowered domain) that a purely functional simulation (which has no concept of "power off" at all) would never detect.

**Q91. Why can a design pass 100% of its purely functional RTL testcases yet still have serious low-power-related bugs?**
Because ordinary functional simulation has no model of power domains being off, isolated, or in retention — signals simply always have valid values in that view of the world. Bugs like "logic reads a value from a domain that should have been power-gated at that point" or "an isolation cell wasn't inserted where needed" are entirely invisible without a power-aware (UPF-driven) simulation or verification flow layered on top of the functional tests.

**Q92. What is Power-Aware Formal Verification, and what specific class of properties does it typically check?**
It applies formal methods (exhaustive, proof-based analysis rather than simulation with specific test vectors) to properties derived from the UPF power intent — for example, formally proving that every signal crossing a power-domain boundary has a corresponding isolation cell, or that retention flops are correctly connected to their save/restore control signals — providing stronger, vector-independent coverage guarantees than simulation alone for these specific structural power-safety properties.

**Q93. What is a "power state table" (PST) in UPF, and what does it define?**
A PST enumerates the legal combinations of power states across all of a design's power domains (e.g., "core domain ON + memory domain RETENTION + peripheral domain OFF" as one valid overall system power state) along with the supply voltage values associated with each state — it gives verification and implementation tools a definitive list of which domain-state combinations the design is actually meant to support, rather than assuming every domain can be independently toggled in any arbitrary combination.

**Q94. Why is it important to verify power-up/power-down sequencing (not just the steady-state "on" and "off" conditions) in a low-power verification flow?**
Real bugs often occur specifically during the transition — e.g., a brief window during power-up where isolation is released before the domain's outputs are actually valid, or where reset isn't properly held through the power ramp — that wouldn't be visible if verification only checked the design once fully settled in the "on" or "off" state; UPF-aware simulation and formal tools explicitly model and check these transient sequencing windows for exactly this reason.

---

## J. System-Level / SoC Low-Power Techniques (Q95–Q100)

**Q95. What is heterogeneous multi-core design (e.g., "big.LITTLE"-style asymmetric clustering), and how does it apply the low-power tier philosophy at the system level?**
It pairs high-performance cores (larger, higher-power, e.g., an Apex-class core) with smaller, more power-efficient cores (e.g., a Nano or Pulse-class core) on the same chip, dynamically migrating workloads to the smaller cores whenever the full performance of the larger core isn't needed — extending the same "right-sized tier for the task" philosophy behind a product family like ReflexRV from the chip-selection level down to the runtime task-scheduling level within a single SoC.

**Q96. What is a power domain hierarchy in a typical SoC, and why is it structured with multiple independently-controllable domains rather than one domain for the whole chip?**
An SoC is typically partitioned into many independent power domains (per-core, per-peripheral, memory subsystem, always-on domain for wake-detection logic, etc.) precisely so that unused portions of the chip (an idle peripheral, an unused core) can be power-gated independently without affecting the parts of the chip that are still needed — a single whole-chip domain would force an all-or-nothing power decision, losing most of the potential savings available from partial, workload-dependent power-down.

**Q97. What is an "always-on" (AON) domain in a low-power SoC, and what kinds of logic typically live there?**
The AON domain is the one portion of the chip that remains continuously powered even during the deepest sleep states, typically containing the minimum logic needed to detect wake events and manage the power state machine itself — things like the Wake-up Interrupt Controller (Q85), real-time clock/timer, and the power management unit's core sequencing logic, since something must always be watching for a reason to wake the rest of the chip back up.

**Q98. What is dark silicon, and how does it relate to modern low-power/thermal-constrained chip design?**
Dark silicon refers to the phenomenon where, due to power density limits, not all transistors on an advanced-process chip can be simultaneously active at full performance without exceeding thermal/power budgets — meaning significant portions of the chip must remain powered down ("dark") at any given moment, which has made aggressive, fine-grained power gating not just a power-saving nicety but often a hard thermal necessity in modern high-density SoC design.

**Q99. Why does interconnect (bus/NoC) design also matter for system-level low power, not just the compute cores themselves?**
On-chip interconnect (buses, crossbars, or a network-on-chip) can itself represent a meaningful fraction of total dynamic power due to long wire capacitance and the sheer number of signals toggling across the chip on every transaction — techniques like bus-encoding to reduce toggling, clock-gating idle interconnect segments, and only powering the interconnect paths actually needed for a given active domain (rather than a chip-wide always-active fabric) are standard parts of a complete SoC-level low-power strategy.

**Q100. Bringing it together: for a CPU IP family spanning Nano through Prime (like ReflexRV), why is "low power" not a single technique but a different combination of these techniques at each tier?**
Because each tier optimizes for a different point in the power/performance/determinism space: Nano prioritizes minimal leakage and area via a shallow pipeline, MPU instead of MMU, and aggressive coarse-grained power/clock gating including deep sleep via `WFI`; Pulse prioritizes bounded, predictable power/latency behavior (favoring simpler, more deterministic techniques like static prediction and careful sleep-depth selection over aggressive DVFS); and Apex/Prime prioritize raw throughput and can afford (and need) more sophisticated techniques like per-domain DVFS, way-predicted caches, and fine-grained power gating across a much larger, more complex design — the right low-power strategy is always tier-specific, not a single one-size-fits-all checklist.

---

## RTL Coding Exercises (RTL1–RTL25)

Each exercise includes a problem statement, a Verilog solution, and a short explanation. These are written for clarity/teaching purposes rather than as production-optimized, foundry-signoff RTL — real low-power flows also require UPF power intent files (see RTL24) and vendor-specific ICG/isolation/retention cells from your target library.

### RTL1. Implement a behavioral Integrated Clock Gating (ICG) cell.

**Problem:** Model a latch-based ICG cell that glitch-free gates a clock based on an enable signal.

```verilog
module icg_cell (
    input  logic clk_in,
    input  logic enable,
    input  logic test_enable, // scan/test bypass, common in real ICG cells
    output logic clk_out
);
    logic enable_latched;

    // Transparent latch: captures 'enable' while clk_in is LOW,
    // holds it stable through the HIGH phase to prevent glitches.
    always_latch begin
        if (!clk_in)
            enable_latched <= enable | test_enable;
    end

    assign clk_out = clk_in & enable_latched;
endmodule
```
**Explanation:** The latch ensures `enable` can only change the gating decision while `clk_in` is already low, so the AND gate never sees a mid-high-phase transition on its enable input — this is what prevents the glitch a naive combinational `clk_in & enable` would risk (Q13-Q14). `test_enable` models the common real-world need to force the clock active during scan/DFT testing.

---

### RTL2. Implement a clock-gated pipeline register using the enable-hold RTL pattern that synthesis tools recognize.

```verilog
module gated_pipe_reg #(
    parameter WIDTH = 32
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             enable,   // 1 = update, 0 = hold (clock-gate candidate)
    input  logic [WIDTH-1:0] d_in,
    output logic [WIDTH-1:0] d_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            d_out <= '0;
        else if (enable)
            d_out <= d_in;
        // implicit else: d_out holds -- synthesis infers clock gating here
    end
endmodule
```
**Explanation:** This is the canonical pattern from Q19: an explicit `if (enable)` with no corresponding `else` branch that reassigns the register tells the synthesis tool the register is meant to hold its value when `enable` is low, letting it automatically insert an ICG cell (like RTL1) instead of always toggling the clock and rewriting the same value.

---

### RTL3. Implement operand isolation for an unused multiplier's inputs.

```verilog
module mult_operand_isolation (
    input  logic         mult_active,
    input  logic [31:0]  a_in,
    input  logic [31:0]  b_in,
    output logic [31:0]  a_isolated,
    output logic [31:0]  b_isolated
);
    // When the multiplier isn't needed this cycle, freeze its inputs at a
    // fixed, non-toggling value instead of letting bus noise/other data
    // propagate into the (otherwise still-powered) multiplier logic.
    assign a_isolated = mult_active ? a_in : 32'b0;
    assign b_isolated = mult_active ? b_in : 32'b0;
endmodule
```
**Explanation:** Feeding a fixed value (here, all zeros) instead of a live, changing bus value into an idle functional unit's inputs prevents that unit's internal combinational logic from uselessly toggling every cycle computing a result that will be discarded (Q47-Q48) — the multiplier's output isn't used when `mult_active` is low, so its inputs shouldn't be either.

---

### RTL4. Implement a power-gating header switch control with a simple enable.

```verilog
module power_switch_ctrl (
    input  logic power_domain_enable,
    output logic header_switch_en_n   // active-low enable to PMOS header array
);
    // Real header switches are typically staged/segmented (Q31) rather than
    // a single monolithic switch; this models the simplest single-stage case.
    assign header_switch_en_n = ~power_domain_enable;
endmodule
```
**Explanation:** This is deliberately minimal — a real design would stage this across multiple header segments with a delay/ramp (RTL5) to avoid inrush current, but this shows the basic active-low convention common for PMOS header switch control signals.

---

### RTL5. Implement staged power-up sequencing to avoid inrush current.

**Problem:** Enable a segmented power header in stages rather than all at once.

```verilog
module staged_power_up #(
    parameter NUM_SEGMENTS = 4
) (
    input  logic clk,
    input  logic rst_n,
    input  logic power_up_req,
    output logic [NUM_SEGMENTS-1:0] segment_en
);
    logic [$clog2(NUM_SEGMENTS+1)-1:0] stage_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_cnt  <= '0;
            segment_en <= '0;
        end else if (power_up_req && stage_cnt < NUM_SEGMENTS) begin
            stage_cnt             <= stage_cnt + 1'b1;
            segment_en[stage_cnt] <= 1'b1; // enable one more segment per cycle
        end else if (!power_up_req) begin
            stage_cnt  <= '0;
            segment_en <= '0; // power down all at once (or stage this too)
        end
    end
endmodule
```
**Explanation:** Turning on one header segment per cycle instead of the whole array at once spreads the inrush current draw across multiple cycles, reducing the peak voltage droop on the shared power grid that a single-cycle full-domain power-up would otherwise cause (Q31).

---

### RTL6. Implement an isolation cell (clamp-to-zero on power-down).

```verilog
module isolation_cell #(
    parameter WIDTH = 32
) (
    input  logic              iso_enable,    // 1 = domain is powered off, clamp output
    input  logic [WIDTH-1:0]  data_in,       // from the (possibly unpowered) domain
    output logic [WIDTH-1:0]  data_out       // to the always-on receiving logic
);
    // Clamp-low isolation: force a defined 0 instead of a floating/undefined
    // value when the source domain is powered down.
    assign data_out = iso_enable ? {WIDTH{1'b0}} : data_in;
endmodule
```
**Explanation:** This directly implements Q26's isolation requirement — whenever the source domain is off (`iso_enable` asserted), downstream always-on logic sees a stable, defined 0 instead of whatever undefined/floating value the unpowered domain's output would otherwise present.

---

### RTL7. Implement a retention flip-flop (behavioral model).

```verilog
module retention_ff (
    input  logic clk,
    input  logic rst_n,
    input  logic d,
    input  logic save_en,     // pulse before power-down: copy main FF to shadow
    input  logic restore_en,  // pulse after power-up: copy shadow back to main FF
    output logic q
);
    logic main_ff;
    logic shadow_latch; // models a small always-on retention element

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            main_ff <= 1'b0;
        else if (restore_en)
            main_ff <= shadow_latch;
        else
            main_ff <= d;
    end

    // Shadow retention storage: conceptually always-on, low-leakage.
    always_latch begin
        if (save_en)
            shadow_latch <= main_ff;
    end

    assign q = main_ff;
endmodule
```
**Explanation:** `save_en` is pulsed as the last step before the main domain's power is actually cut, copying the flop's value into the always-on shadow latch; `restore_en` is pulsed after power returns, before normal operation resumes, copying the value back — matching the save/restore sequencing described in Q27-Q28 and Q32-Q33.

---

### RTL8. Implement a power management FSM (isolate → retain → clock-gate → power-gate, and reverse for wake).

```verilog
module power_state_fsm (
    input  logic clk,
    input  logic rst_n,
    input  logic sleep_req,
    input  logic wake_req,
    output logic clk_gate_en,
    output logic isolate_en,
    output logic retain_save,
    output logic retain_restore,
    output logic power_en
);
    typedef enum logic [2:0] {
        ACTIVE, ISOLATE, RETAIN, PWR_OFF,
        PWR_ON, RESTORE, DEISOLATE
    } state_t;

    state_t state, next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ACTIVE;
        else        state <= next;
    end

    always_comb begin
        next           = state;
        clk_gate_en    = 1'b0;
        isolate_en     = 1'b0;
        retain_save    = 1'b0;
        retain_restore = 1'b0;
        power_en       = 1'b1;

        case (state)
            ACTIVE:     if (sleep_req) next = ISOLATE;
            ISOLATE:    begin isolate_en = 1'b1; next = RETAIN; end
            RETAIN:     begin isolate_en = 1'b1; retain_save = 1'b1; next = PWR_OFF; end
            PWR_OFF:    begin isolate_en = 1'b1; clk_gate_en = 1'b1; power_en = 1'b0;
                              if (wake_req) next = PWR_ON; end
            PWR_ON:     begin isolate_en = 1'b1; power_en = 1'b1; next = RESTORE; end
            RESTORE:    begin isolate_en = 1'b1; retain_restore = 1'b1; next = DEISOLATE; end
            DEISOLATE:  next = ACTIVE; // isolate_en drops to 0 by default here
            default:    next = ACTIVE;
        endcase
    end
endmodule
```
**Explanation:** This directly encodes the ordered sequence from Q32-Q33: isolation is asserted before retention save, which happens before the clock is gated and power is finally cut; on wake, power is restored before de-isolating, and state restore happens before normal operation (DEISOLATE → ACTIVE) resumes — each step only ever sees well-defined signals from its neighbors.

---

### RTL9. Implement `WFI`-triggered clock gating for a simple core.

```verilog
module wfi_sleep_ctrl (
    input  logic clk,
    input  logic rst_n,
    input  logic wfi_executed,   // pulses when core decodes/commits a WFI
    input  logic irq_pending,
    output logic core_clk_gate_en
);
    logic sleeping;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sleeping <= 1'b0;
        else if (wfi_executed)
            sleeping <= 1'b1;
        else if (irq_pending)
            sleeping <= 1'b0;
    end

    assign core_clk_gate_en = sleeping && !irq_pending;
endmodule
```
**Explanation:** This is a minimal implementation of RISC-V `WFI` semantics (Q77-Q79): once `WFI` is executed with no pending interrupt, the core's clock is gated; the moment `irq_pending` asserts, gating is released so the core can resume fetching and service the interrupt.

---

### RTL10. Implement an always-on Wake-up Interrupt Controller (WIC) stub.

```verilog
module wic (
    input  logic aon_clk,      // always-on domain clock, independent of main core
    input  logic aon_rst_n,
    input  logic [7:0] irq_lines,
    input  logic [7:0] irq_wake_mask,
    output logic wake_request
);
    logic [7:0] irq_sync0, irq_sync1;

    // Synchronize asynchronous wake sources into the always-on domain.
    always_ff @(posedge aon_clk or negedge aon_rst_n) begin
        if (!aon_rst_n) begin
            irq_sync0 <= 8'b0;
            irq_sync1 <= 8'b0;
        end else begin
            irq_sync0 <= irq_lines;
            irq_sync1 <= irq_sync0;
        end
    end

    assign wake_request = |(irq_sync1 & irq_wake_mask);
endmodule
```
**Explanation:** This block is deliberately tiny and lives in the always-on power domain (Q85, Q97) — it must keep running even while the main core is fully power-gated, so it's built from minimal logic (a mask-and-OR reduction with synchronizer flops) to keep its own always-on power cost as low as possible.

---

### RTL11. Implement a memory bank power-gating controller for a multi-bank cache.

```verilog
module cache_bank_pgate #(
    parameter NUM_BANKS = 4
) (
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic [NUM_BANKS-1:0]     bank_recently_used,
    input  logic [$clog2(NUM_BANKS)-1:0] idle_timeout_cycles_log2,
    output logic [NUM_BANKS-1:0]     bank_power_en
);
    logic [NUM_BANKS-1:0][15:0] idle_counter;
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                idle_counter[i] <= 16'b0;
                bank_power_en[i] <= 1'b1;
            end
        end else begin
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                if (bank_recently_used[i]) begin
                    idle_counter[i]  <= 16'b0;
                    bank_power_en[i] <= 1'b1;
                end else if (idle_counter[i] < (16'd1 << idle_timeout_cycles_log2)) begin
                    idle_counter[i] <= idle_counter[i] + 1'b1;
                end else begin
                    bank_power_en[i] <= 1'b0; // idle long enough: power gate this bank
                end
            end
        end
    end
endmodule
```
**Explanation:** Each bank tracks its own idle time independently; a bank only loses power after being unused for a configurable timeout, implementing the finer-grained "power-gate only the cold ways/banks" strategy from Q59 rather than an all-or-nothing cache power decision.

---

### RTL12. Implement a bus/peripheral idle detector that drives clock gating for an unused peripheral domain.

```verilog
module bus_idle_detect #(
    parameter IDLE_THRESHOLD = 64
) (
    input  logic clk,
    input  logic rst_n,
    input  logic bus_transaction_valid,
    output logic peripheral_clk_gate_en
);
    logic [$clog2(IDLE_THRESHOLD+1)-1:0] idle_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_cnt <= '0;
        end else if (bus_transaction_valid) begin
            idle_cnt <= '0;
        end else if (idle_cnt < IDLE_THRESHOLD) begin
            idle_cnt <= idle_cnt + 1'b1;
        end
    end

    assign peripheral_clk_gate_en = (idle_cnt >= IDLE_THRESHOLD);
endmodule
```
**Explanation:** A configurable idle threshold avoids gating and immediately un-gating a peripheral's clock on every brief pause between back-to-back transactions (which would waste more power on gating/ungating transients than it saves) — the peripheral only sleeps after being genuinely idle for a sustained period.

---

### RTL13. Implement a simple clock divider for coarse-grained frequency scaling.

```verilog
module clk_divider #(
    parameter MAX_DIV = 8
) (
    input  logic clk_in,
    input  logic rst_n,
    input  logic [$clog2(MAX_DIV)-1:0] div_select, // 0 = /1, 1 = /2, 2 = /4, ...
    output logic clk_out
);
    logic [MAX_DIV-1:0] div_cnt;
    logic clk_div_toggle;

    always_ff @(posedge clk_in or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= '0;
        else
            div_cnt <= div_cnt + 1'b1;
    end

    assign clk_div_toggle = div_cnt[div_select]; // select which counter bit to use
    assign clk_out = (div_select == 0) ? clk_in : clk_div_toggle;
endmodule
```
**Explanation:** This models the frequency half of DVFS (Q35-Q36) in its simplest integer-divider form; a real implementation would need a glitch-free divider/mux (to avoid runt clock pulses when switching `div_select`) and would be paired with a corresponding voltage change from a regulator, not shown here.

---

### RTL14. Implement a DVFS operating-point request/acknowledge handshake with the voltage regulator.

```verilog
module dvfs_ctrl (
    input  logic clk,
    input  logic rst_n,
    input  logic [2:0] opp_request,   // requested operating point (0 = lowest)
    input  logic       regulator_ack, // asserted when voltage has settled
    output logic [2:0] opp_active,
    output logic        freq_change_en,
    output logic [2:0]  regulator_opp_sel
);
    typedef enum logic [1:0] {IDLE, WAIT_VOLTAGE, APPLY_FREQ} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= IDLE;
            opp_active        <= 3'd0;
            regulator_opp_sel <= 3'd0;
            freq_change_en    <= 1'b0;
        end else begin
            freq_change_en <= 1'b0;
            case (state)
                IDLE: if (opp_request != opp_active) begin
                    regulator_opp_sel <= opp_request;
                    state <= WAIT_VOLTAGE;
                end
                WAIT_VOLTAGE: if (regulator_ack) begin
                    freq_change_en <= 1'b1; // only change frequency once voltage is safe
                    opp_active     <= opp_request;
                    state          <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
```
**Explanation:** Voltage must settle before frequency is changed when scaling up (Q36, Q40) — this handshake explicitly waits for `regulator_ack` before asserting `freq_change_en`, preventing the core from running at a higher frequency before its supply voltage can safely support it.

---

### RTL15. Implement a level shifter behavioral model between two voltage domains.

```verilog
module level_shifter (
    input  logic vdd_low_domain_signal,  // logic signal in the lower-voltage domain
    input  logic vdd_high_ok,            // both supplies present/stable (model only)
    output logic vdd_high_domain_signal
);
    // Behavioral model only -- a real level shifter is an analog/mixed-signal
    // cell characterized for specific VDD_low -> VDD_high thresholds, not
    // synthesizable digital logic. This shows the *interface contract* only.
    assign vdd_high_domain_signal = vdd_high_ok ? vdd_low_domain_signal : 1'b0;
endmodule
```
**Explanation:** Level shifters (Q42) are physical-design/library cells, not something meaningfully described in synthesizable RTL — this stub exists to show where one must be instantiated (any signal crossing between differently-voltaged domains) and to gate its output safely if the target domain's supply isn't yet valid.

---

### RTL16. Implement an FSM idle state that explicitly de-asserts all downstream enables (Q73).

```verilog
module datapath_ctrl_fsm (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic done,
    output logic alu_en,
    output logic mem_en,
    output logic mult_en
);
    typedef enum logic [1:0] {IDLE, RUN, FINISH} state_t;
    state_t state, next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next;
    end

    always_comb begin
        next    = state;
        alu_en  = 1'b0; // idle state defaults: everything off
        mem_en  = 1'b0;
        mult_en = 1'b0;

        case (state)
            IDLE:   if (start) next = RUN;
            RUN:    begin
                        alu_en  = 1'b1;
                        mem_en  = 1'b1;
                        mult_en = 1'b1;
                        if (done) next = FINISH;
                    end
            FINISH: next = IDLE;
            default: next = IDLE;
        endcase
    end
endmodule
```
**Explanation:** All enable outputs default to zero at the top of the combinational block and are only asserted explicitly inside the `RUN` state — this coding style guarantees the idle state can never accidentally leave a stale enable asserted, letting downstream clock-gated logic actually quiesce while the FSM is idle.

---

### RTL17. Implement a toggle-activity monitor for RTL-level power estimation.

```verilog
module toggle_monitor #(
    parameter WIDTH = 32
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] signal_in,
    output logic [31:0]      toggle_count
);
    logic [WIDTH-1:0] prev_val;
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_val     <= '0;
            toggle_count <= 32'b0;
        end else begin
            for (i = 0; i < WIDTH; i = i + 1) begin
                if (signal_in[i] != prev_val[i])
                    toggle_count <= toggle_count + 1'b1;
            end
            prev_val <= signal_in;
        end
    end
endmodule
```
**Explanation:** This kind of instrumentation (typically added only in simulation/verification builds, not shipped in silicon) supports the switching-activity-based power estimation described in Q74 — running representative workloads through a design instrumented like this highlights exactly which signals/buses toggle most, guiding where clock gating or operand isolation would pay off most.

---

### RTL18. Implement a register file with per-bank clock gating (split into two halves, only the accessed half clocked).

```verilog
module reg_file_banked (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data
);
    logic bank_a_active, bank_b_active; // bank A: x0-x15, bank B: x16-x31
    logic clk_bank_a, clk_bank_b;

    assign bank_a_active = (we && !rd_addr[4]);
    assign bank_b_active = (we && rd_addr[4]);

    icg_cell icg_a (.clk_in(clk), .enable(bank_a_active), .test_enable(1'b0), .clk_out(clk_bank_a));
    icg_cell icg_b (.clk_in(clk), .enable(bank_b_active), .test_enable(1'b0), .clk_out(clk_bank_b));

    logic [31:0] regs_a [1:15];
    logic [31:0] regs_b [16:31];

    always_ff @(posedge clk_bank_a) if (bank_a_active) regs_a[rd_addr[3:0]] <= rd_data;
    always_ff @(posedge clk_bank_b) if (bank_b_active) regs_b[rd_addr[3:0]] <= rd_data;

    function automatic logic [31:0] read_reg(input logic [4:0] addr);
        if (addr == 5'd0)       read_reg = 32'b0;
        else if (!addr[4])      read_reg = regs_a[addr[3:0]];
        else                    read_reg = regs_b[addr[3:0]];
    endfunction

    assign rs1_data = read_reg(rs1_addr);
    assign rs2_data = read_reg(rs2_addr);
endmodule
```
**Explanation:** Only the bank actually being written gets a toggling write clock that cycle (via the RTL1 ICG cells), rather than every register in the file being clocked on every write regardless of which one is targeted — a finer-grained application of the same clock-gating principle applied at a register-file-bank granularity instead of whole-block granularity (Q15).

---

### RTL19. Implement drowsy (data-retention voltage) mode control signaling for an SRAM macro (control-side model).

```verilog
module sram_drowsy_ctrl (
    input  logic clk,
    input  logic rst_n,
    input  logic access_req,       // real read/write request this cycle
    input  logic [15:0] idle_threshold,
    output logic sram_drowsy_en,   // to memory macro's low-voltage control pin
    output logic sram_active_vdd_en
);
    logic [15:0] idle_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_cnt <= 16'b0;
        end else if (access_req) begin
            idle_cnt <= 16'b0;
        end else if (idle_cnt < idle_threshold) begin
            idle_cnt <= idle_cnt + 1'b1;
        end
    end

    assign sram_drowsy_en     = (idle_cnt >= idle_threshold);
    assign sram_active_vdd_en = access_req; // must wake to full voltage before any access
endmodule
```
**Explanation:** `sram_active_vdd_en` must be asserted (restoring full read/write voltage, per Q60-Q61) at least one cycle before `access_req` can actually be serviced in a real memory macro, since a drowsy-mode SRAM typically cannot be reliably read or written at its reduced retention voltage — this control logic only shows the request/threshold side; the actual voltage-domain wake latency would need to be accounted for in the requesting logic's stall behavior.

---

### RTL20. Implement a way-predicted cache access controller (activate one way instead of all ways).

```verilog
module way_predicted_access #(
    parameter NUM_WAYS = 4,
    parameter WAY_BITS = $clog2(NUM_WAYS)
) (
    input  logic [WAY_BITS-1:0] predicted_way,
    output logic [NUM_WAYS-1:0] way_access_en
);
    always_comb begin
        way_access_en = '0;
        way_access_en[predicted_way] = 1'b1; // only the predicted way's array is read
    end
endmodule
```
**Explanation:** Compare this to a naive set-associative access that would assert all `NUM_WAYS` bits every access (activating every way's bit-lines and sense amps in parallel) — only enabling the single predicted way (Q63) means the other ways' arrays don't toggle at all for that access, at the cost of needing a fallback re-access path (not shown) when the prediction is later found wrong via tag comparison.

---

### RTL21. Implement a combined isolation + retention sequencing wrapper (UPF-style behavior modeled directly in RTL for simulation).

```verilog
module domain_wrapper #(
    parameter WIDTH = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              domain_power_en,
    input  logic [WIDTH-1:0]  core_logic_out,
    output logic [WIDTH-1:0]  domain_out
);
    logic isolate_en;
    logic power_was_off_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            power_was_off_prev <= 1'b1;
        else
            power_was_off_prev <= ~domain_power_en;
    end

    // Isolate whenever power is off, AND for one extra cycle after power-up
    // to allow internal logic to settle before exposing its output.
    assign isolate_en = (~domain_power_en) || power_was_off_prev;

    isolation_cell #(.WIDTH(WIDTH)) iso (
        .iso_enable(isolate_en),
        .data_in(core_logic_out),
        .data_out(domain_out)
    );
endmodule
```
**Explanation:** This is a simplified, RTL-simulatable approximation of what a UPF-driven low-power simulation flow (Q90) checks automatically — isolation stays asserted not just while power is off but for one extra settling cycle after power returns, modeling the "power-up before de-isolate" ordering from the power state FSM (RTL8) directly in a wrapper that could be unit-tested independently.

---

### RTL22. Implement a simple per-core power-gate arbiter for a heterogeneous 2-core (big.LITTLE-style) SoC.

```verilog
module hetero_core_pgate_arbiter (
    input  logic clk,
    input  logic rst_n,
    input  logic big_core_needed,   // e.g., high-performance task scheduled
    output logic big_core_power_en,
    output logic little_core_power_en
);
    // Little core (Nano/Pulse-class) stays powered whenever the big core
    // (Apex-class) doesn't need to be active -- workload migrates to the
    // efficient core by default, matching Q95's tier-selection philosophy.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            big_core_power_en    <= 1'b0;
            little_core_power_en <= 1'b1;
        end else begin
            big_core_power_en    <= big_core_needed;
            little_core_power_en <= 1'b1; // little core always available as fallback
        end
    end
endmodule
```
**Explanation:** This models the system-level policy from Q95 at the RTL control level: the power-efficient core is the default always-available option, and the high-performance core is only powered up on demand — a direct hardware analogue of scheduling a task to Nano/Pulse versus Apex based on actual performance need.

---

### RTL23. Implement an always-on real-time clock/timer used to schedule periodic wake events.

```verilog
module aon_rtc_wake (
    input  logic aon_clk,       // slow, always-on clock (e.g., 32kHz)
    input  logic aon_rst_n,
    input  logic [31:0] wake_interval,
    output logic wake_pulse
);
    logic [31:0] counter;

    always_ff @(posedge aon_clk or negedge aon_rst_n) begin
        if (!aon_rst_n) begin
            counter    <= 32'b0;
            wake_pulse <= 1'b0;
        end else if (counter >= wake_interval) begin
            counter    <= 32'b0;
            wake_pulse <= 1'b1;
        end else begin
            counter    <= counter + 1'b1;
            wake_pulse <= 1'b0;
        end
    end
endmodule
```
**Explanation:** Running from a slow, always-on clock (rather than the main high-frequency core clock) keeps this timer's own power cost minimal while still living in the always-on domain (Q97) needed to periodically wake a deeply power-gated core for scheduled tasks (e.g., a sensor poll every N milliseconds) without requiring the main core to stay powered just to count time.

---

### RTL24. Write an example UPF power-intent snippet corresponding to a two-domain design (main core + always-on domain).

**Problem:** Show the UPF companion file that would describe the power architecture for a core wrapped by the isolation/retention logic built in RTL6-RTL8, since UPF (not RTL) is where power domains, supplies, and strategies are actually declared in a real flow.

```tcl
# Example UPF 3.x-style power intent (illustrative, not tool-verified)

create_power_domain PD_AON \
    -include_scope

create_power_domain PD_CORE \
    -elements {u_core}

create_supply_net VDD_AON  -reuse
create_supply_net VDD_CORE -reuse
create_supply_net VSS      -reuse

create_supply_port VDD_AON_PORT  -direction in
create_supply_port VDD_CORE_PORT -direction in

connect_supply_net VDD_AON  -ports VDD_AON_PORT
connect_supply_net VDD_CORE -ports VDD_CORE_PORT

set_domain_supply_net PD_AON  -primary_power_net VDD_AON  -primary_ground_net VSS
set_domain_supply_net PD_CORE -primary_power_net VDD_CORE -primary_ground_net VSS

# Isolation strategy: clamp PD_CORE outputs to 0 when its domain is off
set_isolation ISO_CORE -domain PD_CORE \
    -isolation_power_net VDD_AON \
    -isolation_signal iso_enable \
    -isolation_sense high \
    -clamp_value 0 \
    -applies_to outputs

# Retention strategy: retain u_core's state flops through power-down
set_retention RET_CORE -domain PD_CORE \
    -retention_power_net VDD_AON \
    -save_signal   {retain_save   high} \
    -restore_signal {retain_restore high}

# Power states: legal domain-state combinations
add_power_state PD_CORE.primary_power_net \
    -state {ON  -supply_expr {power == FULL_ON}} \
    -state {OFF -supply_expr {power == OFF}}
```
**Explanation:** This is the actual industry-standard way the power architecture described conceptually throughout this document (domains, isolation, retention, legal power states — Q87-Q94) gets specified: not embedded as ad-hoc logic scattered through RTL, but declared once in a UPF file that synthesis, simulation, and place-and-route tools all consume consistently, keeping the power-intent specification separate from — but linked to — the functional RTL (like RTL6-RTL8) that implements the actual gating/isolation/retention hardware.

---

### RTL25. Implement a top-level power management unit (PMU) tying together `WFI` detection, the power state FSM, and DVFS request handling.

```verilog
module pmu_top (
    input  logic clk,
    input  logic rst_n,
    input  logic wfi_executed,
    input  logic irq_pending,
    input  logic [2:0] sw_dvfs_request, // software-requested performance level via CSR
    output logic core_clk_gate_en,
    output logic core_power_en,
    output logic isolate_en,
    output logic retain_save,
    output logic retain_restore,
    output logic [2:0] active_opp
);
    logic sleeping;
    logic sleep_req, wake_req;

    // 1. WFI/interrupt-driven sleep decision (RTL9 logic, inlined)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      sleeping <= 1'b0;
        else if (wfi_executed) sleeping <= 1'b1;
        else if (irq_pending)  sleeping <= 1'b0;
    end
    assign sleep_req = sleeping && !irq_pending;
    assign wake_req  = irq_pending;

    // 2. Power state sequencing (RTL8 FSM, instantiated)
    power_state_fsm u_pstate (
        .clk(clk), .rst_n(rst_n),
        .sleep_req(sleep_req), .wake_req(wake_req),
        .clk_gate_en(core_clk_gate_en),
        .isolate_en(isolate_en),
        .retain_save(retain_save),
        .retain_restore(retain_restore),
        .power_en(core_power_en)
    );

    // 3. DVFS operating point tracking (simplified: only while active)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_opp <= 3'd0;
        else if (core_power_en && !sleeping)
            active_opp <= sw_dvfs_request;
    end
endmodule
```
**Explanation:** This ties together three previously separate exercises into one PMU: `WFI` execution (Q77-Q79, RTL9) decides *whether* to sleep, the power state FSM (Q32-Q33, RTL8) handles *how* to sleep/wake safely in the correct order, and a DVFS tracker (Q35, RTL14) manages *how fast* to run while active — reflecting how a real PMU (Q82) coordinates all three concerns from a single control point rather than as isolated, uncoordinated mechanisms.

---

