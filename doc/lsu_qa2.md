# The Load–Store Unit: 100 Questions with Detailed Answers

**A RISC-V–centric reference for CPU microarchitecture and RTL design**

Every question below is answered in depth, with a concrete RISC-V instruction example where one applies, and with technical terms defined inline the first time they appear (marked **Term —** *definition*). Part II contains 25 synthesizable SystemVerilog modules covering the major LSU datapath and control blocks.

---

## Table of contents

**Part I — 100 questions**

| Section | Questions | Topic |
|---|---|---|
| 1 | Q1–Q12 | Fundamentals and RISC-V load/store ISA |
| 2 | Q13–Q22 | Address generation, alignment, and the AGU |
| 3 | Q23–Q32 | Address translation, TLBs, PMA and PMP |
| 4 | Q33–Q44 | L1 data cache organization |
| 5 | Q45–Q58 | Store buffer and store-to-load forwarding |
| 6 | Q59–Q68 | Load queue, store queue, memory disambiguation |
| 7 | Q69–Q78 | Non-blocking caches, MSHRs, replay |
| 8 | Q79–Q90 | Atomics, LR/SC, fences, and the memory model |
| 9 | Q91–Q100 | Prefetch, PPA, verification, and debug |

**Part II — 25 RTL modules** — see [Part II](#part-ii--25-systemverilog-rtl-modules)

---

# Part I — 100 Questions

## Section 1 — Fundamentals and the RISC-V load/store ISA

### Q1. What is a load–store unit and what are its responsibilities?

The **LSU** — *Load–Store Unit* — is the block of a CPU pipeline that executes every instruction which touches memory. Nothing else in the core is allowed to read or write data memory; that is the defining property of a **load–store architecture** — *an ISA in which arithmetic instructions operate only on registers, and memory is accessed only by dedicated load and store instructions*. RISC-V, ARM, and MIPS are load–store architectures; x86 is not, because `add [rax], rbx` both loads and stores.

The LSU owns eight distinct responsibilities:

1. **Address generation** — compute the effective address from a base register and an immediate.
2. **Alignment and legality checking** — detect misaligned accesses and out-of-range addresses.
3. **Address translation** — turn a virtual address into a physical address through the DTLB and page tables.
4. **Permission and attribute checking** — PMP, PMA, and page-table permission bits.
5. **Cache access** — tag lookup, way selection, data array read/write.
6. **Ordering** — enforce the memory consistency model between loads, stores, and fences.
7. **Store buffering and forwarding** — hold committed-but-not-yet-written stores and supply their data to younger loads.
8. **Miss handling** — allocate MSHRs, track outstanding fills, replay dependents.

The LSU is almost always the timing-critical and the bug-dense block of a core. Its critical path (base + offset → TLB → tag compare → way mux → align → bypass) sets the **load-to-use latency** — *the number of cycles between issuing a load and the earliest cycle a dependent instruction can consume its result* — which is the single largest IPC lever in most designs.

### Q2. What load and store instructions does RV64I define, and how do they differ?

RV64I defines loads at four widths, each in signed and (where meaningful) unsigned form, and stores at four widths.

```asm
# Loads — I-type: rd = mem[rs1 + sign_extend(imm12)]
lb   x10, 0(x11)     # load  8 bits, sign-extend to 64
lbu  x10, 0(x11)     # load  8 bits, zero-extend to 64
lh   x10, 2(x11)     # load 16 bits, sign-extend to 64
lhu  x10, 2(x11)     # load 16 bits, zero-extend to 64
lw   x10, 4(x11)     # load 32 bits, sign-extend to 64  <-- note: SIGN-extends
lwu  x10, 4(x11)     # load 32 bits, zero-extend to 64  (RV64 only)
ld   x10, 8(x11)     # load 64 bits                     (RV64 only)

# Stores — S-type: mem[rs1 + sign_extend(imm12)] = rs2[width-1:0]
sb   x12, 0(x11)     # store low  8 bits
sh   x12, 2(x11)     # store low 16 bits
sw   x12, 4(x11)     # store low 32 bits
sd   x12, 8(x11)     # store low 64 bits                (RV64 only)
```

Three points matter for hardware:

- **`lw` sign-extends on RV64.** This is a deliberate ISA choice so that 32-bit arithmetic results (`addw`, `subw`) and 32-bit loads produce the same canonical 64-bit form, letting the core compare and branch on them without re-canonicalizing. `lwu` exists for genuinely unsigned 32-bit data. Your load aligner must therefore take a `sign` control bit, not derive it from width.
- **Stores have no sign/zero variant** because they truncate; the upper bits of `rs2` are simply discarded.
- **The immediate is always 12 bits, sign-extended**, giving a ±2 KiB window around the base register. There is no scaled-index or register-offset addressing mode in base RISC-V (see Q6).

### Q3. Why does RISC-V have only one addressing mode, and what does that cost the LSU?

RISC-V provides exactly one addressing mode: **base + 12-bit sign-extended displacement**, written `imm(rs1)`.

**Addressing mode** — *the rule an ISA uses to compute the memory address an instruction refers to.* x86 offers `base + index*scale + disp`; ARM offers pre/post-indexed, register-offset, and scaled variants.

The benefit to the LSU is real: the AGU is a single 64-bit adder with one register operand and one immediate. There is no shifter in the address path, no second register read port needed for addressing, and the address is available one cycle earlier than it would be with a three-input address computation. That directly shortens load-to-use latency and simplifies the wakeup logic.

The cost is instruction count. Array indexing that x86 does in one instruction takes three in base RISC-V:

```asm
# C: x = a[i];  with a in x11, i in x12, element size 8
slli x13, x12, 3       # x13 = i * 8
add  x13, x11, x13     # x13 = &a[i]
ld   x10, 0(x13)       # x10 = a[i]
```

Two mitigations exist and both belong in a high-performance design. First, the **Zba** extension adds `sh1add`, `sh2add`, `sh3add`, which fold the shift and add into one instruction:

```asm
sh3add x13, x12, x11   # x13 = (x12 << 3) + x11
ld     x10, 0(x13)
```

Second, **macro-op fusion** — *decode-time recognition of an adjacent instruction pair that the hardware executes as a single internal operation* — lets the decoder collapse `sh3add + ld` into one indexed load micro-op, so the AGU sees a three-input add it performs in the same cycle using a carry-save adder ahead of the final adder.

### Q4. What are the compressed load/store instructions and how do they affect the LSU?

The **C extension** — *RISC-V's 16-bit compressed instruction encoding* — provides shorter forms of the most common memory operations:

```asm
c.ld    x10, 8(x11)     # -> ld  x10, 8(x11);   rd/rs1 restricted to x8-x15
c.sd    x12, 16(x11)    # -> sd  x12, 16(x11)
c.ldsp  x10, 24(sp)     # -> ld  x10, 24(x2);   any rd, sp-relative
c.sdsp  x12, 32(sp)     # -> sd  x12, 32(x2)
c.lw / c.sw / c.lwsp / c.swsp    # 32-bit equivalents
```

Two consequences for the LSU:

1. **Offsets are unsigned and pre-scaled.** `c.ld` encodes a 5-bit field scaled by 8, giving 0–248. The expander in decode must zero-extend and shift, not sign-extend. Getting this wrong is a classic bug that only shows on stack frames larger than 128 bytes.
2. **The stack-pointer forms are extremely frequent** — function prologues and epilogues are almost entirely `c.sdsp`/`c.ldsp`. Some designs add a **stack cache** or give `sp`-relative accesses a dedicated fast path with a pre-computed base, because `sp` changes rarely and the address can be speculated a cycle early.

The C extension does not create misaligned *data* accesses — a `c.ld` is still 8-byte aligned by convention — but it does create 2-byte-aligned *instruction* addresses, which is an I-side issue, not an LSU one.

### Q5. What are the floating-point and vector memory instructions, and why do they complicate the LSU?

```asm
# F/D extensions — scalar FP loads/stores, same addressing mode
flw  f0, 0(x11)      # load  32-bit float
fld  f0, 8(x11)      # load  64-bit double
fsw  f0, 0(x11)
fsd  f0, 8(x11)

# V extension (RVV 1.0) — vector memory
vle64.v   v8, (x11)               # unit-stride load, 64-bit elements
vse64.v   v8, (x11)               # unit-stride store
vlse64.v  v8, (x11), x12          # strided load, stride in x12 bytes
vluxei64.v v8, (x11), v16         # indexed (gather), offsets in v16
vsuxei64.v v8, (x11), v16         # indexed (scatter)
vl2re64.v v8, (x11)               # whole-register load, 2 registers
```

Scalar FP is easy: it uses the same AGU and cache port, just a different writeback register file. The only wrinkle is that FP loads must **NaN-box** — *place a 32-bit float in the low half of a 64-bit FP register with all upper bits set to 1* — so `flw` writes `{32'hFFFFFFFF, data}`.

Vector memory is where the LSU gets hard:

- **Unit-stride** accesses can span many cache lines. A `vle64.v` with VLEN=512 moves 64 bytes — one or two lines — so the LSU needs a **line-crossing splitter** and multi-cycle occupancy of the cache port.
- **Strided** accesses generate one address per element. With a stride larger than a line, every element is a separate cache access and possibly a separate TLB lookup.
- **Gather/scatter** (`vluxei`) generate VL independent addresses, each needing its own translation and permission check. Practical designs pipeline these at 1–4 addresses per cycle through a dedicated vector AGU, coalescing addresses that land in the same line.
- **Faults are element-precise.** If element 5 of a 16-element gather faults, elements 0–4 must have completed and 5–15 must not have. This requires either a per-element completion mask or a pre-check pass over all addresses before any data moves. `vle*ff.v` (fault-only-first) exists precisely to let software handle this cheaply for speculative vectorization.

### Q6. What is an effective address and how is it computed in RISC-V?

The **effective address (EA)** — *the final byte address the instruction actually accesses, after all addressing-mode arithmetic* — is:

```
EA = (X[rs1] + sign_extend(imm[11:0])) mod 2^XLEN
```

`XLEN` is 32 for RV32 and 64 for RV64. The `mod 2^XLEN` matters: address arithmetic **wraps silently** and never traps on overflow. So on RV64:

```asm
li   x11, -1           # x11 = 0xFFFF_FFFF_FFFF_FFFF
ld   x10, 8(x11)       # EA = 0xFFFF...FF + 8 = 0x0000_0000_0000_0007  (wraps)
```

This is a real hardware requirement, not a corner case: your AGU adder must discard the carry-out, and your fault logic must check the *wrapped* address, not the 65-bit intermediate.

On RV64 with Sv39 or Sv48 paging there is an additional rule: the address must be **canonical** — *bits above the translated range must all equal the highest translated bit*. For Sv39, bits [63:39] must all equal bit 38. A non-canonical EA raises a page fault, not an alignment or access fault. The check is a simple wide AND/OR reduction and it sits in the AGU output stage.

### Q7. What is the difference between an alignment fault, an access fault, and a page fault?

These three are distinct exception causes in RISC-V and must be prioritized correctly.

| Cause | `mcause` (load / store) | Raised when |
|---|---|---|
| Address misaligned | 4 / 6 | EA is not a multiple of the access size and hardware does not support misaligned access to that region |
| Access fault | 5 / 7 | PMP or PMA denies the access, or the physical address has no target |
| Page fault | 13 / 15 | Page-table walk fails, PTE permission bits deny, or address is non-canonical |

**Priority order** (from the privileged spec, highest first): address misaligned → access fault → page fault. That is, alignment is checked on the *virtual* address before translation even begins, which is convenient because it needs only the low 3 bits of the EA and can happen in parallel with the TLB lookup.

```asm
# Misaligned example on a core without hardware misalignment support
li x11, 0x1001
ld x10, 0(x11)         # EA = 0x1001, not 8-byte aligned
                       # -> load address misaligned, mcause = 4, mtval = 0x1001
```

`mtval` — *machine trap value, a CSR that holds the faulting address* — must be written with the full EA for all three causes, so the LSU has to carry the address to the trap unit even on a page fault discovered several cycles later.

### Q8. What does the RISC-V spec actually require regarding misaligned accesses?

The base ISA says misaligned loads and stores **may** be supported, and if they are not, the implementation **must** raise an address-misaligned exception. There are three legal implementation choices, and the choice is a major microarchitectural decision:

1. **Trap always.** Simplest. The M-mode trap handler emulates the access byte by byte. Cost: hundreds of cycles per misaligned access. Acceptable for embedded cores; unacceptable if you run unmodified Linux userspace with memcpy implementations that assume misalignment works.
2. **Hardware support with a slow path.** The LSU detects a misaligned access, splits it into two aligned accesses to consecutive lines, performs them over two or more cycles, and merges. This is what most application-class cores do.
3. **Hardware support at full speed.** The data array is banked and dual-ported enough that a line-crossing access completes in the same latency as an aligned one. Expensive; rarely worth it.

The **Zicclsm** extension — *"misaligned loads and stores to main memory regions are supported"* — is the RVA23 profile's way of letting software query this. Note the important carve-out: even a core with Zicclsm may trap on misaligned access to **I/O regions**, because splitting an MMIO access changes the number and size of bus transactions a device observes, which can break the device.

Atomics are stricter: `lr`, `sc`, and all AMOs **must** be naturally aligned or raise a misaligned exception. There is no legal hardware-split implementation of a misaligned atomic, because atomicity across two lines cannot be guaranteed without a bus lock.

### Q9. How does an LSU split a misaligned access that crosses a cache line?

Detection is cheap. For an access of size `S` at address `A` with line size `L`:

```
crosses_line = (A[log2(L)-1:0] + S) > L
```

Since `S` is a power of two and at most 8, this reduces to comparing the low offset bits against `L - S`. For a 64-byte line and an 8-byte load, `cross = (A[5:0] > 56)`.

The split is then a small state machine in the LSU:

1. **Cycle N** — issue access A to line 0. Capture the returned line-0 bytes into a **splice register**.
2. **Cycle N+1** — recirculate the operation with address `(A + S) & ~(L-1)`, i.e. the start of line 1. This is a second full TLB lookup and a second tag lookup, because line 1 may be on a different page.
3. **Cycle N+2** — merge: `result = (line1_bytes << (8*(L - A[5:0]))) | line0_bytes`, then align and extend.

Three subtleties bite people:

- **Two separate fault checks.** Line 1 may be unmapped even when line 0 is fine. The reported `mtval` should be the original EA, but the fault must be detected on the second half too.
- **Two MSHRs.** If both halves miss, you need two miss entries and must not deadlock when the MSHR file is full — reserve, don't allocate greedily.
- **Non-atomicity.** A misaligned store split into two writes is *not* atomic. Another hart can observe the first half. RVWMO permits this, but it means you cannot implement `amoadd.d` this way.

### Q10. What is the load-to-use latency and why does it dominate performance?

**Load-to-use latency** — *the number of clock cycles from the cycle a load issues to the earliest cycle a dependent instruction can issue and consume the loaded value.* If a load issues in cycle 0 and a dependent `add` can issue in cycle 3, the load-to-use latency is 3.

It dominates because loads are roughly 25% of the dynamic instruction stream and a large fraction of them feed an immediately dependent instruction — pointer chasing being the extreme case:

```asm
loop:
  ld   x10, 0(x10)      # next = node->next
  bnez x10, loop        # each iteration costs a full load-to-use
```

For a linked list traversal, IPC is literally `1 / load_to_use`. Going from 4 cycles to 3 is a 33% speedup on that loop.

The path that sets it, in a typical VIPT L1:

```
reg read -> AGU add -> index decode -> SRAM access -> tag compare
         -> way mux -> byte rotate -> sign extend -> bypass mux -> ALU input
```

The standard tricks to shorten it, roughly in order of value:

- **Way prediction** (Q37) removes tag compare from the critical path.
- **Speculative wakeup** (Q71) starts the dependent before the hit is confirmed, with replay on mispredict.
- **Early/partial address** — decode the SRAM index from `rs1[11:0] + imm[11:0]` using a fast 12-bit adder while the full 64-bit add completes in parallel.
- **Splitting the rotate** — rotate before sign-extend, and fold sign-extend into the bypass mux.
- **Zero-cycle stack loads** — if `sp` is tracked in a dedicated adder, `c.ldsp` addresses are known at decode.

### Q11. How many loads and stores per cycle should a core support, and what determines this?

The rule of thumb: **one load port per ~2.5 issue slots, one store port per ~5**. A 3-wide core wants 1 load + 1 store; a 6-wide core wants 2 loads + 1 store; an 8-wide core wants 3 loads + 2 stores. This follows from the instruction mix — roughly 25% loads and 12% stores in SPECint.

What limits you is the L1D **port count**, and SRAM ports are the most expensive thing in a cache:

- A true dual-ported SRAM is ~1.8× the area of single-ported and slower.
- **Banking** — *splitting the data array into independently addressed sub-arrays so that accesses to different banks proceed in parallel* — is far cheaper. Eight 8-byte banks selected by `A[5:3]` give you two loads per cycle whenever they hit different banks, at the cost of a **bank conflict** stall when they don't. Conflict rates run 5–15% for two ports over eight banks.
- **Replication** — keeping two copies of the data array, each single-ported, gives conflict-free dual load but doubles data array area and requires writing both copies on every store.

Tag arrays are cheaper to multi-port because they are small, so a common design is a truly dual-ported tag array feeding a banked data array.

### Q12. What is the difference between an in-order and an out-of-order LSU?

An **in-order LSU** executes memory operations in program order. It still needs a store buffer (because stores must not write the cache before commit) and MSHRs (because you want hit-under-miss), but it needs **no memory disambiguation logic at all** — a load can never be older than a store that has not yet computed its address, because addresses are computed in order.

An **out-of-order LSU** allows a load to execute before an older store whose address is not yet known. This is the source of nearly all LSU complexity:

- A **load queue (LQ)** and **store queue (SQ)** to hold in-flight operations with age order.
- **Memory disambiguation** — *deciding whether a younger load aliases an older store* — requiring full-address CAM comparisons.
- **Memory dependence prediction** to decide whether to speculate past an unknown-address store.
- **Load replay / squash** machinery when the speculation is wrong.

The payoff is large: allowing loads to bypass unknown stores is worth 10–20% IPC on an OoO core, because otherwise every store with an unresolved base register creates a barrier.

For an in-order core, the equivalent lever is a **non-blocking cache with stall-on-use** (Q69), which recovers much of the same memory-level parallelism at a fraction of the area.

---

## Section 2 — Address generation, alignment, and the AGU

### Q13. What exactly is in the AGU and what is its critical path?

The **AGU** — *Address Generation Unit, the adder and associated checking logic that produces the effective address* — for base RISC-V is deceptively simple:

```
EA[63:0] = rs1[63:0] + {{52{imm[11]}}, imm[11:0]}
```

The critical path is a 64-bit carry-propagate add. At 3 GHz in a modern node that is comfortably under a cycle, so the AGU is rarely the limiter *by itself*. What makes the AGU stage critical is everything hung off it in the same cycle:

- The low 12 bits must reach the SRAM index decoder (index is typically `A[11:6]` for a 32 KB 8-way with 64 B lines).
- Bits `[5:0]` must reach the byte-enable generator and the rotate amount.
- Bits `[2:0]` and the size must reach the misalignment comparator.
- Bits `[63:39]` must reach the canonical-address checker.
- The full address must reach the DTLB CAM.

The standard optimization is the **split adder**: compute `A[11:0] = rs1[11:0] + imm[11:0]` with a fast 12-bit adder that finishes in ~1/4 the time, use it to start the SRAM access immediately, and compute the upper bits with a normal adder in parallel. Because the page offset in Sv39/Sv48 is 12 bits and the index of a VIPT cache is inside the page offset, the untranslated low 12 bits are *exactly* what the SRAM needs. This is the whole reason VIPT exists (Q34).

With fusion (Q3), the AGU becomes a three-input adder: `rs1 + (rs2 << k) + imm`. Implement it as a 3:2 **carry-save adder** — *a compressor that reduces three addends to a sum vector and a carry vector without carry propagation* — feeding the same 64-bit CPA. The added delay is one XOR/MAJ level, roughly 10% of the adder delay.

### Q14. How do you generate byte enables for a store?

**Byte enables** (also called **byte strobes**, `wstrb` in AXI) — *a bit-per-byte mask indicating which bytes of a data beat are actually written.* For an 8-byte-wide data path with address offset `off = A[2:0]` and size encoding:

```
size=0 (byte):    mask = 8'b0000_0001 << off
size=1 (half):    mask = 8'b0000_0011 << off
size=2 (word):    mask = 8'b0000_1111 << off
size=3 (double):  mask = 8'b1111_1111
```

Uniformly: `mask = ((1 << (1<<size)) - 1) << off`. In RTL this is a decoder plus a barrel shift, and it is on the store critical path only to the extent that it must be ready before the data array write. Since stores write from the store buffer (not the pipeline), you have slack — compute the mask at store-buffer allocation time and store it alongside the data.

Example:

```asm
li  x11, 0x2003
sh  x12, 0(x11)     # off = 3, size = 1  ->  mask = 8'b0001_1000
                    # bytes 3 and 4 of the 8-byte word at 0x2000 are written
```

Note that this particular store is **misaligned** (0x2003 is not 2-byte aligned) but does *not* cross an 8-byte boundary, so a hardware-misalignment core handles it in one access. The distinction between "misaligned" and "crosses a boundary" is worth keeping separate in your control logic — many misaligned accesses are cheap.

### Q15. How does the store data aligner work?

The register value must be rotated so the relevant bytes land in the correct byte lanes of the cache line.

```
store_data_aligned = rs2 <<< (8 * A[2:0])      // left rotate by byte offset
```

A **rotate** rather than a shift is used deliberately: it costs the same in a barrel shifter, and combined with the byte-enable mask it gives correct behaviour for every case including ones that wrap within the 8-byte word (which the mask then suppresses). Using rotate also means the same shifter structure can be shared with the load aligner (Q16), which genuinely needs a rotate.

```asm
# x12 = 0x00000000_000000AB
li  x11, 0x2005
sb  x12, 0(x11)
# off = 5 -> rotate left by 40 bits -> 0x0000AB00_00000000
# mask = 8'b0010_0000 -> only byte lane 5 written -> memory[0x2005] = 0xAB
```

For a 3-bit rotate amount the shifter is three 2:1 mux levels (8, 16, 32 bit stages) — about 3 gate delays, negligible.

### Q16. How does the load data aligner and sign-extender work?

The reverse: rotate the line data right so the requested bytes land at bit 0, mask off the rest, then extend.

```
rotated  = line_data >>> (8 * A[2:0])
masked   = rotated & size_mask
result   = sign ? {{(64-W){masked[W-1]}}, masked[W-1:0]} : masked
```

where `W` is 8, 16, 32, or 64. Note the sign bit position depends on the size, so the sign-extend logic is a 4:1 mux selecting `masked[7]`, `masked[15]`, `masked[31]`, or `1'b0`, then a wide fanout.

```asm
# memory at 0x2000: FF EE DD CC BB AA 99 88   (little-endian, byte 0 = FF)
li  x11, 0x2000
lb  x10, 0(x11)     # rotate 0, W=8, byte = 0xFF, sign -> 0xFFFF_FFFF_FFFF_FFFF
lbu x10, 0(x11)     #                                  -> 0x0000_0000_0000_00FF
lh  x10, 2(x11)     # rotate 16, W=16, half = 0xCCDD, sign -> 0xFFFF_FFFF_FFFF_CCDD
lw  x10, 4(x11)     # rotate 32, W=32, word = 0x8899AABB, sign -> 0xFFFF_FFFF_8899AABB
lwu x10, 4(x11)     #                                        -> 0x0000_0000_8899AABB
```

The rotate is on the critical path (it is after the way mux), so it is usually merged into the way mux: instead of `mux8way → rotate`, build a single fused selection network that picks the right byte from the right way in one mux tree. This saves one full mux level, which at 3 GHz is worth having.

### Q17. What is a bank conflict and how do you avoid it?

A **bank conflict** occurs when two accesses in the same cycle target the same bank of a banked SRAM and the bank has only one port, forcing one access to stall.

With 8 banks selected by `A[5:3]`, two random accesses conflict with probability 1/8 = 12.5%. But real access patterns are not random and can be much worse: a stride-64 loop hits the same bank every time.

Mitigations:

- **More banks.** 16 banks halves the conflict rate but doubles the peripheral logic overhead (each bank needs its own decoder and sense amps), so area grows faster than linearly.
- **Bank hashing** — *XOR-folding higher address bits into the bank index* — turns pathological strides into pseudo-random distribution: `bank = A[5:3] ^ A[8:6] ^ A[11:9]`. Extremely cheap (a few XOR gates) and very effective. The cost is that you can no longer read consecutive banks sequentially for a line fill without un-hashing.
- **Dual-porting only the tag array** and accepting single-load-per-cycle data.
- **Conflict-aware scheduling** — the issue queue checks bank equality before issuing two loads together and defers one. This moves the cost from a pipeline stall to an issue-slot loss, which is cheaper.

### Q18. What is address wrap-around and why must the AGU handle it explicitly?

Covered partly in Q6. The concrete RTL requirement: your adder must be 64 bits and the carry-out **discarded**, not used to signal an error.

```systemverilog
// CORRECT
assign ea = rs1 + imm_sext;              // 64-bit, natural truncation

// WRONG - some designers add an overflow check
assign {ovf, ea} = {1'b0, rs1} + {1'b0, imm_sext};
assign fault = ovf;                       // NOT a RISC-V behaviour
```

The reason this matters practically: negative displacements are extremely common (stack frames use `-8(s0)`, `-16(s0)`), and any small positive base with a large negative offset wraps. If your fault logic keys off carry-out, `ld x10, -8(x0)` traps incorrectly instead of accessing `0xFFFF_FFFF_FFFF_FFF8` and then page-faulting for the right reason.

### Q19. How is the alignment check implemented and where does it sit in the pipeline?

```
misaligned = |(EA[2:0] & size_mask)
where size_mask = 3'b000 (byte), 3'b001 (half), 3'b011 (word), 3'b111 (double)
```

A three-bit AND and an OR reduction. It is placed **immediately after the AGU, before or parallel to the TLB**, because the privileged spec ranks address-misaligned above access-fault and page-fault (Q7). If you checked alignment after translation, a misaligned access to an unmapped page would report the wrong cause.

There is a nuance for cores that support misalignment in hardware: the check becomes a *routing* decision rather than a fault. The signal splits three ways:

```
aligned          -> fast path, 1 access
misaligned_same_line -> fast path, 1 access (just a wider rotate)
misaligned_cross_line -> slow path, 2 accesses
misaligned && is_atomic -> always fault (Q8)
misaligned && is_io_region -> fault if the region disallows it
```

The `is_io_region` term requires PMA information, which comes from the PMA checker after translation — so a core with hardware misalignment support has a *late* misalignment fault path in addition to the early one. That is a genuine complication and a common source of verification escapes.

### Q20. What is a partial-store-forwarding stall and how does the AGU relate to it?

If a load reads bytes that are covered *partly* by an older store in the store buffer and partly by memory, the LSU cannot simply forward — it needs to merge store-buffer bytes with cache bytes.

```asm
sw   x12, 0(x11)      # writes bytes 0-3 at 0x2000
ld   x10, 0(x11)      # reads  bytes 0-7 at 0x2000  <-- partial overlap
```

Three implementation options:

1. **Stall until the store drains.** Simplest and what most designs do. Cost is 5–30 cycles. This is the "store-forwarding stall" that shows up prominently in x86 performance counters and equally on RISC-V cores.
2. **Byte-granular merge.** Keep a per-byte valid mask in the store buffer and build a per-byte mux that selects between store-buffer byte and cache byte. This makes full forwarding work for any overlap pattern, at the cost of 8 8:1 muxes and a wider CAM output. Worth it in a high-performance core.
3. **Merge only when a single store covers the load fully** — the common case — and stall otherwise. A good 90/10 compromise.

The AGU relates because forwarding comparison needs the *full* address, not just the index. If your store buffer CAM compares only `A[11:0]` to save area, you get false forwarding matches across pages and must then verify with the translated tag a cycle later, adding a late-kill path.

### Q21. How do you handle a load and a store to the same address issued in the same cycle?

This is the **same-cycle RAW** case. The store has not yet allocated in the store buffer when the load's CAM lookup happens, so ordinary forwarding misses it.

Solutions, in order of increasing cost:

- **Forbid it in the scheduler.** Do not co-issue a load and an older store in the same cycle. Costs an issue slot occasionally.
- **Bypass path from the store pipeline into the forwarding mux.** Compare the store's AGU output against the load's AGU output combinationally in the same cycle and add a ninth input to the forwarding mux. This is a genuine extra critical path and is why many designs choose option 1.
- **Delay the load by one cycle** when the comparison hits, and let the normal store-buffer path handle it next cycle. This needs only the comparator, not the data mux, and is a good compromise.

In an in-order machine the problem is simpler because the store always issues first; you only need the bypass if you issue multiple memory ops per cycle.

### Q22. What is address disambiguation at the index level versus the full address?

Two-level comparison is a standard area/timing optimization.

- **Index match** compares only the bits that select the cache set, typically `A[11:6]`. Cheap: 6-bit comparators. Used for early filtering — if the indices differ, the addresses definitely differ.
- **Full match** compares all significant address bits, typically `A[47:3]` plus a byte mask. Expensive: 45-bit comparators × number of store-buffer entries.

A common structure: an 8-entry store buffer CAMs the 12-bit page offset in the load's DC1 stage (fast, untranslated, available early), producing a small candidate set. In DC2, when the physical tag is available, the candidates are re-checked against the physical page number. A false positive from stage 1 is killed in stage 2 with a one-cycle replay; a false *negative* is impossible because the page offset is never translated.

This is exactly the same reasoning that makes VIPT caches work (Q34), and it is worth internalizing: **the low 12 bits of a virtual address are also the low 12 bits of the physical address**, so any comparison confined to those bits is translation-independent and can be done a cycle early.

---

## Section 3 — Address translation, TLBs, PMA and PMP

### Q23. What is the DTLB and why does every LSU need one?

The **DTLB** — *Data Translation Lookaside Buffer, a cache of recent virtual-to-physical page translations used by the data path* — exists because a page-table walk costs 3–5 dependent memory accesses (one per level of the page table) and doing that on every load would be catastrophic.

In Sv39 (39-bit virtual address, three levels), translating one address requires reading the root PTE, then a level-1 PTE, then a level-0 PTE. Each is a memory access that may itself miss. A DTLB hit reduces this to a single-cycle CAM lookup.

A typical hierarchy:

| Structure | Entries | Organization | Latency |
|---|---|---|---|
| L1 DTLB | 32–64 | Fully associative CAM | 1 cycle, parallel with cache index |
| L2 TLB (unified) | 1024–2048 | 8-way set associative | 4–8 cycles |
| PTE cache / walk cache | 16–32 | Caches non-leaf PTEs | Saves walk levels |
| Page table walker | 1–4 units | Hardware FSM | 20–200 cycles |

The L1 DTLB is fully associative because it must support **multiple page sizes** simultaneously. A set-associative structure indexed by VPN bits cannot handle a 2 MiB superpage and a 4 KiB page in the same array without either replicating the superpage across all sets it could map to (wasteful) or having separate arrays per size (common in practice — many designs have a 4 KiB-only set-associative array plus a small fully associative array for superpages).

### Q24. Walk through an Sv39 page table translation in detail.

**Sv39** — *RISC-V's 39-bit virtual address, three-level page table scheme for RV64.* The virtual address decomposes as:

```
 38      30 29      21 20      12 11        0
+----------+----------+----------+-----------+
|  VPN[2]  |  VPN[1]  |  VPN[0]  |  page off |
|  9 bits  |  9 bits  |  9 bits  |  12 bits  |
+----------+----------+----------+-----------+
Bits [63:39] must all equal bit 38 (canonical check, Q6)
```

The walk, given `satp.PPN` as the root:

```
a = satp.PPN * 4096
for i = 2 downto 0:
    pte = mem[a + VPN[i]*8]              # 8-byte PTE
    if !pte.V or (!pte.R and pte.W): fault
    if pte.R or pte.X:                    # leaf found
        if i > 0 and pte.PPN[i-1:0] != 0: fault    # misaligned superpage
        goto permission_check
    a = pte.PPN * 4096                    # descend
fault                                     # ran out of levels
```

A leaf at level 2 is a **1 GiB superpage**, at level 1 a **2 MiB megapage**, at level 0 a normal **4 KiB page**.

The PTE format:

```
63    54 53      28 27  19 18  10 9 8 7 6 5 4 3 2 1 0
+-------+----------+------+------+---+-+-+-+-+-+-+-+-+
|reserved| PPN[2]  |PPN[1]|PPN[0]|RSW|D|A|G|U|X|W|R|V|
```

- **V** valid, **R** read, **W** write, **X** execute
- **U** user-accessible — an S-mode access to a U=1 page faults unless `sstatus.SUM` is set
- **G** global — the entry is valid in all address spaces, so it survives an ASID-specific `sfence.vma`
- **A** accessed, **D** dirty — see Q26
- **RSW** reserved for software

### Q25. What is a page-table walker and how many should a core have?

The **PTW** — *Page Table Walker, the hardware FSM that performs the memory accesses of a page-table walk on a TLB miss* — issues its PTE reads into the memory hierarchy, usually at the L2 or through a dedicated port on the L1D.

Design decisions:

**How many walkers?** One is enough for an in-order core. An out-of-order core with a large load queue benefits from 2–4, because independent TLB misses can then overlap. This is **MLP for translations** — *memory-level parallelism, the number of independent memory accesses in flight simultaneously* — and it matters a lot for pointer-heavy and large-footprint workloads.

**Where do PTE reads go?** Three options:
- Into the L1D. Simple, but PTEs pollute the L1D and the walker contends with real loads for the port.
- Into the L2 directly with a dedicated port. Keeps L1D clean; adds L2 port cost.
- Into a dedicated **PTE cache / page walk cache** — *a small cache of non-leaf PTEs, indexed by the partial VPN* — backed by the L2. This is the standard high-performance answer, because non-leaf PTEs have enormous reuse: every page in a 2 MiB region shares the same level-1 PTE. A 16-entry walk cache typically eliminates 60–80% of walk memory accesses.

**Coherence.** PTE reads must be coherent with other harts' page-table writes only to the extent the spec requires, which for RISC-V is: not at all until an `sfence.vma`. This means the walker may read PTEs non-coherently, but most designs make them coherent anyway because it is simpler than proving the software always fences.

### Q26. What are the A and D bits and how does hardware handle them?

**A (Accessed)** is set when a page is read, written, or fetched. **D (Dirty)** is set when a page is written. The OS uses them for page replacement and for knowing which pages must be written back to swap.

RISC-V permits two implementations, selected by the `Svadu` extension:

1. **Software management (the base behaviour).** If the walker finds `A=0` on any access, or `D=0` on a store, it raises a **page fault** even though permissions are fine. The OS trap handler sets the bit and returns. Simple hardware, but the fault cost (~1000 cycles) is paid on the first touch of every page.
2. **Hardware update (Svadu).** The walker atomically sets A and, for stores, D, using an AMO or a load-reserved/store-conditional sequence on the PTE. This must be atomic because another hart may be walking the same PTE.

The atomicity requirement is the hard part. A correct implementation does a compare-and-swap on the PTE: read it, check it has not changed, write it back with the bits set. If the CAS fails, restart the walk. A naive read-modify-write loses concurrent updates and can resurrect a PTE the OS just invalidated.

Note that the LSU must know whether the operation is a load or a store **before** the walk completes, because D is only set for stores. This means the walker needs the access type carried along with the miss.

### Q27. What is `sfence.vma` and what must the LSU do when it executes?

```asm
sfence.vma           # invalidate everything
sfence.vma x11       # invalidate translations for the virtual address in x11
sfence.vma x0, x12   # invalidate all translations for the ASID in x12
sfence.vma x11, x12  # invalidate the (vaddr, ASID) pair
```

**`sfence.vma`** — *supervisor fence, virtual memory address; orders page-table writes before it against implicit page-table reads after it, and flushes stale TLB state.*

What the LSU must do:

1. **Drain or complete all in-flight translations.** Any load or store that has already read a TLB entry but not yet completed is using a translation that may now be stale. Most designs simply flush the LSU pipeline and replay.
2. **Invalidate matching TLB entries.** For the address-specific forms this is a CAM match; for the flush-all form it is a global valid-bit clear (one cycle if you use a flash-clear array).
3. **Respect the G bit.** An ASID-specific fence must *not* invalidate global entries — those belong to the kernel and are valid across all address spaces. Getting this backwards is a correctness bug that only manifests under context switching load.
4. **Order against the store buffer.** The page-table write that preceded the fence may still be sitting in the store buffer. The fence must make it visible to the walker before any post-fence translation. Either drain the store buffer, or make the walker snoop it.

Point 4 is the one people miss. A page-table update is just an ordinary store to memory; nothing makes it special to the store buffer. If the walker reads the PTE from L2 while the new value sits in the store buffer, the walk uses stale data.

### Q28. What are PMAs and how do they affect the LSU?

**PMA** — *Physical Memory Attributes: the fixed, per-address-region properties of the physical address map.* Unlike PMPs, PMAs are not programmable per-hart; they describe what the memory system physically is.

The attributes that matter to the LSU:

| Attribute | Values | LSU consequence |
|---|---|---|
| Memory type | Main memory / I/O / vacant | I/O accesses bypass the cache |
| Cacheability | Cacheable / non-cacheable | Determines whether a miss allocates |
| Coherence | Coherent / non-coherent | Determines whether snoops apply |
| Idempotency | Idempotent / non-idempotent | Non-idempotent regions forbid speculative and repeated access |
| Atomicity support | None / LR-SC / AMO subsets | An AMO to a region without support raises access fault |
| Alignment | Misalignment supported or not | Q8 |

**Idempotency** is the subtle one. *An idempotent region gives the same result if an access is performed more than once and has no side effects.* Main memory is idempotent; a UART FIFO is not — reading it twice pops two characters. Therefore:

- The LSU must **never issue a speculative load to a non-idempotent region.** In an OoO core this means a load to I/O space must wait until it is non-speculative (at or near the head of the ROB).
- The LSU must **never replay** an access to a non-idempotent region. If your MSHR replay mechanism re-issues an access, that is illegal for MMIO.
- **Prefetchers must be masked** to idempotent regions only.

In practice the PMA checker is a small set of hardwired address-range comparators producing an attribute bundle, checked in parallel with the TLB and combined with the PMP result.

### Q29. What is PMP and where does the check happen?

**PMP** — *Physical Memory Protection: a set of CSR-programmed address-range registers that grant or deny R/W/X permission on physical addresses, enforced regardless of paging.* It is RISC-V's mechanism for M-mode to sandbox lower privilege levels without paging, and for isolating firmware from the OS.

Up to 64 entries, each a `pmpaddrN` register plus a field in `pmpcfgN`:

```
pmpcfg bits:  [7]=L (lock)  [4:3]=A (mode)  [2]=X  [1]=W  [0]=R
A modes: 0=OFF, 1=TOR (top of range), 2=NA4 (naturally aligned 4 bytes), 3=NAPOT
```

**NAPOT** — *naturally aligned power-of-two region, encoded by a run of 1s in the low bits of `pmpaddr`.* `pmpaddr = 0x...0111` encodes a 32-byte region. Decoding NAPOT requires finding the lowest zero bit — a priority encoder — and then masking.

**Where the check happens:** on the *physical* address, so after translation. This puts PMP squarely on the load critical path in the DC2 stage. Because a 64-entry PMP with priority selection (lowest matching entry wins) is a wide comparison, high-performance designs:

- Cache the PMP result in the TLB entry. Since PMP regions are usually much larger than a page, the permission outcome can be computed once at TLB-fill time and stored as three bits in the TLB. Any `pmpcfg` write then flushes the TLB. This is by far the most common optimization.
- Limit the implemented PMP count to 8 or 16 rather than the maximum 64.

### Q30. How does the TLB interact with the cache index in a VIPT design?

This is the central timing trick of every L1 data cache. See Q34 for the cache side; here is the translation side.

In Sv39, the low 12 bits of the virtual address are the **page offset** and are *not translated* — they pass through unchanged to the physical address. Therefore:

```
VA[11:0] == PA[11:0]     always
```

If the cache index and block offset together fit in 12 bits, the cache can start its SRAM access using untranslated virtual bits *in parallel with* the TLB lookup, and only needs the translated bits (the **PPN** — *physical page number*) at tag-compare time, one stage later.

The constraint is:

```
index_bits + offset_bits <= 12
=> num_sets * line_size <= 4096
=> cache_size / associativity <= 4096
```

So a 4 KiB page limits you to 4 KiB per way. A 32 KiB L1 must therefore be at least 8-way associative. This is why essentially every high-performance L1D is 32 KiB 8-way or 48 KiB 12-way — the associativity is forced by the page size, not chosen for hit rate.

### Q31. What is the synonym / aliasing problem and how is it solved?

**Synonyms (aliases)** — *two different virtual addresses that map to the same physical address.* Common with shared memory, `fork` copy-on-write, and file mappings.

If a VIPT cache's index uses any virtual bits *above* bit 11, two synonyms can index different sets, so the same physical line could be cached twice. A write to one copy leaves the other stale — a correctness bug.

Solutions:

1. **Keep index within the page offset.** If `index_bits + offset_bits ≤ 12`, the index is physical, no synonyms are possible, and the problem vanishes. This is the standard answer and the reason for the 8-way constraint in Q30.
2. **Page coloring.** The OS guarantees that synonyms agree in the overlapping bits. Works, but requires OS cooperation, which a hardware designer cannot assume.
3. **Physical-index reverse lookup.** On a fill, check the other possible sets for an existing copy and invalidate it. Requires a reverse-mapped structure and adds fill latency.
4. **PIPT** — physically indexed, physically tagged. No aliasing at all, but the TLB is now in series with the cache index, adding a full cycle to load-to-use. Common at L2, essentially never at L1.

Note that **homonyms** — *the same virtual address meaning different things in different address spaces* — are a separate problem, solved by including an **ASID** (*address space identifier*) in the TLB tag, or by flushing the TLB on every context switch.

### Q32. What happens on a DTLB miss in the middle of a pipelined load stream?

A DTLB miss is not a fault; it is a long-latency event. The sequence:

1. **DC1**: DTLB CAM misses. The load cannot produce an address, so it cannot access the tag array meaningfully.
2. The load is **parked**. Options: hold it in the load queue and replay later (OoO), or stall the pipeline behind it (in-order). Parking is much better because it lets younger, TLB-hitting loads proceed — this is the same hit-under-miss principle as Q69, applied to translation.
3. A **TLB MSHR** (sometimes called a translation-miss buffer) is allocated. Like a data MSHR, it must merge: two loads to the same page miss once, not twice.
4. The walker runs. If it hits the L2 TLB, ~6 cycles. If it must walk, 20–200.
5. On completion, the L1 DTLB is filled, and every load parked on that TLB MSHR is woken and replayed.
6. If the walk faults, every parked load must be woken with a fault indication — and only the *oldest* one should actually take the trap in an OoO machine.

Step 6 is a classic bug source: a faulting walk that wakes multiple loads must not raise multiple traps, and must not lose the fault if the oldest load is squashed for an unrelated reason.

---

## Section 4 — L1 data cache organization

### Q33. What are the key parameters of an L1 data cache and how are they chosen?

| Parameter | Typical | Driven by |
|---|---|---|
| Capacity | 32–64 KiB | Hit rate vs. access latency and area |
| Line size | 64 B | Bus width, spatial locality, false sharing |
| Associativity | 8–12 way | Forced by VIPT constraint (Q30) |
| Indexing | VIPT | Load-to-use latency |
| Write policy | Write-back | Bandwidth to L2 |
| Allocation | Write-allocate | Locality of subsequent accesses |
| Banks | 4–16 | Number of load ports |
| MSHRs | 8–16 | Desired MLP |
| Replacement | Pseudo-LRU / RRIP | Hit rate |

A few of these deserve comment. **Line size 64 B** is nearly universal because it matches the DRAM burst and the coherence granule of essentially every interconnect. Larger lines improve spatial locality but worsen **false sharing** — *two harts writing different bytes of the same line, causing the line to ping-pong between caches even though there is no real data race*.

**Write-back** — *dirty data is written to the next level only on eviction, not on every store* — is universal at L1 because write-through would need L2 bandwidth equal to the store rate.

### Q34. Explain VIPT, PIPT, and VIVT with their trade-offs.

| Scheme | Index from | Tag from | Latency | Aliasing | Context switch |
|---|---|---|---|---|---|
| **VIVT** | Virtual | Virtual | Fastest — no TLB in path | Yes, and homonyms too | Must flush or use ASID |
| **VIPT** | Virtual | Physical | Fast — TLB parallel with index | Only if index exceeds page offset | Clean |
| **PIPT** | Physical | Physical | Slowest — TLB in series | None | Clean |

**VIPT** — *Virtually Indexed, Physically Tagged.* The index comes from untranslated `VA[11:6]`, so the SRAM access starts immediately; the tag compare uses the `PPN` from the TLB, which arrives one stage later. This gets PIPT's correctness at VIVT's speed, subject to the size constraint of Q30.

The timing diagram for a 3-cycle load:

```
Cycle 1 (AG) : rs1 + imm -> EA
Cycle 2 (DC1): DTLB CAM  ||  tag SRAM read  ||  data SRAM read  ||  way predict
Cycle 3 (DC2): tag compare (PPN vs tags) -> hit/way -> way mux -> rotate -> extend
Cycle 4      : dependent instruction executes
```

The two SRAM reads and the TLB happen in the same cycle because none of them depends on the others. That parallelism is the entire point.

### Q35. What is a way predictor and how much does it help?

A **way predictor** — *a small structure that guesses which way of a set-associative cache holds the requested line, so that only that way's data array is read and the result is used before the tag compare completes.*

The most common form is a **µtag** (micro-tag) array: store 8 bits of the address tag per way per set, compare all 8 µtags, and use the match to select a single way.

```
Without prediction: read all 8 ways of data (8x energy), mux after tag compare
With prediction:    read 1 way of data (1x energy), tag compare only validates
```

Benefits:
- **Energy**: reading one 64 B way instead of eight cuts data-array read energy ~8×. On a load-heavy workload this is 10–15% of core power.
- **Latency**: the way mux moves off the critical path. The tag compare becomes a *validation* that arrives in parallel with the data being consumed, and a mismatch triggers a replay.

Costs:
- **Misprediction replay.** A µtag mispredict (aliasing in 8 bits) costs a 1–2 cycle replay. Rate is typically <1%.
- **The predictor must be updated on fill and invalidated on eviction and snoop-invalidate**, or it will point at the wrong line.

### Q36. What replacement policies are used in L1 data caches?

**True LRU** — *evict the least recently used line* — requires `log2(A!)` bits per set: 16 bits for 8-way. Rarely implemented above 4-way.

**Pseudo-LRU (tree PLRU)** — *a binary tree of `A-1` bits, each pointing away from the more recently used subtree.* 7 bits for 8-way. On access, walk the tree setting each bit to point away from the accessed way; on eviction, follow the bits down to a victim. Cheap and within 1–2% of true LRU hit rate.

**RRIP (Re-Reference Interval Prediction)** — *each line carries a 2-bit prediction of how soon it will be re-referenced; new lines are inserted with a "distant" prediction so streaming data does not evict useful data.* SRRIP inserts at 2 (of 0–3), promotes to 0 on hit, and evicts the first line at 3, incrementing all if none found. This resists **cache thrashing** — *a working set larger than the cache causing every access to miss because lines are evicted before reuse* — much better than LRU. Typically 3–8% MPKI improvement at L2/L3; less at L1 where working sets are smaller.

**Random / not-MRU.** 1 bit per set. Surprisingly competitive at high associativity and used in area-constrained designs.

### Q37. What is write-allocate versus no-write-allocate, and when does each win?

**Write-allocate (fetch-on-write)** — *a store that misses fetches the line into the cache, merges the store data, and marks it dirty.*

**No-write-allocate (write-around)** — *a store that misses is sent straight to the next level; the line is not brought in.*

Write-allocate wins when a store miss is likely followed by more accesses to the same line — true for most code, because of spatial locality and because a stored-to line is often read back. It is the default for L1D.

No-write-allocate wins for **streaming stores** — *large sequential writes with no reuse, such as `memset` of a buffer larger than the cache.* Fetching each line only to overwrite it entirely wastes half the memory bandwidth.

The practical answer is both: use write-allocate by default, plus a **write-combining buffer** (Q38) that detects full-line writes and sends them out without a fetch. RISC-V also provides `cbo.zero` (the **Zicboz** extension) which zeroes a cache block without reading it:

```asm
cbo.zero (x11)       # zero the cache block containing the address in x11
                     # allocates the line in M state with all zeros, no memory read
```

This is the ISA-visible way to get no-fetch behaviour and is what an optimized `memset` uses.

### Q38. What is a write-combining buffer and how does it work?

A **write-combining buffer (WCB)** — *a small set of line-sized buffers that accumulate stores to the same line so they can be sent to memory as one full-line write rather than several partial writes.*

Structure: 4–8 entries, each holding a line address, a full line of data, and a per-byte valid mask.

Operation:
1. A store to a write-combining region (or a store missing in a no-write-allocate cache) looks up the WCB.
2. **Hit**: merge the bytes into the entry, update the mask.
3. **Miss**: allocate an entry, evicting the LRU one.
4. **Eviction / flush**: if the byte mask is all-ones, issue a full-line write with no read-for-ownership. If partial, either issue a partial write (if the bus supports byte enables, which AXI does) or read the line first and merge.

The win is on `memcpy`/`memset`: eight `sd` instructions to one line become one 64 B bus transaction instead of eight 8 B transactions, and if the line is fully covered, the read-for-ownership is eliminated entirely — halving memory traffic.

Ordering caveat: the WCB reorders and merges writes, so it must be flushed by a `fence w,w` and by any access that requires ordering. For this reason WCBs are typically restricted to regions with a "write-combining" PMA, not applied to ordinary coherent memory.

### Q39. How does a store actually get written into the data array?

A store never writes the cache from the execution pipeline. The sequence is:

1. **Execute**: AGU computes the address, alignment and permissions are checked, the tag array is probed to determine hit/miss and way. The store data is captured. Nothing is written.
2. **Allocate**: the store is placed in the **store buffer** with `{physical address, data, byte mask, way, valid}`.
3. **Commit**: when the store retires from the ROB (or reaches the head in an in-order core), it becomes **non-speculative** and is marked as eligible to drain.
4. **Drain**: on a cycle when the data array has a free port — typically a cycle when no load is using that bank — the store buffer writes the data array using the recorded way and byte mask.

Step 4 is why the store buffer exists: it decouples the store's commit from data-array port availability, so stores are "free" whenever there is a spare bank cycle. A well-designed store buffer drains almost entirely into load shadow, costing zero performance.

The recorded **way** matters. If between execute and drain the line is evicted or invalidated by a snoop, the recorded way is stale and writing it would corrupt an unrelated line. Every store buffer entry must therefore be checked against evictions and snoops, and re-probe the tag array if hit.

### Q40. What is a dirty bit and how is write-back handled?

Each line carries a **dirty bit** — *set when the line has been modified in this cache and not yet written to the next level.* On eviction, a dirty line must be written back; a clean line can simply be dropped.

The write-back path:
1. Replacement policy selects a victim way.
2. If the victim is dirty, its data is read out of the array and pushed into a **write-back buffer (victim buffer)** — *a small FIFO holding evicted dirty lines awaiting transmission to L2*.
3. The new line is filled into the way immediately; the write-back proceeds in the background.

The write-back buffer is essential for latency: without it, a miss that evicts a dirty line takes `writeback_time + fill_time` instead of `fill_time`. Two to four entries is usually enough.

**Coherence subtlety**: while a line sits in the write-back buffer it is no longer in the cache but is not yet at L2. A snoop for that address must be answered from the write-back buffer, so the buffer needs a snoop-comparable address CAM. Forgetting this creates a window where a line silently disappears from the coherent system.

### Q41. What is a victim cache and is it still worth building?

A **victim cache** — *a small fully associative cache that holds lines recently evicted from the L1, checked in parallel with (or just after) an L1 miss.* Jouppi's original proposal used 4–16 entries.

It targets **conflict misses** — *misses caused by too many hot lines mapping to the same set, even though the cache as a whole has room.* With a direct-mapped or 2-way L1, conflict misses are a large fraction of all misses and a victim cache recovers most of them.

Is it worth it today? Mostly no, at L1. Modern L1Ds are 8-way (forced by VIPT, Q30), and 8-way associativity already eliminates most conflict misses. The area would be better spent on more MSHRs or a bigger L2.

Where the idea survives:
- As the **write-back buffer** (Q40), which is a victim cache that only holds dirty lines and is required anyway.
- In direct-mapped structures elsewhere in the machine — some way predictors and prefetch tables benefit.
- At L2 in **exclusive hierarchies**, where the L2 *is* effectively a victim cache of L1.

### Q42. How do you handle a snoop or coherence probe in the LSU?

A **snoop (probe)** — *a request from the coherence fabric asking this cache to change or report the state of a line*, e.g. "downgrade to Shared" or "invalidate and return data".

The LSU must handle several interacting structures:

1. **Tag array**: look up the line, change state, possibly read out data. Requires a tag port, which contends with load/store lookups. Give the snoop a dedicated tag port or a fixed priority slot to prevent snoop starvation (which can deadlock the fabric).
2. **Store buffer**: entries holding data for the snooped line represent writes that have not happened yet. If the snoop is an invalidate and we give the line away, the store must re-acquire it later. Simplest correct approach: do not let a snoop invalidate a line with a pending committed store; **NACK** or stall the snoop until the store drains. Careful — this can deadlock if the other hart is waiting on you.
3. **MSHRs**: a snoop to a line with an outstanding fill must be ordered against the fill. This is the source of most coherence protocol bugs.
4. **Load queue (OoO only)**: a snoop-invalidate to a line whose data has already been speculatively read by an executed-but-not-retired load may violate the memory model. That load must be squashed. This is the **load-load ordering** check of Q86.
5. **Way predictor and LSU-internal caches**: must be invalidated too.

### Q43. What is the difference between inclusive, exclusive, and NINE hierarchies?

- **Inclusive**: every line in L1 is also in L2. Snoop filtering is easy — L2 knows what L1 holds, so a probe that misses L2 need not go to L1. Cost: L2 capacity is partly wasted duplicating L1, and an L2 eviction must **back-invalidate** the L1 copy.
- **Exclusive**: a line is in L1 *or* L2, never both. Total effective capacity is `L1 + L2`, which matters when L2 is not much larger than L1. Cost: every L1 eviction must be written into L2 (even clean lines), and snoop filtering requires a separate directory.
- **NINE (Non-Inclusive Non-Exclusive)**: no enforced relationship. L2 fills do not evict from L1, L1 evictions may or may not go to L2. Most flexible, needs a snoop filter, and is what most modern designs use for L2/L3.

For the LSU specifically, the consequence is **back-invalidation traffic**. In an inclusive hierarchy, the L1 must accept invalidations caused purely by L2 capacity pressure, which look identical to coherence invalidations but are far more frequent. Your L1 invalidate path must be able to sustain that rate without stalling loads.

### Q44. How is ECC or parity handled in an L1 data cache, and what does it cost the LSU?

**Parity** — *one bit per protected word, set so the total number of 1s is even (or odd); detects any single-bit error but corrects nothing.*

**SECDED ECC** — *Single Error Correct, Double Error Detect: a Hamming code with an extra overall parity bit; 8 check bits per 64 data bits.*

The standard arrangement:

- **Tag array**: parity, sometimes ECC. A tag error can cause a false hit (returning wrong data) so it must at minimum be detected. Detection turns the access into a miss and a re-fetch, which is a clean recovery.
- **Data array, write-through cache**: parity is sufficient. A detected error is recoverable by re-fetching from L2, because L2 has a valid copy.
- **Data array, write-back cache**: **ECC is mandatory**. A dirty line is the only copy in the system; detecting an error without being able to correct it means unrecoverable data loss and a machine check.

Costs to the LSU:

1. **Latency.** ECC decode is a syndrome computation plus a correction XOR — roughly 2–3 gate levels beyond the array output. On the load critical path this is often a full extra cycle. The standard mitigation is **speculative forwarding**: send the uncorrected data to the dependent instruction immediately, run the ECC check in parallel, and if it fails, squash and replay. Since errors are astronomically rare, this costs nothing in practice.
2. **Read-modify-write on partial stores.** ECC is computed over a granule, usually 64 bits. A `sb` writes 8 bits, which is less than a granule, so the hardware must read the granule, merge the byte, recompute ECC, and write back. This turns a 1-cycle store into a 2-cycle RMW. Mitigations: use a smaller ECC granule (more check bits, more area), or buffer partial stores in the store buffer until they can be merged into a full granule.
3. **Area.** 8 check bits per 64 data bits is 12.5% overhead on the data array.

---

## Section 5 — Store buffer and store-to-load forwarding

### Q45. What is a store buffer and why can stores not write the cache immediately?

A **store buffer (SB)** — *a small FIFO-like structure holding stores that have executed but not yet been written into the cache* — exists because a store must not become visible to the rest of the system before it is architecturally committed.

Two independent reasons force this:

1. **Speculation.** In an OoO core, an instruction after a branch may execute before the branch resolves. If a store wrote memory immediately and the branch was mispredicted, the write cannot be undone — memory has no rollback. The store buffer holds the write until the store retires (is known non-speculative).
2. **Exceptions must be precise.** Even in an in-order core, a store's *own* address or permission check might fault, or an older instruction might fault after the store executed. Memory changes are the one type of state that genuinely cannot be undone, so nothing may touch memory until it is certain no earlier exception will occur.

The store buffer is also what makes store latency invisible to the pipeline: once allocated, the store retires immediately from the pipeline's point of view, and the actual data-array write happens later whenever a bank is free (Q39).

```asm
sw   x10, 0(x11)     # allocates in SB, drains to cache later
beq  x12, x13, target  # if this was mispredicted and sw were already
                       # committed to memory, there would be no way back
```

### Q46. What fields does a store buffer entry need?

A representative entry:

```
valid        : 1 bit    - entry in use
addr_valid   : 1 bit    - address has been computed
data_valid   : 1 bit    - data has been captured
committed    : 1 bit    - non-speculative, safe to drain
addr_phys    : 44 bits  - physical line address (or full byte address)
way          : 3 bits   - cache way, if hit was determined at execute time
data         : 64 bits  - store data, already rotated into place
byte_mask    : 8 bits   - which bytes are valid (Q14)
age / seq_id : N bits   - program order, for forwarding priority (Q49)
is_io        : 1 bit    - PMA-derived, must not be combined or reordered
size         : 2 bits   - for sub-word forwarding checks
```

`addr_valid` and `data_valid` are separate because the address and the data can become known on different cycles — the base register might be ready before the store's data-producing instruction finishes. Forwarding logic (Q47) must not use an entry until *both* are valid; using an address-valid-only entry for forwarding is a classic bug that silently forwards garbage.

### Q47. Explain store-to-load forwarding end to end.

**Store-to-load forwarding (STLF)** — *supplying a younger load's data directly from an older, not-yet-drained store in the store buffer, instead of from the cache.*

```asm
sw   x10, 0(x11)     # store 0x1234_5678 to address A
ld   x12, 0(x11)     # load from address A — must see 0x1234_5678,
                     # even though the cache at A may still hold old data
```

Steps:

1. Load computes its address (Q13).
2. In parallel with the cache tag lookup, CAM the store buffer's `addr_phys` fields against the load's address.
3. Among all matching entries, select the **youngest store older than the load** (Q49) — there may be several stores to the same address.
4. Check **coverage**: does the matching entry's byte mask cover every byte the load needs? If yes, full forward (Q47 continues below); if partially, either stall or byte-merge (Q20); if no matching bytes, ignore and use the cache.
5. Mux the store's data (already byte-rotated at allocation) directly into the load's result path, bypassing the cache entirely.
6. The load never touches the data array's coherence state for those bytes — it simply never learns whether the line was even present in the cache.

Forwarding must consider **every** store between the load and the start of the buffer, not just the newest — a common bug is comparing only against the most recent store when an older, unforwarded store to the same address is also present but the newest store is to a different address:

```asm
sw   x10, 0(x11)     # store A -> value1
sw   x14, 8(x11)     # store B (different address) -> value2
ld   x12, 0(x11)     # must forward value1 from the FIRST store, not miss it
```

### Q48. What is a store buffer CAM and how is it implemented in RTL?

A **CAM (Content-Addressable Memory)** here is not a dedicated memory macro but a **comparator array**: N parallel equality comparators, one per store buffer entry, each comparing the entry's stored address against the load's address.

```
for i in 0..N-1:
  addr_match[i] = entry[i].valid & entry[i].addr_valid
                & (entry[i].addr_phys == load_addr_phys)
  byte_match[i] = |(entry[i].byte_mask & load_byte_mask)
  candidate[i]  = addr_match[i] & byte_match[i]
```

Then a **priority selector** picks the youngest candidate that is still older than the load, typically using the age/seq_id field and a priority encoder that scans from "closest to the load, going backward in age."

For an 8–16 entry store buffer this is entirely combinational and fits comfortably in a cycle. Beyond ~32 entries, the fan-in of the final select mux becomes the bottleneck, and designs split the CAM into two levels (compare in one cycle, select in the next) — the same technique as Q22's index-then-full-tag approach.

### Q49. Why does store-to-load forwarding need program order / age information?

Because multiple stores to the same address can be in the buffer simultaneously, and the load must see the value from the *closest preceding* store, not an arbitrary one.

```asm
sw   x10, 0(x11)      # value1 -- older
sw   x14, 0(x11)      # value2 -- younger, same address
ld   x12, 0(x11)      # must forward value2, NOT value1
```

Implementations tag every instruction with a monotonically increasing **sequence number** at decode/dispatch. The store buffer, typically implemented as a circular FIFO in program order, makes this almost free: scan from the tail (oldest) toward the head (youngest) — no, more precisely, scan from the position just older than the load backward to the oldest entry, and take the **first** hit encountered, which by construction of the FIFO ordering is the youngest qualifying store. This is why store buffers are usually literal FIFOs rather than freely indexed CAMs — the physical entry order encodes age for free.

### Q50. What is a memory-order violation caused by incorrect forwarding, and how is it detected?

If a load executes speculatively (before an older store's address is known, in an OoO machine) and guesses that no forwarding is needed, but the older store's address later resolves to the same location, the load already produced a stale value. Downstream instructions may have consumed that stale value.

This is a **memory order violation**, distinct from a branch misprediction but handled the same way: squash the load and everything younger, and re-execute.

Detection mechanism:
1. Every executed load records its address (and often the store-buffer state it saw) in the load queue (Q59).
2. When an older store later computes its address, it CAMs the load queue for any younger load to the same address that already executed without seeing this store.
3. A match means the load ran too early — flag a violation.

```asm
# out-of-order execution allows LD to run before ST's address is known
st_op:  sw   x10, 0(x9)     # address depends on slow-to-produce x9
ld_op:  ld   x12, 0(x11)    # executes first, speculatively assumes no alias
                            # if x9 later equals x11 -> violation, squash ld_op+
```

Cost of a violation is typically similar to a branch misprediction — a full pipeline flush from the load onward — so a good **memory dependence predictor** (Q66) that avoids unnecessary speculation, and avoids *unnecessary* stalling, is valuable in both directions.

### Q51. What is store-set prediction?

**Store sets** — *a memory dependence predictor that learns, per load PC, which store PC(s) it has aliased with in the past, and forces the load to wait for exactly those stores rather than all older stores or none.*

Mechanism (Moshovos's original scheme, still the basis of most implementations):

1. **SSIT (Store Set ID Table)**, indexed by PC: maps a load or store PC to a store-set ID.
2. **LFST (Last Fetched Store Table)**, indexed by store-set ID: holds the instruction ID of the most recently dispatched store in that set.
3. On a violation (Q50) between store S and load L, merge their sets: assign both to the same store-set ID.
4. When a load is dispatched, look up its store-set ID in LFST; if a store from the same set is in flight, the load must wait for that specific store's address (not all stores) before it may execute speculatively past it.

This gets most of the benefit of full speculation (loads still execute early relative to unrelated stores) while eliminating repeat violations for the specific load/store pairs that are known to alias — common in cases like spilled registers reused for different purposes at the same stack slot.

### Q52. What is naive total ordering versus speculative disambiguation, and what do they cost?

**Naive total ordering** — *a load may not execute until all older stores have computed their addresses.* Zero violations, but a store with a slow-to-produce address (e.g., waiting on a multi-cycle multiply or a cache miss) blocks every younger load, even unrelated ones. Measured IPC loss versus full speculation is commonly 10–20% on pointer-heavy code.

**Speculative (full) disambiguation** — *every load executes as soon as its own operands are ready, ignoring older stores with unknown addresses, and violations are caught and repaired after the fact (Q50).* Maximizes MLP, but repair cost multiplies with mispredict rate.

**Store-set-guided disambiguation** (Q51) is the practical middle ground almost every high-performance core uses: speculate by default, but respect specific learned dependencies.

An in-order core sidesteps this entirely (Q12) since stores compute addresses before any younger instruction issues.

### Q53. What is the drain policy for a store buffer, and how does it interact with the cache ports?

**Draining** — *writing a committed store buffer entry's data into the L1 data array, freeing the entry.* Policy choices:

- **Opportunistic**: drain whenever a bank has no load/fill demand that cycle. Maximizes load throughput, at the cost of unpredictable store buffer occupancy — under a long streak of loads, the buffer can fill and eventually stall commit.
- **Guaranteed bandwidth**: reserve one drain slot every K cycles regardless of load demand, bounding worst-case store-buffer occupancy at the cost of a small, constant load throughput tax.
- **Priority-inverted**: if the store buffer occupancy exceeds a high-water mark, drains start winning arbitration over loads, to avoid backpressure into the pipeline (a full store buffer must stall store dispatch, and eventually the whole front end).

A drained entry must still answer forwarding CAMs from loads for one extra cycle if there is any chance a load's lookup and the drain race — otherwise a load could miss the forward window and read the (not-yet-updated) cache. The clean fix is to keep the entry valid for CAM purposes until the write has definitely landed, then invalidate.

### Q54. What ordering must be preserved among stores when draining?

Within the same hart, RVWMO (Q83) requires stores to become visible to *other harts* in an order consistent with certain preserved-program-order rules, and same-address stores must always drain in program order (**store atomicity** — *all other harts see a single total order of writes to the same location*). Reordering same-address stores in the buffer would let some observer see values go "backward."

For different addresses, RVWMO is more permissive: ordinary stores may become globally visible out of order **unless** separated by a `fence` or unless one has release semantics. The store buffer therefore drains in FIFO order by default (simplest, always correct), and only needs out-of-order drain logic if a design specifically wants to exploit RVWMO's relaxation for performance — most designs do not bother, because FIFO draining is simple and the reordering window is a small win.

### Q55. What is store-to-load forwarding latency and why does it typically beat a cache hit?

Forwarding latency is usually **1 cycle faster** than a cache hit, because it skips the tag array entirely — the store buffer CAM produces both the hit signal and the data in the same lookup, whereas a cache hit needs tag compare *then* way-mux the data.

```
Cache hit path:    index -> {tag read, data read} -> compare -> way mux -> align
Forward path:      addr  -> CAM compare -> data mux (already aligned) -> done
```

Because forward data is stored pre-rotated (Q15 mirrored: it's already the raw register value, so the load's own rotate/extend still applies, but there's no way-mux stage), designs sometimes make forwarding *faster* than a cache hit rather than merely comparable, which changes the scheduling assumption for dependents — you cannot always assume a load takes the nominal load-to-use latency; a forwarded load might resolve a cycle earlier or later depending on microarchitecture, so speculative wakeup (Q71) must account for both cases or default to the slower one.

### Q56. How do you handle forwarding across a store that spans two cache lines (misaligned, line-crossing)?

A line-crossing store (Q9) may occupy two store-buffer entries, one per line. A forwarding load that needs bytes from both must be serviced by two matches simultaneously, merged.

```asm
li x11, 0x203C          # store starts near a 64B line boundary at 0x2040
sd x10, 0(x11)          # 0x203C..0x2043 -> spans line 0 and line 1
ld x12, 0(x11)          # forwarding load needs bytes from BOTH SB entries
```

The forwarding mux must therefore support merging two candidate entries when both are marked as "this store's other half," not just selecting a single best match. Many designs simplify by disallowing forwarding across a line-crossing store entirely — stall until it drains — since these are rare and the merge logic is disproportionately expensive for a corner case.

### Q57. What happens when a store buffer is full?

The store buffer has a fixed number of entries (typically 8–32). When full:

1. **Dispatch/rename stalls** for further stores — the instruction cannot be allocated an entry and stays in the issue queue or is not dispatched from decode, depending on pipeline point.
2. In an in-order core, this typically **stalls the whole pipeline** behind the blocked store, since nothing younger can be issued out of order.
3. In an OoO core, only store-consuming resources stall; independent younger instructions can often still issue if the scheduler isn't structured around strict in-order dispatch.

This is why store buffer sizing is a real performance lever, not just a correctness one: a burst of stores (e.g., saving many registers, or a `memset` loop) can exhaust a small buffer and stall the whole front end even though the cache itself is not congested. Sizing follows Little's Law: `entries >= average_drain_latency x store_rate`.

### Q58. How is a store buffer entry retired/deallocated, and what could go wrong?

An entry is freed after its data has been **durably written** into the data array (or forwarded to whatever mechanism makes it visible, e.g. writing straight to a non-cacheable target). The two failure modes to design against:

1. **Freeing too early.** If the entry is deallocated the same cycle the write is issued but before it is guaranteed to complete (e.g., the write got NACKed by a bank conflict and must retry), a subsequent load could miss the forward window and see stale cache data. Fix: only deallocate on a confirmed-complete signal, not on issue.
2. **Freeing too late.** Holding entries longer than necessary (e.g., waiting an extra cycle "to be safe" for every store) wastes buffer capacity and can needlessly stall dispatch (Q57). Fix: pipeline the drain-confirm signal so it arrives the cycle after the write actually commits to the array, not N cycles later "for margin."

A store buffer is one of the highest bug-density blocks in an LSU precisely because of this durably-written boundary condition interacting with drain arbitration, bank conflicts, and snoop invalidation of the target line mid-drain (which must cause a retry, not silent data loss).

---

## Section 6 — Load queue, store queue, and memory disambiguation

### Q59. What is a load queue and what does it track beyond "loads in flight"?

A **load queue (LQ)** — *a structure holding every load from dispatch until it is guaranteed correct and can retire* — tracks, per entry, considerably more than just "in flight":

```
valid, addr, size, sign, dest_reg
executed       : has the load produced a value at least once
speculative    : was it executed before all older stores' addresses were known
snooped        : has a coherence invalidate hit this load's line since execution
forwarded_from : which store buffer entry (if any) supplied the data
seq_id         : program order position
```

The `speculative` and `snooped` bits together implement Q50's violation detection and Q86's memory-model checks: a speculative load whose line is invalidated before it retires might have observed a value that a strict ordering model would forbid, and must be replayed even absent an explicit store-address conflict.

### Q60. What is the difference between a load queue entry being "issued," "executed," and "retired"?

- **Issued**: selected by the scheduler to go to the AGU/cache this cycle. May be re-issued multiple times (replay).
- **Executed**: successfully produced a value — either a cache hit, a forward, or a returned miss fill — and wrote the destination register (speculatively, if OoO).
- **Retired**: reached the head of the reorder buffer / commit point with no outstanding exception or ordering violation; the load is now architecturally final and its LQ entry can be freed.

A single load may be issued several times (miss, replay, miss again) before it executes once, and it may execute once but still need re-validation (Q50, Q86) before it may retire. Conflating "executed" with "done" is a common design-review finding — the entry must stay allocated and monitored for snoops between execute and retire.

### Q61. How does the LSU decide the size of the load queue and store queue independently?

Sizing is driven by different things:

- **LQ size** ≈ the number of loads the reorder buffer can hold in flight before the oldest one retires, which tracks the ROB size and the average load latency. A core with a 200-entry ROB and loads that take 4–300 cycles (including misses) wants an LQ deep enough that a long-latency miss doesn't force everything behind it to stall for lack of an LQ slot — commonly 40–80 entries in wide OoO designs, far fewer (matching pipeline depth) in in-order designs.
- **SQ size** tracks how long stores linger *unretired*, which is normally short (stores retire quickly once their data is ready), so SQ is usually smaller than LQ — commonly half to two-thirds.

Note that "store queue" here can refer either to the pre-retirement structure (tracks speculative stores for disambiguation) or be merged conceptually with the store buffer (Q45, post-retirement, pre-drain); many real designs use one unified structure spanning both roles, with a "committed" bit as the dividing line, to avoid copying entries between two structures.

### Q62. What is a CAM-based load queue and what is its main scalability problem?

Every store, on computing its address, must check every *younger* load in the LQ for a potential violation (Q50) — an **all-to-all comparison**. For an N-entry LQ and M-entry SQ, this is O(N×M) comparators, each a wide (~44-bit) equality check.

This is the classic LSU scalability wall: doubling LQ/SQ size quadruples comparator count. Beyond roughly 64–96 combined entries, the CAM becomes impractical to route and time in one cycle, and designs move to:

- **Bank-partitioned queues**: split the LQ/SQ by address hash into several smaller CAMs, each independently sized, cutting comparator count proportionally while accepting occasional false cross-bank stalls.
- **Filter structures** (Q63) that cheaply rule out "definitely no alias" before paying for a full CAM compare.
- **Bloom-filter based approaches**, common in academic proposals and some real implementations, trading a small false-positive rate for large comparator-count reduction.

### Q63. What is a store-to-load forwarding filter (e.g., a Bloom filter) and why use one?

Rather than CAM-comparing every load against every store's full address, a **filter** answers a cheap, approximate question first: "could this address possibly be in the store buffer/queue at all?"

A simple **address Bloom filter**: hash the address into a small bit vector, set bits on store insertion, and OR them together. A load hashes its own address and checks whether all corresponding bits are set. If not, it is **guaranteed** no matching store exists, and the full CAM (or the cache access) can proceed immediately without waiting for disambiguation logic. If the filter says "maybe," fall back to the full comparator.

Because false positives only cost a redundant full check (never a false negative — the filter must be conservative), this is safe, and because most loads in most programs do *not* alias with any pending store, the fast "definitely not aliased" path is taken the overwhelming majority of the time, saving both energy and, in some pipeline organizations, a cycle.

### Q64. What is a non-speculative store and how does the LSU know a store is safe to make globally visible?

A store becomes **non-speculative** — *guaranteed to actually happen architecturally, with no possibility of being undone* — only when every instruction older than it, including all older branches, is guaranteed not to fault or be mispredicted. Concretely, this means the store has reached the **head of the reorder buffer** (or, in designs without a full ROB, has passed every structural hazard that could still cause a flush).

Until that point, the store may only exist in the store buffer/queue in "pending" state, visible to forwarding logic for this hart's own later loads, but never drained to the cache or the memory bus, and never visible to other harts. This single rule — no memory write leaves the core before it is architecturally certain — is what makes precise exceptions and correct speculative recovery possible.

### Q65. What is a "younger load bypasses older unresolved store" hazard and how do in-order cores avoid needing to solve it?

This is the OoO-specific problem covered in Q50–Q52. An in-order LSU avoids it structurally: since instructions issue to the LSU in program order, by the time a load's address is being computed, every older store has *already* had its address computed (it issued earlier). There is no window in which a load can race ahead of an address-unknown store, so no disambiguation logic — no CAM, no store sets, no violation detection — is needed at all. This is one of the largest complexity (and verification) savings of choosing an in-order design, and is a major reason in-order cores remain attractive for area- and power-constrained designs even though their raw IPC is lower.

### Q66. What is a memory dependence predictor, distinct from store sets specifically?

More broadly than store sets (Q51), a **memory dependence predictor** is any mechanism that decides, before addresses are known, whether a given load should wait for older stores or execute speculatively. Alternatives to store sets include:

- **Global "always speculate" with full squash-on-violation** — the simplest, described in Q52.
- **Per-load saturating counters**: each load PC has a 2-bit counter; a violation increments toward "wait," repeated non-violations decrement toward "speculate." Cruder than store sets (no store-specific information) but much cheaper.
- **Distance-based predictors**: predict how many older stores (by count, not identity) a load must wait for, useful when the aliasing store is always a fixed number of instructions back (common in loop-carried stack spill patterns).

Store sets generally win on accuracy per bit of storage because they capture the *specific pairing*, not just "this load is risky," but simpler predictors remain common in area-constrained in-order-with-limited-OoO-memory designs (some cores allow only loads, not general instructions, to go out of order — "OoO loads only" — and use a lightweight predictor there).

### Q67. What is a load-load ordering hazard and why does an in-order core still need to think about it?

Even without store reordering, a **load-load hazard** can arise from cache-line invalidation: hart A performs load L1 from address X, then load L2 from address Y. Another hart's coherent write to X invalidates the line between L1 and L2. RVWMO's default ordering (Q83) does not require L1 and L2 to be globally ordered relative to other harts' operations *unless* other conditions apply, but certain profiles and certain instruction sequences (e.g. with `fence r,r`, or on RVTSO-following implementations) do require it. An in-order core issuing L1 and L2 in program order is naturally compliant with the common cases, but a design that allows a load to be replayed and thus **re-executed** after a later load has already completed can violate ordering if it isn't careful about which value the replay picks up — this is why even simple in-order machines must track "has this line been invalidated since I read it" for any load that might still be observed.

### Q68. How does the LSU handle a load that is younger than a store to an unresolved address, when the core wants some (but not full) OoO memory behavior?

A common middle-ground design ("partial OoO," seen in several application-class in-order-issue cores that still allow limited reordering around long-latency misses) allows loads to bypass *known-non-aliasing* stores only:

1. If an older store's address is already computed and does not match the load's address, the load is free to proceed — this needs only the same CAM comparison used for forwarding (Q47), reinterpreted as a "definitely safe" signal rather than a "definitely forward" signal.
2. If an older store's address is *not yet* computed, the load must wait, full stop — no speculation, no store-set prediction, no violation-and-replay machinery.

This captures a meaningful fraction of the OoO benefit (unblocking loads behind stores whose *address happens to already be known*, which is common when the store's address computation is simple even if its data is a slow multiply) with none of the violation-detection complexity of Q50, at the cost of missing the harder case (address itself is slow to compute).

---

## Section 7 — Non-blocking caches, MSHRs, and replay

### Q69. What is a non-blocking (lockup-free) cache and why is it essential for performance?

A **blocking cache** stalls *all* accesses while a miss is being serviced. A **non-blocking (lockup-free) cache** — *a cache that continues to accept and service new accesses while one or more misses are still outstanding* — is essential because DRAM latency (150–300+ cycles) is two orders of magnitude larger than a hit (3–4 cycles); stalling the whole cache on every miss would waste that entire gap even when unrelated independent accesses are ready to proceed.

Two distinct capabilities are usually distinguished:

- **Hit-under-miss**: while one miss is outstanding, a *hit* to a different line can still complete.
- **Miss-under-miss (miss-under-multiple-misses)**: while one miss is outstanding, a *second, independent miss* can also be issued and tracked concurrently. This is what actually delivers **MLP** — *memory-level parallelism, multiple memory requests in flight simultaneously, overlapping their latencies instead of summing them.*

The number of misses that can be tracked simultaneously is set by the **MSHR file** size (Q70) — this single number is often the tightest practical limit on achievable memory bandwidth on real workloads, more so than raw DRAM bandwidth.

### Q70. What is an MSHR and what fields does it contain?

**MSHR** — *Miss Status Holding Register: a hardware structure that records everything needed to (a) know a miss to a given line is already outstanding, (b) merge further requests to that line instead of issuing duplicate fill requests, and (c) know what to do with the data and which waiting instructions to wake when the fill returns.*

Representative fields:

```
valid          : entry in use
addr           : missing line's physical address
issued         : has the fill request been sent to L2/memory
type           : load-miss / store-miss(allocate) / prefetch / PTW
subentries[K]  : per-request info for MERGED requests to the same line:
    dest_reg, size, sign, byte_offset, ROB/LQ index, seq_id
data_pending   : (for store-miss) the store's data + mask to merge on fill
```

The `subentries` array is what implements **merging**: if load A misses on line X and, two cycles later, load B (different offset, same line) also misses, B does not issue a second fill request — it just adds a subentry to A's MSHR. When the fill returns, every subentry is serviced (data extracted, sign-extended, and forwarded to its own destination) from the single returned line.

### Q71. Walk through the full miss-to-fill sequence for a load, including replay.

```
Cycle 0  : Load executes. Tag compare misses.
Cycle 0  : Allocate MSHR (or merge into an existing one, Q72). If MSHR
           file is full, the load must be retried later (Q74).
Cycle 0  : Load is marked "not executed" in the LQ (Q60) and parked.
Cycle 1..N: Fill request travels to L2 (and possibly further). While
           waiting, OTHER independent loads/stores continue to issue and
           execute normally -- this is the whole point of non-blocking.
Cycle N  : Fill data returns, is written into the data array (allocating
           a way per the replacement policy), tag is set valid.
Cycle N  : Every subentry in the MSHR is serviced: byte-extract, sign-
           extend, and WAKE the corresponding load in the scheduler.
Cycle N+1: Woken load(s) re-issue -- this is a REPLAY, not a fresh issue.
           They re-read the (now-present) data from the array like a
           normal hit, or take the data directly from the fill path via
           a "fill-forwarding" bypass to save a cycle.
Cycle N+1: MSHR is deallocated once all subentries are serviced.
```

The **fill-forwarding bypass** (also called "critical word forwarding" when combined with critical-word-first, Q75) is an important optimization: rather than writing the fill into the array and then re-reading it a cycle later, route the returning fill data directly into the load's bypass mux the same cycle it arrives, saving one full cycle of miss latency for every dependent instruction.

### Q72. How does MSHR merging work for two loads to the same line but different words?

```asm
# a and b are on the same 64B line but different offsets, both miss
ld  x10, 0(x11)      # offset 0  -- allocates MSHR for the line
ld  x12, 32(x11)     # offset 32 -- MERGES into the same MSHR
```

On the second load's miss, the LSU checks the MSHR file's `addr` field (line-granular, so both loads' addresses match after masking the offset bits) against all valid MSHRs. A match means: do not issue a second fill request (there is already one in flight for this exact line), just append a subentry `{offset=32, dest=x12, size=8, ...}` to the existing MSHR. When the line returns, both subentries extract their respective bytes from the single line and wake both loads.

This is important for bandwidth as well as latency: without merging, a loop with several loads per iteration that all miss on the same or adjacent lines would issue redundant fill requests, wasting external bandwidth several-fold.

### Q73. What is the difference between primary and secondary misses?

- **Primary miss**: the first request to a given line while no MSHR for it exists. It allocates a new MSHR and actually issues the fill request outward.
- **Secondary miss**: a subsequent request to a line that *already* has an outstanding MSHR. It merges as a subentry (Q72) and issues nothing outward.

This terminology matters for performance counters and for sizing: MSHR file occupancy is bounded by the number of *primary* misses in flight, not total misses, because secondary misses are "free" in terms of MSHR entries (up to the subentry array's own capacity, which is a separate, usually smaller, limit — e.g. 4 subentries per MSHR).

### Q74. What happens when the MSHR file is full and a new (primary) miss occurs?

The new miss cannot allocate, so it cannot proceed. Two structurally different responses exist:

1. **Blocking stall**: hold the missing instruction in place and stall its issue slot / pipeline stage until an MSHR frees up. Simple, but in an in-order machine this stalls everything younger too — turning "should have hit-under-miss" into "temporarily fully blocking," which is a real performance cliff under bursty miss patterns (e.g., the start of a streaming loop before the prefetcher ramps up).
2. **Replay/retry queue**: reject the access (like a structural NACK), keep the instruction's LQ entry marked not-executed, and re-attempt on a later cycle (or when an MSHR-freed event is broadcast). This avoids stalling unrelated younger instructions in an OoO scheduler but adds replay traffic and complexity — and requires that repeatedly failing to acquire an MSHR cannot starve an instruction forever (a fairness/livelock concern, usually solved with an age-priority arbiter for MSHR allocation).

Sizing the MSHR file adequately (8–16 for an L1D in most application-class cores, more for server-class or vector-heavy designs) is usually a better investment than building elaborate replay logic to paper over a too-small file — MSHR count roughly bounds achievable MLP, which bounds effective memory bandwidth under Little's Law: `bandwidth ≈ MSHR_count × line_size / average_miss_latency`.

### Q75. What is critical-word-first and early restart?

**Critical-word-first (CWF)** — *requesting the specific word the demand access actually needs first from the next level, rather than always starting a line fill at its lowest address* — shaves the latency of the fill down to "time to get the one word that's actually needed," rather than "time to get the whole line and then find the word inside it."

**Early restart** — *waking the waiting instruction as soon as its specific word arrives, without waiting for the rest of the line to finish filling* — is the companion technique: the memory system continues streaming in the remaining words of the line in the background (to complete the cache fill for future accesses), while the originally-missing load is serviced and its dependents unblocked immediately.

```
Without CWF+ER: fill line[0..63] fully (say 20 cycles) -> THEN extract byte 40 -> wake load
With CWF+ER:    request word containing byte 40 FIRST (arrives in ~12 cycles)
                -> wake load immediately -> remaining words of the line stream in afterward
```

The gain (roughly 30–40% of line-fill latency in typical DRAM/bus configurations) is largest for wide lines (64B+) and accesses that land toward the end of the line under a naive fixed fill order. The DRAM burst protocol must support a **critical-word-first burst ordering** mode (most do) for this to work end to end; the LSU side needs a small amount of extra bookkeeping to track "which words of this in-flight line have arrived" so it can correctly service late-arriving MSHR subentries for other offsets in the same line.

### Q76. What is a replay queue and how does it differ from simply re-issuing from the load queue?

A **replay queue** is a small, fast structure specifically for instructions that need to retry within a handful of cycles (typically 1–4) for a *known-short* reason — an L1 hit that was invalidated between tag-read and data-consume, a bank conflict, a way-mispredict (Q35) — as opposed to a full miss, which can take hundreds of cycles and is better tracked in the LQ/MSHR path (Q71) rather than a tight replay loop.

Keeping these separate matters because a tight replay loop (a 2–3 entry queue that immediately re-attempts next cycle) can be built with a fast, simple wakeup path optimized for the common, short case, while the LQ/MSHR path is optimized for holding state cheaply over hundreds of cycles for the comparatively rare, long case. Conflating them — e.g. routing every replay through the full LQ re-issue mechanism — adds unnecessary latency to the common short-replay case, which given how frequently way mispredicts and bank conflicts occur (often several percent of all loads), directly costs IPC.

### Q77. What is a load-use hazard in an in-order pipeline and how is it interlocked?

A **load-use hazard** occurs when the instruction immediately following a load consumes the loaded register before the load's data is available.

```asm
ld   x10, 0(x11)     # data available at end of MEM stage (say cycle 4)
add  x12, x10, x13   # needs x10 -- if issued next cycle (3), it reads
                     # the OLD value of x10 unless interlocked
```

In a simple in-order pipeline without full bypassing, the hazard detection unit compares the destination register of instructions in the EX/MEM stage against the source registers of the instruction in ID, and if the producer is a load (not an ALU op, which could bypass combinationally) and there is a match, it **stalls** the consumer (and everything behind it) for exactly the number of cycles needed — typically one bubble — until the load's data is available on the bypass network. This is the same mechanism as any RAW hazard interlock, specialized to loads because loads (unlike ALU ops) cannot forward their result until after the memory stage completes, one stage later than an ALU result would be available.

### Q78. How is exception handling coordinated between the LSU and precise-exception logic for loads and stores?

RISC-V, like nearly all modern ISAs, requires **precise exceptions** — *when a trap occurs, the architectural state must look exactly as if all instructions before the faulting one completed fully, and none of it or after it had any effect.* For the LSU this means:

1. A load's fault (misaligned, access, page fault — Q7) must be detected and tagged on the LQ entry, but **must not** be reported to the trap unit until the load reaches the commit/retire point and is the oldest thing in the machine (or the machine is otherwise certain nothing older will fault first).
2. A store's fault must similarly be tagged but the store must **never have written memory** before the fault is known — which falls straight out of the store-buffer discipline of Q45/Q64: a store isn't drained until non-speculative, and a fault discovered before that point simply prevents the drain and instead raises the trap.
3. If multiple in-flight memory ops fault simultaneously (e.g., an OoO machine with a faulting load and a faulting store both in flight), only the **oldest** one's fault is architecturally reported; all younger operations, faulting or not, are squashed without effect.
4. `mtval`/`stval` must carry the correct faulting address, size, and access type all the way from wherever the fault was detected (which could be the AGU, the TLB, or the PMP/PMA checker, at different pipeline depths) through to the trap unit, tagged to the specific instruction.

This coordination — detect early, act late, report only the oldest — is why exception plumbing threads through essentially every other structure discussed so far (LQ entries, store buffer entries, MSHR subentries all need a fault-pending bit that survives until retire).

---

## Section 8 — Atomics, fences, and the memory model

### Q79. What are LR and SC and how do they implement atomic read-modify-write?

**LR (Load-Reserved)** and **SC (Store-Conditional)** implement a lock-free atomic sequence: LR loads a value and establishes a **reservation** on the address; SC attempts to store, and succeeds only if the reservation is still intact (no other hart wrote to that address since the LR).

```asm
retry:
  lr.w   x10, (x11)         # load old value, set reservation on addr(x11)
  addi   x12, x10, 1        # compute new value = old + 1
  sc.w   x13, x12, (x11)    # store new value IF reservation still valid
  bnez   x13, retry         # x13 = 0 on success, nonzero on failure -> retry
```

This constructs an atomic increment (or any atomic RMW) from ordinary arithmetic plus two special memory instructions, without needing a bus lock. `.w` and `.d` suffixes select 32- or 64-bit; `.aq`/`.rl` suffixes (Q84) add acquire/release ordering.

**Reservation** — *hardware tracking of an address (or, in practice, the cache line containing it) such that any intervening write to that line, by any hart including this one, invalidates the reservation.* SC checks reservation validity, not the old value — this is what distinguishes LR/SC from a compare-and-swap, and it is why LR/SC is subject to the **livelock** hazard of Q80.

### Q80. What is LR/SC livelock and what does the RISC-V spec require to bound it?

Because SC can fail for reasons *unrelated* to the actual data race — a cache eviction, an unrelated coherence probe on the same line, even an interrupt — a naive implementation risks **livelock**: every hart's LR keeps getting invalidated by something before its SC can execute, and no forward progress is ever made even though no hart is malicious or slow.

The RISC-V spec places explicit **eventual-success guarantees** (the "constrained LR/SC loop" rules) on implementations: as long as the LR/SC loop follows a small set of restrictions (no other memory operations of certain kinds between the LR and SC, loop is short, no taken branches out of a certain form), the hardware **must** guarantee an SC eventually succeeds within a bounded number of dynamic instructions, even under contention.

Practical hardware technique: give a hart that has an active reservation and is retrying **priority** to actually complete its SC before yielding the line to another hart's competing LR/SC sequence for a bounded window — effectively a small, temporary exemption from normal coherence fairness specifically for reservation holders. Implementations vary, but the spec's requirement is on the *outcome* (bounded retries succeed), not the mechanism.

### Q81. How is the reservation implemented in the cache, and what invalidates it?

The simplest and most common implementation ties the reservation to **cache-line ownership**: LR requires the line to be brought into an exclusive-capable coherence state (e.g., Modified or Exclusive in a MESI-family protocol) and sets a **reservation-valid bit plus the reserved address**, usually one register per hart (some implementations support a small number of concurrent reservations, but one is typical and spec-compliant).

The reservation is cleared (making a subsequent SC fail) by:

- Any store, by this hart or another, that maps to the **same line** (RISC-V permits an implementation to use line granularity even though the reservation is logically on an address — this is an allowed over-approximation).
- Any coherence probe that downgrades or invalidates the line's coherence state.
- A context switch, trap, or `xret` in many implementations (though not spec-mandated, this is common practice for simplicity, since these events already imply "something changed").
- Some implementations also clear it after a fixed number of cycles as a fallback, though this must be done carefully to not violate the eventual-success guarantee (Q80).

Because reservation tracking piggybacks on the coherence state the line already needs for MESI, the incremental hardware cost is small: one valid bit and one address register per reservation, plus wiring the "cleared" condition into the existing snoop/invalidate path (Q42).

### Q82. What are AMOs and how do they differ from LR/SC in implementation?

**AMO (Atomic Memory Operation)** instructions perform a read-modify-write on memory as a single indivisible operation, without a retry loop:

```asm
amoadd.w  x10, x12, (x11)    # x10 = mem[x11]; mem[x11] = mem[x11] + x12  (atomically)
amoswap.d x10, x12, (x11)    # x10 = mem[x11]; mem[x11] = x12
amoor.w   x10, x12, (x11)
amoand.w  x10, x12, (x11)
amoxor.w  x10, x12, (x11)
amomax.w / amomin.w / amomaxu.w / amominu.w
```

Unlike LR/SC, an AMO **always succeeds** (barring a fault) — there is no failure/retry outcome, which simplifies software but requires the hardware to actually perform the read-modify-write atomically in one indivisible step, typically by acquiring exclusive ownership of the line (as in LR/SC) but then performing the ALU operation **at the cache/memory controller** rather than round-tripping the old value back to the core's ALU and then back out — this is important: doing the add in the core would require holding exclusivity across the round trip, exposed to the same livelock risk as LR/SC, whereas doing it locally at the cache (or even at a near-memory ALU in some server designs) keeps the whole operation within a single, short, uninterruptible cache-controller transaction.

This requires a small **AMO ALU** sitting next to (or inside) the L1D or L2 controller (see the RTL in Part II), separate from the core's main integer ALU.

### Q83. What is RVWMO and what does it guarantee by default?

**RVWMO (RISC-V Weak Memory Ordering)** is RISC-V's default memory consistency model: a **weak/relaxed model** — *the hardware is free to reorder memory operations from different addresses relative to each other, observed by other harts, except where specific ordering rules or explicit fences require otherwise.*

The baseline guarantees, without any fences:

- **Program order is preserved for accesses to the same address** by the same hart (a hart always sees its own prior writes and cannot see its own future writes out of order — "single-hart sequential semantics").
- **Dependencies are preserved**: if instruction B's address, data, or control depends on instruction A's result, A is ordered before B (this rules out certain absurd reorderings a compiler-level model might otherwise allow, but does not provide general ordering between independent operations).
- **No ordering is guaranteed** between two operations to *different* addresses unless a fence, an acquire/release annotation (Q84), or an atomic instruction connects them.

This is deliberately similar to ARM's and POWER's weak models (and unlike x86-TSO, which is much stronger by default) to allow the LSU maximum reordering freedom for performance — but it means correct concurrent software on RISC-V, and the hardware verifying it, must reason carefully about every point where two harts communicate through memory.

### Q84. What do the `.aq` and `.rl` bits do on RISC-V atomics?

Every AMO and LR/SC can carry independent **acquire (`.aq`)** and **release (`.rl`)** annotations:

```asm
lr.w.aq    x10, (x11)      # acquire semantics: no later memory op (by this
                          # hart) may be observed by others before this one
amoadd.w.rl x10, x12, (x11) # release semantics: no earlier memory op may be
                          # observed by others after this one
amoswap.w.aqrl x10, x12, (x11)  # both -- full fence-like barrier around this op
```

**Acquire** — *prevents subsequent memory operations from being reordered before this one, as observed by other harts* — is used when "acquiring" a lock: nothing inside the critical section should be visible to other harts before the lock acquisition is visible.

**Release** — *prevents preceding memory operations from being reordered after this one* — is used when "releasing" a lock: everything done inside the critical section must be visible to other harts no later than the unlock itself becomes visible.

In the LSU, implementing these typically means: an `.aq` operation cannot be allowed to let *younger* loads/stores drain to memory or become globally visible before it does; an `.rl` operation must not itself become globally visible until all *older* memory operations in this hart have already done so. This is enforced by treating `.aq`/`.rl` as light-weight, single-instruction-scoped fences integrated into the store-buffer drain and load-issue logic, rather than by invoking the full heavyweight `fence` machinery (Q85).

### Q85. What does the `fence` instruction do and how is it implemented in the LSU?

```asm
fence rw, rw     # full fence: order all prior memory ops before all later ones
fence r,  r      # order prior loads before later loads only
fence w,  w      # order prior stores before later stores only (rarely sufficient alone)
fence.tso        # a special encoding requesting TSO-like ordering for this fence
fence.i          # instruction-fence: not a memory-ordering fence at all --
                 # synchronizes the instruction fetch stream with recent
                 # stores to code (self-modifying / JIT code); a completely
                 # different mechanism (usually an I-cache/pipeline flush)
```

For the general `fence pred, succ` form, the LSU's job is: **no memory operation in the "succ" (successor) set may become visible to other harts, or even execute past the point of no return, until every memory operation in the "pred" (predecessor) set has completed and become visible.**

A conservative and common implementation: on `fence rw,rw`, stall the front end from dispatching anything younger until (a) the store buffer has fully drained all older stores, and (b) all older loads have retired. This is simple and correct but costly — potentially tens of cycles of a full pipeline bubble on every fence. A less conservative implementation tracks the "pred"/"succ" sets more precisely and only orders the specific instruction types requested (e.g. `fence r,r` need not drain the store buffer at all, only ensure load-load ordering), recovering most of the performance for the narrower fence forms that well-written concurrent code actually uses.

### Q86. How does the LSU verify that a speculatively-executed load did not violate the memory model, beyond the store-disambiguation check of Q50?

Q50 catches the case where an *older store in this hart* aliases a speculatively-executed younger load. But RVWMO also constrains ordering **between harts**, and a purely local store-address check does not catch every violation. The additional mechanism, generally called **load value speculation checking via coherence**, works as follows:

1. When a load executes speculatively (before it is certain to be non-speculative, e.g. before older branches resolve), record which cache line it read and, in some designs, the actual value or a hash of it.
2. Keep monitoring that line for coherence invalidations (the same snoop path as Q42) for as long as the load remains unretired.
3. If any coherence invalidate touches that line before the load retires, this is treated conservatively as a possible violation (the value the load saw *might* not be the value that a strictly-ordered execution would have produced relative to other harts' operations), and the load — and everything younger — is squashed and replayed, exactly as in Q50.

This is deliberately conservative: not every such invalidate is a genuine model violation, but proving precisely which ones are would require far more state than is practical, so hardware over-approximates and accepts some unnecessary replays in exchange for a small, auditable set of invalidation-tracking bits per LQ entry (this is the `snooped` bit introduced in Q59).

### Q87. What is the difference between coherence and consistency, and why does the LSU need to reason about both?

**Coherence** — *a per-address guarantee: all harts eventually agree on a single order of writes to that one location, and every hart eventually sees the most recent write* (this is what MESI-family protocols, Q42, Q43, provide).

**Consistency (the memory model)** — *a whole-program guarantee about the order in which operations to potentially different addresses may appear to different observers* (this is what RVWMO, Q83, specifies).

Coherence alone is not enough to build correct concurrent software: two harts can each individually observe a coherent, correctly-ordered sequence of writes to *each individual address* and still disagree wildly about the relative order of writes to *different* addresses, which is exactly what lets classic bugs like "flag set before data write is visible" occur without a memory model that constrains cross-address ordering. The LSU therefore needs a coherence protocol (to make individual addresses behave sanely) **and** ordering enforcement (fences, acquire/release, store-buffer drain discipline) layered on top (to make the multi-address behavior match RVWMO) — one without the other is insufficient and neither can substitute for the other.

### Q88. What is a memory barrier's interaction with the write-combining buffer and non-cacheable I/O accesses?

Write-combining buffers (Q38) and posted I/O writes are the parts of the memory system most likely to silently violate ordering, because their entire purpose is to reorder and delay writes for efficiency — exactly what a fence must prevent when required.

Rules that must hold:

- A `fence` (or an `.rl` annotation) that is required to order a write-combined store must **flush the WCB entry** (force it out to the bus) as part of satisfying the fence, not merely drain the ordinary store buffer.
- Accesses to **strongly-ordered / device (I/O) memory** (a PMA property, Q28) must bypass the WCB and the ordinary reordering-permissive store buffer path entirely — device register writes (e.g., to a UART control register followed by a data register) frequently *depend* on program-order delivery for correctness, which is stricter than anything RVWMO requires for ordinary memory, so PMA-indicated I/O regions are typically hardwired to strict in-order, unbuffered (or minimally buffered, drain-immediately) treatment regardless of what the general consistency model would otherwise allow.
- A `fence` must be understood by any posted-write buffer in the path to an external bus (e.g., an AXI write buffer outside the core), not just the LSU's own store buffer — end-to-end ordering requires every buffering point between the core and the actual device to respect the fence, which in practice means the fence signal (or an equivalent "drain and acknowledge" handshake) must propagate through the entire write path, not stop at the L1.

### Q89. How does the LSU support `cbo.clean`, `cbo.flush`, and `cbo.inval` (the Zicbom extension)?

```asm
cbo.clean (x11)     # write back the line if dirty, keep it cached (still valid)
cbo.flush (x11)     # write back if dirty, then invalidate the line (removed from cache)
cbo.inval (x11)     # invalidate the line WITHOUT writing back, even if dirty
                    # (data loss if dirty -- software must know this is safe,
                    # e.g. because it is about to be overwritten by DMA)
```

These give software (typically device drivers doing DMA buffer management, or JIT compilers) explicit control over cache-line state that the coherence protocol alone does not expose. Implementation-wise, all three are straightforward extensions of the existing eviction path (Q40): `cbo.clean`/`cbo.flush` reuse the write-back buffer exactly as a normal eviction would, and `cbo.inval` simply skips the write-back step. The main design care needed is ordering: these instructions must interact correctly with the store buffer (a pending store to the same line must be resolved — drained or accounted for — before `cbo.inval` can safely discard the line) and, for `cbo.inval` specifically, the ISA explicitly permits an implementation to make it a **privileged-only or trapped** operation if unprivileged use would create a coherence or security hazard (discarding dirty data another hart still expects to be able to read coherently).

### Q90. What is `cbo.zero` and what is a "zero-fill fast path" in the L1D?

Covered briefly in Q37; expanded here. `cbo.zero (x11)` zeroes an entire cache line **without reading it from memory first**, and the RTL benefit is real: a normal write-allocate store miss must fetch the old line (to merge the partial-store bytes with the unmodified rest), but since `cbo.zero` overwrites the *entire* line, that fetch is provably unnecessary.

The fast path: on a `cbo.zero` miss, allocate the line directly in the requested (often Modified/dirty) coherence state with the data array driven to all zeros — a **fill-bypass**, since there is no actual fill from the next level, just a metadata (tag + coherence state) update and a data-array write of constant zero. This removes both the fetch latency and the fetch bandwidth entirely, which is precisely why an optimized `memset`/`bzero` implementation issues `cbo.zero` in a loop instead of `sd` stores of zero — the latter would pay full fetch cost for data about to be discarded.

---

## Section 9 — Prefetching, PPA, verification, and debug

### Q91. What is a stride prefetcher and how does it interact with the LSU's load path?

A **stride prefetcher** — *a predictor that detects a constant address delta between successive accesses from the same instruction and issues speculative fetches ahead of demand* — is typically implemented as a small table indexed by load PC (or by cache-line address, in an address-based variant), each entry tracking `{last_address, stride, confidence}`.

```asm
loop:
  ld   x10, 0(x11)     # address = base + i*8, a constant stride of 8
  addi x11, x11, 8
  bnez x12, loop
```

On each execution of this load, the prefetcher observes `new_address - last_address == 8` repeatedly, raises confidence, and once confident, issues prefetch requests for `address + stride`, `address + 2*stride`, etc., some configurable distance ahead — far enough to hide DRAM latency, not so far that the prefetched lines are evicted before use.

Interaction with the LSU: prefetch requests **share the MSHR file** with demand misses (Q70), so a poorly-tuned or wrong prefetcher can exhaust MSHRs and delay real demand misses — a serious enough risk that most designs give demand misses strict priority over prefetch allocation, and often cap prefetches to a fraction of the MSHR file (e.g., at most 4 of 16 entries). Prefetches must also respect PMA idempotency (Q28) — never prefetch into non-idempotent (I/O) regions — and typically do not prefetch across a page boundary without a valid, already-cached translation, to avoid speculatively triggering a page-table walk (or worse, a page fault) for an access the program may never actually make.

### Q92. What is a stream buffer and how does it differ from a stride prefetcher?

A **stream buffer** — *a FIFO of prefetch-ahead lines for a single detected sequential stream, decoupled from where they'll eventually be consumed* — is the classic complement to a stride table: rather than (or in addition to) inserting prefetched lines directly into the L1 (competing with demand data for replacement), a stream buffer holds them in a small side structure and only promotes a line into the L1 proper when a demand access actually confirms the stream is still being followed.

This matters for **cache pollution**: a wrong or short-lived prefetch stream that writes directly into the L1 can evict genuinely useful demand data. Keeping speculative prefetch data in a side buffer until confirmed avoids this, at the cost of an extra lookup (check stream buffers in parallel with the L1 tag array) and the modest storage for the buffer itself. Most modern designs use a hybrid: a handful of stream-buffer-style FIFOs for detected sequential streams, plus PC-indexed stride tables (Q91) for indexed/gather-like patterns with a constant but non-unit stride.

### Q93. What is prefetch degree, distance, and how are they tuned?

**Prefetch distance** — *how far ahead of the current demand access (in cache lines) the prefetcher issues requests* — must be large enough that the prefetched data arrives before it's needed: roughly `distance ≥ memory_latency / time_per_iteration`. Too short and the prefetch doesn't hide the latency; too long and the prefetched line may be evicted before use, or may prefetch past the actual end of the useful stream.

**Prefetch degree** — *how many lines ahead are requested per triggering access* — trades bandwidth for aggressiveness: degree 1 issues one prefetch per demand access; degree 4 issues four, filling the memory-level-parallelism pipe faster but consuming proportionally more bandwidth and MSHR occupancy (Q91) for speculative traffic.

Practical designs make both **adaptive**: distance/degree increase when recent prefetches are being used (measured by a "prefetch accuracy" counter — fraction of prefetched lines that are actually touched before eviction) and decrease when accuracy drops, to avoid wasting bandwidth on workloads without exploitable regularity (e.g., pointer-chasing code, where a naive stride prefetcher's accuracy collapses to near zero and an aggressive fixed degree would be pure waste).

### Q94. What area and power costs does a high-performance LSU typically carry, relative to the rest of the core?

Rough, representative breakdown for an application-class core (numbers vary significantly by node and design point, but the *relative* ordering is fairly consistent):

| Component | Typical share of LSU area |
|---|---|
| L1 data array (SRAM) | 35–45% |
| Tag array + way predictor | 8–12% |
| DTLB (L1 + L2) | 10–15% |
| Store buffer + load queue (CAMs) | 15–20% |
| MSHR file | 5–8% |
| AGU + alignment/rotate logic | 3–5% |
| PMP/PMA checkers | 2–4% |

The **CAM structures (store buffer, load queue, disambiguation logic)** are disproportionately expensive relative to their bit count because comparators, not storage cells, dominate their area — this is precisely why Q62's scalability problem is a real constraint and not just a theoretical one, and why in-order designs (which need none of this, Q65) can build a materially smaller LSU for the same cache capacity.

Power-wise, the **data array read** (especially without way prediction, Q35, reading all ways on every access) and the **DTLB CAM** (fully-associative, so every entry compares every lookup) are usually the top two dynamic-power contributors within the LSU, which is why way prediction and DTLB access gating (only searching if a first-level micro-TLB of 4–8 entries misses) are common power-driven additions even in designs that don't strictly need them for timing.

### Q95. What are typical clock-cycle budgets for each LSU pipeline stage in a 3+ GHz design?

Illustrative for a 3-cycle load-to-use design at ~3 GHz (≈333 ps/cycle) in a modern (5–7 nm class) process:

| Stage | Content | Approx. budget |
|---|---|---|
| AG | Register read mux, 64-bit add, low-bits fan-out | ~300 ps |
| DC1 | SRAM access (tag + data, parallel), DTLB CAM, way predict | ~330 ps (SRAM-latency bound) |
| DC2 | Tag compare / way-predictor validation, way mux, rotate, sign-extend, PMP/PMA check, bypass mux drive | ~300 ps |

The DC1 stage is almost always **SRAM-latency bound** rather than logic-bound — a 32 KiB 8-way SRAM macro's access time at a given node is a fixed number that logic optimization cannot meaningfully shrink, which is why way prediction (removing the *dependent* tag-compare-then-mux chain from DC2, not from DC1's SRAM read itself) and split/early-index addressing (Q13, getting the index to DC1 as early as possible) are where the real timing wins are found — you generally cannot make the SRAM itself faster without changing its size or associativity.

### Q96. What LSU-specific coverage points matter most in constrained-random verification?

A representative (non-exhaustive) coverage plan, organized by the failure modes actually seen in real designs:

- **Address boundary crossing**: every load/store size at every byte offset within a line, specifically including the exact offsets that trigger line-crossing (Q9) and page-crossing splits.
- **Store-buffer full-coverage aliasing**: every pairing of {no overlap, partial overlap, full overlap, superset, subset} between a store and a later load, at every relative age distance, including same-cycle (Q21).
- **Multiple stores to the same address**, forwarding must select the correct (youngest, older-than-load) one (Q49) — specifically stress with 2, 3, and buffer-full-many same-address stores pending simultaneously.
- **MSHR merge stress**: N loads to the same line, different offsets, all missing within the same or adjacent cycles, verifying every subentry gets correctly serviced on fill (Q72).
- **MSHR-full backpressure and fairness**: sustained miss rate exceeding MSHR count, verifying no starvation/livelock (Q74) and correct replay ordering.
- **Snoop-during-everything**: a coherence invalidate arriving during each stage of a load/store's lifetime — mid-tag-lookup, mid-fill, mid-store-buffer-drain, mid-forward — each is a distinct race window (Q42).
- **LR/SC interleavings**: back-to-back LR/SC from multiple harts, LR followed by an intervening event from every category in Q81's invalidation list, verifying eventual-success (Q80).
- **Exception-priority ordering**: constructing accesses that could simultaneously trigger misalignment, PMP denial, and page fault, verifying the mandated priority (Q7) is followed in every path (fast/aligned and slow/split, Q19).
- **Fence/acquire-release ordering** cross-checked against a reference RVWMO litmus-test oracle (Q83, Q86) — this category is usually where formal methods (Section below, Q98) outperform simulation, because the state space of "which reordering could a weak model permit" is combinatorially large.

### Q97. What is a memory-consistency litmus test and how is it used to validate the LSU?

A **litmus test** — *a short, carefully constructed multi-hart program with a specific outcome that is either legal or illegal under a given memory model, used to empirically or formally check whether an implementation respects that model.* The classic example is the "message passing" (MP) litmus test:

```asm
# Hart 0                          # Hart 1
sw   x10, 0(x_data)              loop: lw  x12, 0(x_flag)
fence rw, rw                            beqz x12, loop
sw   x11, 0(x_flag)              lw   x13, 0(x_data)
                                  # is x13 GUARANTEED to be the value hart 0 wrote?
```

With the `fence rw,rw` present, RVWMO **guarantees** hart 1, upon observing the flag set, must also observe the data write — this is exactly what the fence is for. A test harness runs this pattern (and dozens of its variants — store-buffering, read-after-read, independent-reads-independent-writes, and so on, drawn from the standard litmus-test literature used across ARM/POWER/RISC-V memory-model validation) thousands or millions of times on the actual RTL (via simulation) or against a formal model, checking that the "must happen" outcomes always happen and the "must not happen" outcomes (e.g., the same test *without* the fence, where the ordering is legitimately unconstrained and re-ordering must remain *possible*, not merely "didn't happen to occur in this run") are neither over- nor under-constrained by the implementation. Tools like `herd7`/`diy` (from the academic memory-model-testing community) are commonly adapted for RISC-V RTL validation for exactly this purpose.

### Q98. Where does formal verification add the most value for an LSU, compared to simulation?

Formal methods (model checking, symbolic simulation, or bounded formal proof) are disproportionately valuable for the LSU specifically because its bugs are dominated by **rare interleavings of independent events** (a snoop landing on exactly the cycle a store is draining and a forward is happening, Q42+Q53+Q47 all at once) rather than by simple functional miscoding — and constrained-random simulation is fundamentally bad at finding needle-in-haystack interleavings, because the state space of "which of N independent, individually-rare events happen to coincide on the same cycle" grows combinatorially and a random simulator essentially never samples the worst corners without deliberate, hard-to-write directed sequences.

High-value formal targets specifically for an LSU:
- **Store buffer forwarding correctness**: prove, for all possible ages/addresses/masks, that the forwarded value always exactly matches what an unbuffered (direct-to-memory) implementation would have produced — this is a bounded, tractable property that formal tools handle well and that simulation would need an astronomically large random suite to approximate confidence in.
- **MSHR merge/deallocate safety**: prove no MSHR is ever deallocated while a subentry is still pending, and no subentry is ever silently dropped.
- **No-deadlock properties** across the snoop/store-buffer/MSHR interaction of Q42 — formal model checking is well suited to proving the *absence* of a cyclic wait condition, which simulation can only fail to find, never confirm absent.
- **RVWMO litmus-test-style properties** (Q97) formalized as assertions rather than run empirically — turning "we ran a million random interleavings and never saw a violation" into "we proved no violation exists for this bounded configuration."

### Q99. What debug and observability hooks does a production LSU typically need?

Beyond the architectural CSRs (`mtval`, `mcause`), production designs add hardware **exclusively for post-silicon debug and performance analysis**, because LSU bugs and performance cliffs are notoriously hard to root-cause from software-visible state alone:

- **Performance counters**: L1D hit/miss counts (split by load/store), MSHR occupancy histogram, store-buffer-full stall cycles, forwarding success/failure counts, TLB hit/miss at each level, way-mispredict rate, bank-conflict count, replay count by cause (way-mispredict, bank-conflict, MSHR-full, snoop-race).
- **Trace/trigger hardware**: a small set of comparators that can be programmed (via debug-mode CSRs) to fire on a specific address, address range, or access type, used to catch a single problematic access out of billions during silicon bring-up — critical because a coherence race that occurs once in 10^9 loads is otherwise unfindable.
- **Scan/shadow access to internal state**: the ability to read out (via JTAG/debug-module access, or a dedicated internal-state-dump mode) the live contents of the store buffer, load queue, and MSHR file, since a hung or misbehaving core often has the smoking-gun evidence sitting in exactly these structures at the moment of hang.
- **Error injection hooks**: for ECC-protected arrays (Q44), the ability to deliberately flip a bit to verify the correction/detection path actually works in silicon, not just in RTL simulation — a real and commonly-required DFT (design-for-test) feature, since an ECC path that has literally never been exercised by a real error is a meaningful verification gap.

### Q100. What is the single most impactful design decision when building a new LSU, and why?

If forced to rank, the decision with the largest downstream effect on both performance and complexity is: **in-order versus out-of-order memory disambiguation** (Q12, Q65). This single choice determines whether the design needs the entire apparatus of Q49–Q68 — CAM-based load/store queues, store-set prediction, violation detection and replay, speculative-load coherence tracking — or needs none of it.

Every other decision in this document (cache associativity, MSHR count, way prediction, prefetcher sophistication) is a *tunable* that trades area/power for performance along a relatively smooth curve, and can be revisited later in a design's lifetime without touching the fundamental pipeline structure. The in-order/out-of-order memory choice, by contrast, is a **structural** decision baked into how instructions flow through the entire back end, made once at the start of a microarchitecture project, essentially never revisited within that design's lifetime, and it single-handedly determines whether the LSU is a modestly-sized, easily-verified block (in-order) or one of the largest and most bug-prone blocks in the entire core (out-of-order) — which is exactly why a huge fraction of area- and power-constrained RISC-V cores (embedded, and increasingly "efficiency-core" designs in heterogeneous server and mobile SoCs) deliberately choose in-order memory even when the rest of the pipeline is otherwise aggressively wide and deep.

---

# Part II — 25 SystemVerilog RTL modules

These are synthesizable, self-contained reference modules for the structures discussed above. Parameters are chosen for a representative RV64 core (64-bit addresses, 64 B lines, 8-way L1D) but are exposed as `parameter`s so they can be retargeted. Each module is preceded by a one-line pointer back to the question it implements. Interfaces are simplified (no full handshake/credit protocol) to keep the logic readable; real integration would add `valid/ready` on every port.

### RTL 1 — Address Generation Unit (Q13, Q18)

```systemverilog
module agu #(
  parameter int XLEN = 64
)(
  input  logic [XLEN-1:0] rs1,
  input  logic [11:0]     imm12,
  output logic [XLEN-1:0] ea,          // effective address, wraps silently
  output logic [11:0]     ea_low12     // fast path for VIPT index (Q13, Q30)
);
  logic [XLEN-1:0] imm_sext;

  assign imm_sext = {{(XLEN-12){imm12[11]}}, imm12};
  assign ea       = rs1 + imm_sext;     // natural truncation = wrap (Q18)
  assign ea_low12 = rs1[11:0] + imm12;  // early, page-offset-only adder
endmodule
```

### RTL 2 — Three-input fused AGU for macro-op fusion (Q3, Q13)

```systemverilog
module agu_fused #(
  parameter int XLEN = 64
)(
  input  logic [XLEN-1:0] rs1,
  input  logic [XLEN-1:0] rs2,
  input  logic [1:0]      shamt,       // 0,1,2,3 for sh1add/sh2add/sh3add
  input  logic [11:0]     imm12,
  output logic [XLEN-1:0] ea
);
  logic [XLEN-1:0] rs2_shifted, imm_sext;
  logic [XLEN-1:0] sum_s, sum_c;        // carry-save 3:2 compressor outputs

  assign rs2_shifted = rs2 << shamt;
  assign imm_sext     = {{(XLEN-12){imm12[11]}}, imm12};

  // 3:2 compressor: {rs1, rs2_shifted, imm_sext} -> {sum_s, sum_c<<1}
  assign sum_s = rs1 ^ rs2_shifted ^ imm_sext;
  assign sum_c = (rs1 & rs2_shifted) | (rs2_shifted & imm_sext) | (rs1 & imm_sext);

  assign ea = sum_s + (sum_c << 1);     // final carry-propagate add
endmodule
```

### RTL 3 — Alignment and priority-ordered fault checker (Q7, Q19)

```systemverilog
module align_check (
  input  logic [63:0] ea,
  input  logic [1:0]  size,            // 0=B 1=H 2=W 3=D
  input  logic         hw_misalign_ok, // Zicclsm supported for this region
  input  logic         is_atomic,      // LR/SC/AMO -> never allowed misaligned
  input  logic         is_io_region,   // PMA-derived
  output logic         misaligned,
  output logic         fault_misaligned,
  output logic         crosses_line,
  localparam int LINE = 64
);
  logic [2:0] size_mask;
  assign size_mask = (3'b000 << 0) | ((8'b1 << size) - 1'b1); // low bits mask

  assign misaligned = |(ea[2:0] & size_mask[2:0]);

  // Q8: fault if hw support absent, or atomic, or (misaligned && IO region)
  assign fault_misaligned = misaligned &&
                             (is_atomic || !hw_misalign_ok ||
                              (is_io_region));

  assign crosses_line = misaligned &&
                         ((ea[5:0] & 6'h3F) + (8'b1 << size)) > LINE;
endmodule
```

### RTL 4 — Byte-enable generator (Q14)

```systemverilog
module byte_enable_gen (
  input  logic [2:0] offset,    // ea[2:0], byte offset within 8B word
  input  logic [1:0] size,      // 0=B 1=H 2=W 3=D
  output logic [7:0] byte_en
);
  logic [7:0] base_mask;

  always_comb begin
    unique case (size)
      2'd0: base_mask = 8'b0000_0001;
      2'd1: base_mask = 8'b0000_0011;
      2'd2: base_mask = 8'b0000_1111;
      2'd3: base_mask = 8'b1111_1111;
      default: base_mask = 8'b0000_0001;
    endcase
  end

  assign byte_en = base_mask << offset;   // truncates naturally at 8 bits
endmodule
```

### RTL 5 — Store data aligner (rotate-left) (Q15)

```systemverilog
module store_aligner (
  input  logic [63:0] rs2_data,
  input  logic [2:0]  offset,          // ea[2:0]
  output logic [63:0] aligned_data
);
  logic [6:0] rot_bits;
  assign rot_bits = {offset, 3'b000};  // offset * 8

  // 64-bit left rotate by rot_bits[5:0]
  assign aligned_data = (rs2_data << rot_bits[5:0]) |
                         (rs2_data >> (7'd64 - rot_bits[5:0]));
endmodule
```

### RTL 6 — Load data aligner and sign/zero extender (Q16)

```systemverilog
module load_aligner (
  input  logic [63:0] line_data,
  input  logic [2:0]  offset,
  input  logic [1:0]  size,           // 0=B 1=H 2=W 3=D
  input  logic         is_signed,
  output logic [63:0] result
);
  logic [6:0]  rot_bits;
  logic [63:0] rotated, masked;
  logic        sign_bit;

  assign rot_bits = {offset, 3'b000};
  assign rotated  = (line_data >> rot_bits[5:0]) |
                     (line_data << (7'd64 - rot_bits[5:0]));

  always_comb begin
    unique case (size)
      2'd0: masked = {56'b0, rotated[7:0]};
      2'd1: masked = {48'b0, rotated[15:0]};
      2'd2: masked = {32'b0, rotated[31:0]};
      2'd3: masked = rotated;
      default: masked = rotated;
    endcase
  end

  always_comb begin
    unique case (size)
      2'd0: sign_bit = masked[7];
      2'd1: sign_bit = masked[15];
      2'd2: sign_bit = masked[31];
      default: sign_bit = 1'b0;
    endcase
  end

  always_comb begin
    unique case (size)
      2'd0: result = is_signed ? {{56{sign_bit}}, masked[7:0]}   : masked;
      2'd1: result = is_signed ? {{48{sign_bit}}, masked[15:0]}  : masked;
      2'd2: result = is_signed ? {{32{sign_bit}}, masked[31:0]}  : masked;
      default: result = masked;
    endcase
  end
endmodule
```

### RTL 7 — Bank index hashing to reduce bank conflicts (Q17)

```systemverilog
module bank_hash #(
  parameter int BANK_BITS = 3
)(
  input  logic [11:0] addr_index_bits,  // e.g. ea[11:0]
  output logic [BANK_BITS-1:0] bank_sel
);
  // XOR-fold higher index bits into the low bank-select bits (Q17)
  assign bank_sel = addr_index_bits[BANK_BITS-1:0]
                   ^ addr_index_bits[2*BANK_BITS-1:BANK_BITS]
                   ^ addr_index_bits[3*BANK_BITS-1:2*BANK_BITS];
endmodule
```

### RTL 8 — Store buffer entry array with age-ordered forwarding CAM (Q45–Q49)

```systemverilog
module store_buffer #(
  parameter int SB_DEPTH = 8,
  parameter int PA_WIDTH = 44
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // allocate a new store (write port)
  input  logic                  alloc_valid,
  input  logic [PA_WIDTH-1:0]   alloc_addr,
  input  logic [63:0]           alloc_data,
  input  logic [7:0]            alloc_mask,
  output logic [$clog2(SB_DEPTH)-1:0] alloc_id,
  output logic                  alloc_full,

  // commit (make an entry drain-eligible, Q64)
  input  logic                  commit_valid,
  input  logic [$clog2(SB_DEPTH)-1:0] commit_id,

  // drain (deallocate after write lands in the array, Q39, Q58)
  input  logic                  drain_ack,
  output logic [$clog2(SB_DEPTH)-1:0] drain_id,
  output logic                  drain_req,
  output logic [PA_WIDTH-1:0]   drain_addr,
  output logic [63:0]           drain_data,
  output logic [7:0]            drain_mask,

  // forwarding lookup from a younger load (Q47-Q49)
  input  logic [PA_WIDTH-1:0]   fwd_addr,
  input  logic [7:0]            fwd_mask,
  input  logic [$clog2(SB_DEPTH)-1:0] fwd_load_age, // this load's SB "watermark"
  output logic                  fwd_hit,
  output logic                  fwd_full_cover,
  output logic [63:0]           fwd_data
);
  logic                 v      [SB_DEPTH];
  logic                 committed [SB_DEPTH];
  logic [PA_WIDTH-1:0]  addr   [SB_DEPTH];
  logic [63:0]          data   [SB_DEPTH];
  logic [7:0]           mask   [SB_DEPTH];

  logic [$clog2(SB_DEPTH)-1:0] head, tail; // FIFO age order (Q49)
  logic full_r;

  assign alloc_full = full_r;
  assign alloc_id   = tail;

  // ---- allocate / commit / drain (FIFO discipline) ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head <= '0; tail <= '0; full_r <= 1'b0;
      for (int i = 0; i < SB_DEPTH; i++) v[i] <= 1'b0;
    end else begin
      if (alloc_valid && !full_r) begin
        v[tail]         <= 1'b1;
        committed[tail] <= 1'b0;
        addr[tail]      <= alloc_addr;
        data[tail]      <= alloc_data;
        mask[tail]      <= alloc_mask;
        tail            <= tail + 1'b1;
      end
      if (commit_valid) committed[commit_id] <= 1'b1;
      if (drain_ack) begin
        v[head] <= 1'b0;
        head    <= head + 1'b1;
      end
      full_r <= (tail + 1'b1 == head) && (alloc_valid || full_r) && !drain_ack;
    end
  end

  assign drain_id   = head;
  assign drain_req  = v[head] && committed[head];
  assign drain_addr = addr[head];
  assign drain_data = data[head];
  assign drain_mask = mask[head];

  // ---- forwarding CAM: search entries OLDER than fwd_load_age (Q49) ----
  logic [SB_DEPTH-1:0] cand;
  genvar gi;
  generate
    for (gi = 0; gi < SB_DEPTH; gi++) begin : g_cam
      assign cand[gi] = v[gi] &&
                        (addr[gi] == fwd_addr) &&
                        |(mask[gi] & fwd_mask) &&
                        (gi < fwd_load_age);   // age check, simplified linear order
    end
  endgenerate

  // priority-encode: youngest matching entry wins (highest index < fwd_load_age)
  integer k;
  always_comb begin
    fwd_hit        = 1'b0;
    fwd_full_cover = 1'b0;
    fwd_data       = 64'b0;
    for (k = SB_DEPTH-1; k >= 0; k--) begin
      if (cand[k] && !fwd_hit) begin
        fwd_hit        = 1'b1;
        fwd_full_cover = (mask[k] & fwd_mask) == fwd_mask;
        fwd_data       = data[k];
      end
    end
  end
endmodule
```

### RTL 9 — Store-to-load forward vs. cache-hit final select (Q47, Q55)

```systemverilog
module fwd_select (
  input  logic         cache_hit,
  input  logic [63:0]  cache_data,
  input  logic         fwd_hit,
  input  logic         fwd_full_cover,
  input  logic [63:0]  fwd_data,
  output logic         load_result_valid,
  output logic         need_stall,       // partial-cover case (Q20)
  output logic [63:0]  load_result
);
  always_comb begin
    need_stall        = 1'b0;
    load_result_valid = 1'b0;
    load_result        = 64'b0;

    if (fwd_hit && fwd_full_cover) begin
      load_result_valid = 1'b1;
      load_result        = fwd_data;
    end else if (fwd_hit && !fwd_full_cover) begin
      need_stall = 1'b1;              // Q20: byte-merge or stall; here: stall
    end else if (cache_hit) begin
      load_result_valid = 1'b1;
      load_result        = cache_data;
    end
  end
endmodule
```

### RTL 10 — Load queue entry array with snoop tracking (Q59–Q61, Q86)

```systemverilog
module load_queue #(
  parameter int LQ_DEPTH = 32,
  parameter int PA_WIDTH = 44
)(
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  alloc_valid,
  input  logic [PA_WIDTH-1:0]   alloc_addr,
  output logic [$clog2(LQ_DEPTH)-1:0] alloc_id,
  output logic                  alloc_full,

  input  logic                  exec_valid,       // load produced a value
  input  logic [$clog2(LQ_DEPTH)-1:0] exec_id,
  input  logic                  exec_speculative, // Q59

  // coherence snoop interface (Q42, Q86)
  input  logic                  snoop_valid,
  input  logic [PA_WIDTH-1:0]   snoop_addr,

  input  logic                  retire_valid,
  input  logic [$clog2(LQ_DEPTH)-1:0] retire_id,
  output logic                  retire_violation   // must squash (Q50, Q86)
);
  logic                v        [LQ_DEPTH];
  logic                executed [LQ_DEPTH];
  logic                speculative_r [LQ_DEPTH];
  logic                snooped  [LQ_DEPTH];
  logic [PA_WIDTH-1:0] addr_r   [LQ_DEPTH];
  logic [$clog2(LQ_DEPTH)-1:0] alloc_ptr;

  assign alloc_id   = alloc_ptr;
  assign alloc_full = 1'b0; // simplified: real design tracks occupancy count

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      alloc_ptr <= '0;
      for (int i = 0; i < LQ_DEPTH; i++) begin
        v[i] <= 1'b0; executed[i] <= 1'b0;
        speculative_r[i] <= 1'b0; snooped[i] <= 1'b0;
      end
    end else begin
      if (alloc_valid) begin
        v[alloc_ptr]            <= 1'b1;
        addr_r[alloc_ptr]       <= alloc_addr;
        executed[alloc_ptr]     <= 1'b0;
        snooped[alloc_ptr]      <= 1'b0;
        alloc_ptr               <= alloc_ptr + 1'b1;
      end
      if (exec_valid) begin
        executed[exec_id]      <= 1'b1;
        speculative_r[exec_id] <= exec_speculative;
      end
      // Q86: any snoop hit on an executed-but-not-retired speculative load
      if (snoop_valid) begin
        for (int i = 0; i < LQ_DEPTH; i++) begin
          if (v[i] && executed[i] && speculative_r[i] &&
              addr_r[i][PA_WIDTH-1:6] == snoop_addr[PA_WIDTH-1:6]) begin
            snooped[i] <= 1'b1;
          end
        end
      end
      if (retire_valid) v[retire_id] <= 1'b0;
    end
  end

  assign retire_violation = retire_valid && snooped[retire_id];
endmodule
```

### RTL 11 — Store-set memory dependence predictor: SSIT + LFST (Q51)

```systemverilog
module store_set_predictor #(
  parameter int SSIT_ENTRIES = 1024,
  parameter int LFST_ENTRIES = 256,
  parameter int PC_BITS      = 12,
  parameter int SSID_BITS    = 8,
  parameter int IID_BITS     = 8
)(
  input  logic clk,
  input  logic rst_n,

  // lookup at dispatch (Q51 step 4)
  input  logic [PC_BITS-1:0] lookup_pc,
  output logic               dep_valid,
  output logic [IID_BITS-1:0] dep_store_iid,

  // store dispatch: record this store as "last fetched" for its set
  input  logic                store_dispatch_valid,
  input  logic [PC_BITS-1:0]  store_pc,
  input  logic [IID_BITS-1:0] store_iid,

  // violation: merge load_pc and store_pc into one store set (Q50, Q51 step 3)
  input  logic                violation_valid,
  input  logic [PC_BITS-1:0]  violation_load_pc,
  input  logic [PC_BITS-1:0]  violation_store_pc
);
  logic [SSID_BITS-1:0] ssit [SSIT_ENTRIES];   // PC -> store-set ID
  logic                 lfst_valid [LFST_ENTRIES];
  logic [IID_BITS-1:0]  lfst_iid   [LFST_ENTRIES];

  function automatic int unsigned ssit_idx(input logic [PC_BITS-1:0] pc);
    return pc[$clog2(SSIT_ENTRIES)-1:0];
  endfunction

  logic [SSID_BITS-1:0] lookup_ssid, store_ssid;
  assign lookup_ssid = ssit[ssit_idx(lookup_pc)];
  assign store_ssid  = ssit[ssit_idx(store_pc)];

  assign dep_valid     = lfst_valid[lookup_ssid[$clog2(LFST_ENTRIES)-1:0]];
  assign dep_store_iid = lfst_iid[lookup_ssid[$clog2(LFST_ENTRIES)-1:0]];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < SSIT_ENTRIES; i++) ssit[i] <= '0;
      for (int i = 0; i < LFST_ENTRIES; i++) lfst_valid[i] <= 1'b0;
    end else begin
      if (store_dispatch_valid)
        lfst_iid[store_ssid[$clog2(LFST_ENTRIES)-1:0]]   <= store_iid;
      if (store_dispatch_valid)
        lfst_valid[store_ssid[$clog2(LFST_ENTRIES)-1:0]] <= 1'b1;

      if (violation_valid) begin
        // merge: assign both PCs the SAME store-set id (use the store's)
        automatic logic [SSID_BITS-1:0] merged = ssit[ssit_idx(violation_store_pc)];
        ssit[ssit_idx(violation_load_pc)]  <= merged;
        ssit[ssit_idx(violation_store_pc)] <= merged;
      end
    end
  end
endmodule
```

### RTL 12 — Way predictor using µtags (Q35)

```systemverilog
module way_predictor #(
  parameter int WAYS      = 8,
  parameter int SETS      = 64,
  parameter int UTAG_BITS = 8
)(
  input  logic                  clk,
  input  logic [$clog2(SETS)-1:0] set_idx,
  input  logic [UTAG_BITS-1:0]  lookup_utag,

  input  logic                  fill_valid,
  input  logic [$clog2(SETS)-1:0] fill_set,
  input  logic [$clog2(WAYS)-1:0] fill_way,
  input  logic [UTAG_BITS-1:0]  fill_utag,

  output logic [$clog2(WAYS)-1:0] pred_way,
  output logic                  pred_valid
);
  logic [UTAG_BITS-1:0] utag_arr [SETS][WAYS];
  logic                 utag_v   [SETS][WAYS];
  logic [WAYS-1:0]      match;

  genvar w;
  generate
    for (w = 0; w < WAYS; w++) begin : g_match
      assign match[w] = utag_v[set_idx][w] && (utag_arr[set_idx][w] == lookup_utag);
    end
  endgenerate

  // priority encode first match (should be at most one in practice)
  integer j;
  always_comb begin
    pred_valid = 1'b0;
    pred_way   = '0;
    for (j = 0; j < WAYS; j++) begin
      if (match[j] && !pred_valid) begin
        pred_valid = 1'b1;
        pred_way   = j[$clog2(WAYS)-1:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (fill_valid) begin
      utag_arr[fill_set][fill_way] <= fill_utag;
      utag_v[fill_set][fill_way]   <= 1'b1;
    end
  end
endmodule
```

### RTL 13 — Tree pseudo-LRU replacement (Q36)

```systemverilog
module plru_tree #(
  parameter int WAYS = 8   // must be a power of two
)(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     access_valid,
  input  logic [$clog2(WAYS)-1:0]  access_way,
  output logic [$clog2(WAYS)-1:0]  victim_way
);
  localparam int NBITS = WAYS - 1;
  logic [NBITS-1:0] tree_bits;

  // Walk the tree to find the victim: bit index starts at 0 (root)
  function automatic logic [$clog2(WAYS)-1:0] find_victim(input logic [NBITS-1:0] bits);
    int unsigned idx;
    logic [$clog2(WAYS)-1:0] way;
    idx = 0;
    way = '0;
    for (int lvl = 0; lvl < $clog2(WAYS); lvl++) begin
      way = {way[$clog2(WAYS)-2:0], bits[idx]};
      idx = bits[idx] ? (2*idx + 2) : (2*idx + 1);
    end
    return way;
  endfunction

  assign victim_way = find_victim(tree_bits);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tree_bits <= '0;
    end else if (access_valid) begin
      // update bits along the path to access_way, each set to point AWAY from it
      int unsigned idx;
      idx = 0;
      for (int lvl = $clog2(WAYS)-1; lvl >= 0; lvl--) begin
        automatic logic dir = access_way[lvl];
        tree_bits[idx] <= ~dir;
        idx = dir ? (2*idx + 2) : (2*idx + 1);
      end
    end
  end
endmodule
```

### RTL 14 — Write-combining buffer (Q38)

```systemverilog
module write_combine_buffer #(
  parameter int WCB_DEPTH = 4,
  parameter int PA_WIDTH  = 44
)(
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 store_valid,
  input  logic [PA_WIDTH-1:0]  store_line_addr,   // line-aligned
  input  logic [63:0]          store_data,        // pre-aligned 8B chunk
  input  logic [2:0]           store_chunk_idx,   // which 8B chunk of the line
  input  logic [7:0]           store_mask,

  output logic                 evict_req,
  output logic [PA_WIDTH-1:0]  evict_addr,
  output logic [63:0]          evict_data [8],
  output logic [63:0]          evict_mask_full     // all-ones per chunk -> no RFO needed
);
  logic [PA_WIDTH-1:0] waddr   [WCB_DEPTH];
  logic                wv      [WCB_DEPTH];
  logic [63:0]         wdata   [WCB_DEPTH][8];
  logic [7:0]          wmask   [WCB_DEPTH][8];
  logic [2:0]          lru_ptr;

  logic [WCB_DEPTH-1:0] hit;
  genvar gi;
  generate
    for (gi = 0; gi < WCB_DEPTH; gi++) begin : g_hit
      assign hit[gi] = wv[gi] && (waddr[gi] == store_line_addr);
    end
  endgenerate

  integer hit_idx;
  always_comb begin
    hit_idx = -1;
    for (int i = 0; i < WCB_DEPTH; i++) if (hit[i]) hit_idx = i;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < WCB_DEPTH; i++) wv[i] <= 1'b0;
      lru_ptr <= '0;
    end else if (store_valid) begin
      if (hit_idx != -1) begin
        wdata[hit_idx][store_chunk_idx] <= store_data;
        wmask[hit_idx][store_chunk_idx] <= wmask[hit_idx][store_chunk_idx] | store_mask;
      end else begin
        // allocate into round-robin victim slot (Q38)
        waddr[lru_ptr]                        <= store_line_addr;
        wv[lru_ptr]                           <= 1'b1;
        for (int c = 0; c < 8; c++) wmask[lru_ptr][c] <= 8'b0;
        wdata[lru_ptr][store_chunk_idx]       <= store_data;
        wmask[lru_ptr][store_chunk_idx]       <= store_mask;
        lru_ptr                               <= lru_ptr + 1'b1;
      end
    end
  end

  // simplistic eviction: entry 0 exposed when fully covered (real design arbitrates)
  logic full_cover;
  always_comb begin
    full_cover = 1'b1;
    for (int c = 0; c < 8; c++) full_cover &= (wmask[0][c] == 8'hFF);
    evict_req  = wv[0] && full_cover;
    evict_addr = waddr[0];
    for (int c = 0; c < 8; c++) evict_data[c] = wdata[0][c];
    evict_mask_full = {8{full_cover}};
  end
endmodule
```

### RTL 15 — MSHR file with primary/secondary miss merging (Q70–Q73)

```systemverilog
module mshr_file #(
  parameter int MSHR_DEPTH = 8,
  parameter int SUBENTRIES = 4,
  parameter int PA_WIDTH   = 44,
  parameter int TAG_WIDTH  = 8    // destination tag (LQ index etc.)
)(
  input  logic  clk,
  input  logic  rst_n,

  input  logic                 req_valid,
  input  logic [PA_WIDTH-1:0]  req_line_addr,
  input  logic [2:0]           req_offset,
  input  logic [TAG_WIDTH-1:0] req_dest_tag,
  output logic                 req_is_primary,   // Q73
  output logic                 req_accepted,
  output logic [$clog2(MSHR_DEPTH)-1:0] req_mshr_id,

  input  logic                 fill_valid,
  input  logic [$clog2(MSHR_DEPTH)-1:0] fill_mshr_id,
  output logic                 fill_dealloc
);
  logic                 v       [MSHR_DEPTH];
  logic [PA_WIDTH-1:0]  addr    [MSHR_DEPTH];
  logic [$clog2(SUBENTRIES)-1:0] sub_cnt [MSHR_DEPTH];
  logic [2:0]           sub_off [MSHR_DEPTH][SUBENTRIES];
  logic [TAG_WIDTH-1:0] sub_tag [MSHR_DEPTH][SUBENTRIES];

  logic [MSHR_DEPTH-1:0] addr_match;
  logic [MSHR_DEPTH-1:0] free_slot;
  genvar gi;
  generate
    for (gi = 0; gi < MSHR_DEPTH; gi++) begin : g_m
      assign addr_match[gi] = v[gi] && (addr[gi] == req_line_addr);
      assign free_slot[gi]  = !v[gi];
    end
  endgenerate

  integer match_idx, alloc_idx;
  always_comb begin
    match_idx = -1;
    alloc_idx = -1;
    for (int i = 0; i < MSHR_DEPTH; i++) begin
      if (addr_match[i] && match_idx == -1) match_idx = i;
      if (free_slot[i]  && alloc_idx == -1) alloc_idx = i;
    end
  end

  assign req_is_primary = (match_idx == -1);
  assign req_accepted   = req_valid &&
                           ((match_idx != -1 && sub_cnt[match_idx] < SUBENTRIES) ||
                            (match_idx == -1 && alloc_idx != -1));
  assign req_mshr_id    = req_is_primary ? alloc_idx[$clog2(MSHR_DEPTH)-1:0]
                                          : match_idx[$clog2(MSHR_DEPTH)-1:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MSHR_DEPTH; i++) begin v[i] <= 1'b0; sub_cnt[i] <= '0; end
    end else begin
      if (req_valid && req_accepted) begin
        if (req_is_primary) begin
          v[alloc_idx]                    <= 1'b1;
          addr[alloc_idx]                 <= req_line_addr;
          sub_cnt[alloc_idx]              <= 3'd1;
          sub_off[alloc_idx][0]           <= req_offset;
          sub_tag[alloc_idx][0]           <= req_dest_tag;
        end else begin
          sub_off[match_idx][sub_cnt[match_idx]] <= req_offset;
          sub_tag[match_idx][sub_cnt[match_idx]] <= req_dest_tag;
          sub_cnt[match_idx]                     <= sub_cnt[match_idx] + 1'b1;
        end
      end
      if (fill_valid) v[fill_mshr_id] <= 1'b0;   // Q71: dealloc after servicing all subentries
    end
  end

  assign fill_dealloc = fill_valid;
endmodule
```

### RTL 16 — Short-latency replay queue (Q76)

```systemverilog
module replay_queue #(
  parameter int RQ_DEPTH = 4,
  parameter int TAG_WIDTH = 8
)(
  input  logic clk,
  input  logic rst_n,

  input  logic                  push_valid,
  input  logic [TAG_WIDTH-1:0]  push_tag,
  input  logic [1:0]            push_reason,   // 0=way-mispred 1=bank-conflict 2=snoop-race

  output logic                  pop_valid,
  output logic [TAG_WIDTH-1:0]  pop_tag,
  input  logic                  pop_ack
);
  logic [TAG_WIDTH-1:0] tags [RQ_DEPTH];
  logic [1:0]            reason [RQ_DEPTH];
  logic                  v      [RQ_DEPTH];
  logic [$clog2(RQ_DEPTH)-1:0] head, tail;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head <= '0; tail <= '0;
      for (int i = 0; i < RQ_DEPTH; i++) v[i] <= 1'b0;
    end else begin
      if (push_valid && !v[tail]) begin
        tags[tail]   <= push_tag;
        reason[tail] <= push_reason;
        v[tail]      <= 1'b1;
        tail         <= tail + 1'b1;
      end
      if (pop_ack && v[head]) begin
        v[head] <= 1'b0;
        head    <= head + 1'b1;
      end
    end
  end

  assign pop_valid = v[head];
  assign pop_tag   = tags[head];
endmodule
```

### RTL 17 — Fully-associative DTLB (Q23, Q30)

```systemverilog
module dtlb #(
  parameter int ENTRIES  = 32,
  parameter int VPN_BITS = 27,   // Sv39: VPN[2:0] concatenated, simplified
  parameter int PPN_BITS = 44,
  parameter int ASID_BITS = 16
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [VPN_BITS-1:0]  lookup_vpn,
  input  logic [ASID_BITS-1:0] lookup_asid,
  output logic                 hit,
  output logic [PPN_BITS-1:0]  hit_ppn,
  output logic [2:0]           hit_perm,   // {X,W,R}
  output logic                 hit_global,

  input  logic                  fill_valid,
  input  logic [VPN_BITS-1:0]   fill_vpn,
  input  logic [ASID_BITS-1:0]  fill_asid,
  input  logic [PPN_BITS-1:0]   fill_ppn,
  input  logic [2:0]            fill_perm,
  input  logic                  fill_global,

  input  logic                  flush_all,        // sfence.vma (no args)
  input  logic                  flush_asid_valid,
  input  logic [ASID_BITS-1:0]  flush_asid,
  input  logic                  flush_addr_valid,
  input  logic [VPN_BITS-1:0]   flush_vpn
);
  logic                 v      [ENTRIES];
  logic [VPN_BITS-1:0]  vpn    [ENTRIES];
  logic [ASID_BITS-1:0] asid   [ENTRIES];
  logic [PPN_BITS-1:0]  ppn    [ENTRIES];
  logic [2:0]           perm   [ENTRIES];
  logic                 gbl    [ENTRIES];
  logic [$clog2(ENTRIES)-1:0] rr_ptr;

  logic [ENTRIES-1:0] match;
  genvar gi;
  generate
    for (gi = 0; gi < ENTRIES; gi++) begin : g_cam
      assign match[gi] = v[gi] && (vpn[gi] == lookup_vpn) &&
                          (gbl[gi] || (asid[gi] == lookup_asid));
    end
  endgenerate

  integer m;
  always_comb begin
    hit = 1'b0; hit_ppn = '0; hit_perm = '0; hit_global = 1'b0;
    for (m = 0; m < ENTRIES; m++) begin
      if (match[m] && !hit) begin
        hit = 1'b1; hit_ppn = ppn[m]; hit_perm = perm[m]; hit_global = gbl[m];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < ENTRIES; i++) v[i] <= 1'b0;
      rr_ptr <= '0;
    end else begin
      // Q27: sfence.vma handling, respecting the G bit
      if (flush_all) begin
        for (int i = 0; i < ENTRIES; i++) v[i] <= 1'b0;
      end else begin
        if (flush_asid_valid) begin
          for (int i = 0; i < ENTRIES; i++)
            if (!gbl[i] && asid[i] == flush_asid) v[i] <= 1'b0;
        end
        if (flush_addr_valid) begin
          for (int i = 0; i < ENTRIES; i++)
            if (!gbl[i] && vpn[i] == flush_vpn) v[i] <= 1'b0;
        end
      end

      if (fill_valid) begin
        v[rr_ptr]    <= 1'b1;
        vpn[rr_ptr]  <= fill_vpn;
        asid[rr_ptr] <= fill_asid;
        ppn[rr_ptr]  <= fill_ppn;
        perm[rr_ptr] <= fill_perm;
        gbl[rr_ptr]  <= fill_global;
        rr_ptr       <= rr_ptr + 1'b1;
      end
    end
  end
endmodule
```

### RTL 18 — Set-associative L2 TLB (Q23)

```systemverilog
module l2_tlb #(
  parameter int SETS    = 128,
  parameter int WAYS    = 8,
  parameter int TAG_BITS = 20,
  parameter int PPN_BITS = 44
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [$clog2(SETS)-1:0] lookup_set,
  input  logic [TAG_BITS-1:0]     lookup_tag,
  output logic                    hit,
  output logic [PPN_BITS-1:0]     hit_ppn,

  input  logic                    fill_valid,
  input  logic [$clog2(SETS)-1:0] fill_set,
  input  logic [TAG_BITS-1:0]     fill_tag,
  input  logic [PPN_BITS-1:0]     fill_ppn,
  input  logic [$clog2(WAYS)-1:0] fill_way        // from a PLRU victim selector
);
  logic                v    [SETS][WAYS];
  logic [TAG_BITS-1:0] tag  [SETS][WAYS];
  logic [PPN_BITS-1:0] ppn  [SETS][WAYS];

  logic [WAYS-1:0] match;
  genvar gw;
  generate
    for (gw = 0; gw < WAYS; gw++) begin : g_way
      assign match[gw] = v[lookup_set][gw] && (tag[lookup_set][gw] == lookup_tag);
    end
  endgenerate

  integer w;
  always_comb begin
    hit = 1'b0; hit_ppn = '0;
    for (w = 0; w < WAYS; w++)
      if (match[w] && !hit) begin hit = 1'b1; hit_ppn = ppn[lookup_set][w]; end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < SETS; s++)
        for (int wy = 0; wy < WAYS; wy++) v[s][wy] <= 1'b0;
    end else if (fill_valid) begin
      v[fill_set][fill_way]   <= 1'b1;
      tag[fill_set][fill_way] <= fill_tag;
      ppn[fill_set][fill_way] <= fill_ppn;
    end
  end
endmodule
```

### RTL 19 — PMP checker with NAPOT/TOR decoding (Q29)

```systemverilog
module pmp_checker #(
  parameter int NUM_PMP = 16,
  parameter int PA_WIDTH = 44
)(
  input  logic [PA_WIDTH-1:0] phys_addr,
  input  logic [1:0]          access_type,       // 0=R 1=W 2=X
  input  logic [1:0]          priv_mode,         // 0=U 1=S 2=M
  input  logic [PA_WIDTH-1:0] pmpaddr [NUM_PMP],
  input  logic [7:0]          pmpcfg  [NUM_PMP], // {L,0,A[1:0],X,W,R}
  output logic                access_ok
);
  logic [NUM_PMP-1:0] in_range;
  logic [NUM_PMP-1:0] perm_ok;

  genvar gi;
  generate
    for (gi = 0; gi < NUM_PMP; gi++) begin : g_pmp
      logic [PA_WIDTH-1:0] base, mask, top;
      logic [1:0] amode;
      assign amode = pmpcfg[gi][4:3];

      // NAPOT decode: find trailing 1s to build a mask (Q29)
      logic [PA_WIDTH-1:0] napot_mask;
      always_comb begin
        napot_mask = '0;
        for (int b = 0; b < PA_WIDTH; b++)
          if (pmpaddr[gi][b] == 1'b1) napot_mask[b] = 1'b1;
          else break;
      end

      always_comb begin
        unique case (amode)
          2'd2: in_range[gi] = (phys_addr == pmpaddr[gi]);                 // NA4
          2'd3: in_range[gi] = ((phys_addr & ~napot_mask) ==
                                 (pmpaddr[gi] & ~napot_mask));             // NAPOT
          2'd1: in_range[gi] = (gi == 0) ?
                                 (phys_addr < pmpaddr[gi]) :
                                 (phys_addr >= pmpaddr[gi-1] && phys_addr < pmpaddr[gi]); // TOR
          default: in_range[gi] = 1'b0;                                    // OFF
        endcase
      end

      assign perm_ok[gi] = (access_type == 2'd0 && pmpcfg[gi][0]) ||
                            (access_type == 2'd1 && pmpcfg[gi][1]) ||
                            (access_type == 2'd2 && pmpcfg[gi][2]);
    end
  endgenerate

  // lowest-numbered matching entry wins (spec-mandated priority)
  integer p;
  always_comb begin
    access_ok = (priv_mode == 2'd2); // M-mode default-allows if no PMP matches
    for (p = NUM_PMP-1; p >= 0; p--) begin
      if (in_range[p]) begin
        // locked entries (cfg[7]) apply to M-mode too
        access_ok = perm_ok[p] || (priv_mode == 2'd2 && !pmpcfg[p][7]);
      end
    end
  end
endmodule
```

### RTL 20 — PMA region attribute lookup (Q28)

```systemverilog
module pma_checker #(
  parameter int NUM_REGIONS = 8,
  parameter int PA_WIDTH    = 44
)(
  input  logic [PA_WIDTH-1:0] phys_addr,
  input  logic [PA_WIDTH-1:0] region_base [NUM_REGIONS],
  input  logic [PA_WIDTH-1:0] region_size [NUM_REGIONS], // power-of-two
  input  logic                region_cacheable [NUM_REGIONS],
  input  logic                region_idempotent [NUM_REGIONS],
  input  logic                region_is_io      [NUM_REGIONS],
  input  logic                region_misalign_ok[NUM_REGIONS],
  output logic                cacheable,
  output logic                idempotent,
  output logic                is_io,
  output logic                misalign_ok,
  output logic                addr_mapped
);
  logic [NUM_REGIONS-1:0] sel;
  genvar gi;
  generate
    for (gi = 0; gi < NUM_REGIONS; gi++) begin : g_region
      assign sel[gi] = (phys_addr >= region_base[gi]) &&
                        (phys_addr <  region_base[gi] + region_size[gi]);
    end
  endgenerate

  integer s;
  always_comb begin
    addr_mapped = 1'b0;
    cacheable = 1'b0; idempotent = 1'b0; is_io = 1'b0; misalign_ok = 1'b0;
    for (s = 0; s < NUM_REGIONS; s++) begin
      if (sel[s] && !addr_mapped) begin
        addr_mapped  = 1'b1;
        cacheable    = region_cacheable[s];
        idempotent   = region_idempotent[s];
        is_io        = region_is_io[s];
        misalign_ok  = region_misalign_ok[s];
      end
    end
  end
endmodule
```

### RTL 21 — LR/SC reservation station (Q79–Q81)

```systemverilog
module lrsc_reservation #(
  parameter int PA_WIDTH = 44,
  parameter int NHARTS   = 4
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [$clog2(NHARTS)-1:0] hart_id,

  input  logic                 lr_valid,
  input  logic [PA_WIDTH-1:0]  lr_line_addr,

  input  logic                 sc_valid,
  input  logic [PA_WIDTH-1:0]  sc_line_addr,
  output logic                 sc_success,     // Q79: SC succeeds iff reservation intact

  // any coherence-visible write to a line, from any hart (Q81)
  input  logic                 snoop_inval_valid,
  input  logic [PA_WIDTH-1:0]  snoop_inval_addr
);
  logic                res_valid [NHARTS];
  logic [PA_WIDTH-1:0] res_addr  [NHARTS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int h = 0; h < NHARTS; h++) res_valid[h] <= 1'b0;
    end else begin
      if (lr_valid) begin
        res_valid[hart_id] <= 1'b1;
        res_addr[hart_id]  <= lr_line_addr;
      end

      if (sc_valid && sc_success) res_valid[hart_id] <= 1'b0; // consumed on success

      // Q81: ANY write to the reserved line clears the reservation, including
      // this hart's own stores and other harts' coherence invalidates
      if (snoop_inval_valid) begin
        for (int h = 0; h < NHARTS; h++)
          if (res_valid[h] && res_addr[h] == snoop_inval_addr) res_valid[h] <= 1'b0;
      end
    end
  end

  assign sc_success = sc_valid && res_valid[hart_id] &&
                       (res_addr[hart_id] == sc_line_addr);
endmodule
```

### RTL 22 — AMO ALU performed at the cache controller (Q82)

```systemverilog
module amo_alu (
  input  logic [3:0]  amo_op,     // ADD SWAP AND OR XOR MAX MIN MAXU MINU
  input  logic [63:0] mem_old,
  input  logic [63:0] operand,
  output logic [63:0] mem_new
);
  localparam AMOADD=4'd0, AMOSWAP=4'd1, AMOAND=4'd2, AMOOR=4'd3, AMOXOR=4'd4,
             AMOMAX=4'd5, AMOMIN=4'd6, AMOMAXU=4'd7, AMOMINU=4'd8;

  always_comb begin
    unique case (amo_op)
      AMOADD:  mem_new = mem_old + operand;
      AMOSWAP: mem_new = operand;
      AMOAND:  mem_new = mem_old & operand;
      AMOOR:   mem_new = mem_old | operand;
      AMOXOR:  mem_new = mem_old ^ operand;
      AMOMAX:  mem_new = ($signed(mem_old) > $signed(operand)) ? mem_old : operand;
      AMOMIN:  mem_new = ($signed(mem_old) < $signed(operand)) ? mem_old : operand;
      AMOMAXU: mem_new = (mem_old > operand) ? mem_old : operand;
      AMOMINU: mem_new = (mem_old < operand) ? mem_old : operand;
      default: mem_new = mem_old;
    endcase
  end
  // mem_old is returned to the destination register unmodified by the
  // caller (Q82) -- this module only produces the value to write back.
endmodule
```

### RTL 23 — Fence controller tracking drain/retire completion (Q85, Q88)

```systemverilog
module fence_controller (
  input  logic clk,
  input  logic rst_n,

  input  logic fence_valid,
  input  logic fence_pred_r, fence_pred_w,   // predecessor set: read/write
  input  logic fence_succ_r, fence_succ_w,   // successor set: read/write

  input  logic store_buffer_empty,           // Q45/Q53: no pending stores
  input  logic wcb_flush_done,               // Q38/Q88: write-combine buffer flushed
  input  logic all_older_loads_retired,      // Q60

  output logic fence_stall,                  // hold younger dispatch
  output logic fence_done
);
  typedef enum logic [1:0] {IDLE, DRAINING, DONE} state_t;
  state_t state, next_state;

  logic needs_drain;
  assign needs_drain = fence_pred_w; // a write predecessor requires SB+WCB drain

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

  always_comb begin
    next_state = state;
    unique case (state)
      IDLE:      if (fence_valid) next_state = needs_drain ? DRAINING : DONE;
      DRAINING:  if (store_buffer_empty && wcb_flush_done &&
                      (!fence_pred_r || all_older_loads_retired))
                   next_state = DONE;
      DONE:      next_state = IDLE;
      default:   next_state = IDLE;
    endcase
  end

  assign fence_stall = (state == DRAINING) || (state == IDLE && fence_valid && needs_drain);
  assign fence_done  = (state == DONE);
endmodule
```

### RTL 24 — Adaptive stride prefetcher (Q91, Q93)

```systemverilog
module stride_prefetcher #(
  parameter int TABLE_ENTRIES = 64,
  parameter int PC_BITS       = 12,
  parameter int PA_WIDTH      = 44,
  parameter int CONF_BITS     = 2
)(
  input  logic clk,
  input  logic rst_n,

  input  logic                 access_valid,
  input  logic [PC_BITS-1:0]   access_pc,
  input  logic [PA_WIDTH-1:0]  access_addr,

  output logic                 pf_valid,
  output logic [PA_WIDTH-1:0]  pf_addr,

  input  logic                 pf_was_useful    // feedback for accuracy tracking (Q93)
);
  logic [PA_WIDTH-1:0] last_addr [TABLE_ENTRIES];
  logic signed [15:0]  stride    [TABLE_ENTRIES];
  logic [CONF_BITS-1:0] conf     [TABLE_ENTRIES];
  logic [$clog2(TABLE_ENTRIES)-1:0] degree;   // adaptive degree (Q93)

  function automatic int unsigned idx(input logic [PC_BITS-1:0] pc);
    return pc[$clog2(TABLE_ENTRIES)-1:0];
  endfunction

  logic signed [15:0] new_stride;
  logic [$clog2(TABLE_ENTRIES)-1:0] cur;
  assign cur = idx(access_pc);
  assign new_stride = access_addr - last_addr[cur];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TABLE_ENTRIES; i++) begin
        last_addr[i] <= '0; stride[i] <= '0; conf[i] <= '0;
      end
      degree <= 1;
    end else if (access_valid) begin
      if (new_stride == stride[cur] && new_stride != 0) begin
        if (conf[cur] != {CONF_BITS{1'b1}}) conf[cur] <= conf[cur] + 1'b1;
      end else begin
        conf[cur]   <= '0;
        stride[cur] <= new_stride;
      end
      last_addr[cur] <= access_addr;

      // Q93: adapt degree based on feedback
      if (pf_was_useful && degree < TABLE_ENTRIES-1) degree <= degree + 1'b1;
      else if (!pf_was_useful && degree > 1)          degree <= degree - 1'b1;
    end
  end

  // issue a prefetch only once confidence has saturated (Q91)
  assign pf_valid = access_valid && (conf[cur] == {CONF_BITS{1'b1}});
  assign pf_addr  = access_addr + (stride[cur] * $signed({1'b0, degree}));
endmodule
```

### RTL 25 — Load-use hazard interlock for an in-order pipeline (Q77)

```systemverilog
module load_use_interlock (
  input  logic        ex_mem_is_load,
  input  logic [4:0]  ex_mem_rd,
  input  logic         ex_mem_rd_valid,   // rd != x0

  input  logic [4:0]  id_rs1,
  input  logic [4:0]  id_rs2,
  input  logic         id_uses_rs1,
  input  logic         id_uses_rs2,

  output logic         stall_id,
  output logic         bubble_ex          // insert a NOP into EX
);
  logic rs1_hazard, rs2_hazard;

  assign rs1_hazard = ex_mem_is_load && ex_mem_rd_valid && id_uses_rs1 &&
                       (ex_mem_rd == id_rs1);
  assign rs2_hazard = ex_mem_is_load && ex_mem_rd_valid && id_uses_rs2 &&
                       (ex_mem_rd == id_rs2);

  assign stall_id  = rs1_hazard || rs2_hazard;   // Q77: hold ID for one cycle
  assign bubble_ex  = stall_id;                   // inject a bubble downstream
endmodule
```

---

*End of reference. All 100 questions and 25 RTL modules above are cross-referenced by question number (Q1–Q100) so the prose and the hardware can be read together.*