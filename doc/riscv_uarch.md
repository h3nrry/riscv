# RISC-V Microarchitecture Specification

Two cores, specified to the level you can start writing RTL from.

| | **Core-S** (in-order) | **Core-O** (out-of-order) |
|---|---|---|
| ISA | RV32IMC_Zicsr_Zifencei | RV64GC |
| Privilege | M, U | M, S, U + Sv39 |
| Pipeline depth | 5 | 12 |
| Width | 1 | 4 |
| Target IPC | 0.75 | 2.0 |
| Target freq | 100 MHz Artix-7 / 1 GHz 28nm | 50 MHz VU9P / 2 GHz 7nm |
| LUT budget (FPGA) | ~6 K | ~250 K |
| Reference point | Rocket, CVA6 | BOOM, XiangShan Nanhu |

Assumptions stated once: byte-addressed little-endian, physically-tagged caches, single hart, no vector unit. Where RV32 and RV64 differ, `XLEN` is used.

---

# PART I — CORE-S: IN-ORDER 5-STAGE

## 1. Stage IF — Instruction Fetch

### Datapath contents

| Block | Spec |
|---|---|
| PC register | `XLEN` bits, reset to `RESET_VECTOR` (0x8000_0000) |
| Next-PC adder | `pc + 2` and `pc + 4`, select on `instr[1:0] == 2'b11` |
| BTB | 64 entries, direct-mapped, indexed `pc[7:2]` |
| I-cache port | req: `{valid, addr}` · resp: `{valid, data[31:0], fault}` |

### BTB entry format (combined target + direction)

| Field | Bits | Notes |
|---|---|---|
| `valid` | 1 | cleared on reset and `fence.i` |
| `tag` | XLEN-8 | `pc[XLEN-1:8]` |
| `target` | XLEN | |
| `ctr` | 2 | bimodal saturating counter |
| `is_ret` | 1 | steer to RAS instead of `target` |

Predict taken when `valid && tag match && ctr[1]`.

### RAS

8 entries, `XLEN` wide, with a wrap-around pointer (overflow silently discards the oldest — do **not** stall). Push/pop decided at ID from the RISC-V `JALR` hint convention:

| `rd` | `rs1` | Action |
|---|---|---|
| `x1`/`x5` | not `x1`/`x5` | push |
| not `x1`/`x5` | `x1`/`x5` | pop |
| `x1`/`x5` | `x1`/`x5`, `rd ≠ rs1` | pop then push |
| `x1`/`x5` | `rd == rs1` | push only |

Because the RAS is driven from ID but consumed in IF, a return prediction lands one cycle late. Accept the 1-cycle bubble on returns, or duplicate the decode of `JALR` bits in IF (cheap — only needs `instr[11:7]` and `instr[19:15]`).

### IF/ID pipeline register

```
typedef struct {
  logic              valid;
  logic [XLEN-1:0]   pc;
  logic [31:0]       instr;        // RVC already zero-extended
  logic              is_rvc;
  logic              pred_taken;
  logic [XLEN-1:0]   pred_target;
  logic              page_fault;
  logic              access_fault;
} if_id_t;
```

---

## 2. Stage ID — Decode

### Datapath contents

- **RVC decompressor** — pure combinational, expands 16-bit to the equivalent 32-bit encoding. Illegal RVC encodings (e.g. `c.addi4spn` with `nzuimm == 0`) raise illegal-instruction.
- **Main decoder** — produces the control bundle below.
- **Register file** — 32 × XLEN, 2R/1W. Read `rs1`/`rs2` here. Handle the WB→ID same-cycle case either by writing on the negative edge or with an explicit bypass mux; the bypass is preferred for FPGA BRAM inference.
- **Immediate generator** — 5 formats. RISC-V places the sign bit at `instr[31]` for every format, so this is a small mux, not a barrel shifter.
- **Hazard unit** (see §5).

### Control bundle

| Field | Bits | Values |
|---|---|---|
| `alu_op` | 4 | ADD SUB SLL SLT SLTU XOR SRL SRA OR AND |
| `alu_src_a` | 2 | RS1, PC, ZERO |
| `alu_src_b` | 2 | RS2, IMM, CONST4 |
| `reg_write` | 1 | |
| `wb_sel` | 2 | ALU, MEM, PC_PLUS, CSR |
| `mem_read` / `mem_write` | 2 | |
| `mem_size` | 2 | B, H, W (+ D on RV64 only) |
| `mem_signed` | 1 | for LB/LH/LW vs LBU/LHU/LWU |
| `branch_type` | 3 | NONE, EQ, NE, LT, GE, LTU, GEU |
| `is_jal` / `is_jalr` | 2 | |
| `csr_op` | 2 | NONE, RW, RS, RC |
| `csr_imm` | 1 | CSRRWI/CSRRSI/CSRRCI |
| `is_mul` / `is_div` | 2 | M extension |
| `is_fence` / `is_fencei` | 2 | |
| `sys_op` | 3 | NONE, ECALL, EBREAK, MRET, WFI |
| `illegal` | 1 | |

Total ~30 bits, carried down every pipeline register (progressively narrowing — MEM doesn't need `alu_op`).

---

## 3. Stage EX — Execute

### Contents

- **ALU** — 10 operations. On FPGA the shifter dominates; use a single bidirectional barrel shifter with pre/post bit-reverse rather than two shifters.
- **Branch comparator** — separate from the ALU so that `SLT` and a branch don't contend. Six conditions from one subtractor plus sign/zero logic.
- **Branch target adder** — `pc + imm_b` for branches/JAL, `(rs1 + imm_i) & ~1` for JALR. Note the LSB clear is *required* by the spec.
- **MUL/DIV** — see below.
- **Forwarding muxes** — 3:1 on each ALU input.

### Mispredict detection

```
actual_taken  = (branch_type != NONE && cond_met) || is_jal || is_jalr;
actual_target = actual_taken ? branch_target : pc + (is_rvc ? 2 : 4);

mispredict = (actual_taken  != id_ex.pred_taken) ||
             (actual_taken  && actual_target != id_ex.pred_target);
```

On `mispredict`: assert `flush_if_id`, redirect PC to `actual_target`, and update the BTB. **Penalty = 2 cycles.**

### M extension

| Op | Implementation | Latency |
|---|---|---|
| MUL/MULH/MULHSU/MULHU | DSP48 array, pipelined | 2–3 cycles, stall EX |
| DIV/DIVU/REM/REMU | radix-2 restoring, iterative | XLEN+2 cycles, stall EX |

Both stall the whole pipeline. That's acceptable in a small in-order core — divides are rare enough that an early-out for small operands is a better investment than pipelining.

**Divide-by-zero is not a trap in RISC-V.** `DIV` by zero returns all-ones, `REM` returns the dividend. Signed overflow (`MIN_INT / -1`) returns `MIN_INT` for DIV and 0 for REM. Hardcode these cases.

---

## 4. Stage MEM — Memory

- D-cache request, address = ALU result
- **Alignment check** → `load_addr_misaligned` / `store_addr_misaligned` trap (unless you implement `Zicclsm`)
- Store byte-enable generation from `mem_size` and `addr[2:0]`
- Load data rotate + sign/zero extend
- CSR file read/write happens here (it needs to be after the point where the instruction is known non-speculative in an in-order core; putting it in EX means a trapping instruction behind it could have already modified state)

**Blocking cache.** A miss asserts `stall_all` and freezes every pipeline register. This is the single largest IPC loss in Core-S and is the correct trade — a non-blocking cache without an OoO back-end has almost nothing to overlap with.

---

## 5. Stage WB — Writeback

- Writeback mux → register file write port
- `x0` write suppression (`reg_write && rd != 0`)
- **Trap taken here.** Exceptions are detected in IF (page fault), ID (illegal), EX (ecall/ebreak), and MEM (misaligned, access fault), but they are carried down the pipeline and only *acted on* at WB. This is what makes them precise: everything older has already written back, everything younger gets flushed.

Trap sequence: write `mepc`, `mcause`, `mtval`; set `mstatus.MPIE ← MIE`, `MIE ← 0`, `MPP ← current`; redirect PC to `mtvec` (+ `4 × cause` if vectored).

---

## 6. Hazard Unit — Complete Equations

Only one stall condition exists in a 5-stage pipeline with full forwarding:

```verilog
wire rs1_used = uses_rs1(if_id.instr);   // false for LUI, AUIPC, JAL
wire rs2_used = uses_rs2(if_id.instr);   // false for I-type, loads, U/J-type

wire load_use_hazard =
     id_ex.mem_read && (id_ex.rd != 0) &&
     ( (rs1_used && id_ex.rd == if_id_rs1) ||
       (rs2_used && id_ex.rd == if_id_rs2) );

wire stall_pc     = load_use_hazard | stall_all;
wire stall_if_id  = load_use_hazard | stall_all;
wire bubble_id_ex = load_use_hazard;    // inject NOP into EX
```

`rs1_used`/`rs2_used` matter. Getting them wrong doesn't break correctness (you stall unnecessarily), but a naive `always true` costs several percent IPC.

**CSR hazard.** A CSR write can change fetch or execution behaviour (`satp`, `mstatus`, `fence.i`). Simplest correct policy: flush the pipeline behind any CSR write. They're rare.

---

## 7. Forwarding Unit — Complete Selection Table

Priority matters: EX/MEM (newer) beats MEM/WB (older).

```verilog
// operand A
always_comb begin
  if (ex_mem.reg_write && ex_mem.rd != 0 && ex_mem.rd == id_ex.rs1)
      fwd_a = FROM_EX_MEM;
  else if (mem_wb.reg_write && mem_wb.rd != 0 && mem_wb.rd == id_ex.rs1)
      fwd_a = FROM_MEM_WB;
  else
      fwd_a = FROM_REGFILE;
end
// operand B: identical with rs2
```

Three forwarding paths are required in total:

| Path | Consumer | Purpose |
|---|---|---|
| EX/MEM → EX | ALU input A/B | back-to-back ALU dependency |
| MEM/WB → EX | ALU input A/B | load result to a use 2 slots later |
| MEM/WB → MEM | store data | `lw x1,..` then `sw x1,..` |

The third one is routinely forgotten and produces a bug that only appears on a specific load-store distance.

---

## 8. Core-S Module Hierarchy

```
core_s_top
├── frontend
│   ├── pc_gen              // PC mux + adders
│   ├── btb                 // 64-entry, 1 BRAM
│   ├── ras                 // 8-entry register array
│   └── icache_if
├── decode
│   ├── rvc_decompressor
│   ├── decoder             // control bundle
│   ├── imm_gen
│   └── regfile             // 32 x XLEN, 2R1W
├── execute
│   ├── alu
│   ├── branch_unit         // comparator + target adder
│   ├── mul_unit            // DSP
│   └── div_unit            // iterative
├── memory
│   ├── lsu                 // align, byte-enable, extend
│   └── dcache_if
├── writeback
├── csr_file                // mstatus, mtvec, mepc, mcause, mtval, counters
├── hazard_unit
├── forward_unit
└── trap_ctrl
```

---

# PART II — CORE-O: OUT-OF-ORDER 4-WIDE

## 9. Parameters

| Parameter | Value | Rationale |
|---|---|---|
| `FETCH_WIDTH` | 8 instrs (32 B) | must exceed decode width to absorb taken branches |
| `DECODE_WIDTH` | 4 | |
| `RENAME_WIDTH` | 4 | |
| `ISSUE_WIDTH` | 6 | 2 ALU + 1 complex + 1 branch + 2 AGU |
| `COMMIT_WIDTH` | 4 | must ≥ rename width or the ROB backs up |
| `ROB_ENTRIES` | 96 | |
| `PHYS_REGS_INT` | 128 | ≥ 32 + ROB_ENTRIES is the safe rule |
| `PHYS_REGS_FP` | 128 | |
| `IQ_INT` | 32 | |
| `IQ_MEM` | 24 | |
| `IQ_FP` | 16 | |
| `LQ_ENTRIES` | 32 | |
| `SQ_ENTRIES` | 24 | stores are ~40% of memory ops |
| `BR_CHECKPOINTS` | 16 | limits in-flight branches |
| `FETCH_BUFFER` | 24 instrs | |

**The `PHYS_REGS ≥ 32 + ROB_ENTRIES` rule.** In the worst case every ROB entry holds an instruction with a destination register, each holding one physical register, plus the 32 committed mappings. Violate this and you deadlock: rename stalls waiting for a free register that only commit can release, and commit is waiting behind the stalled instruction. If you want fewer physical registers, you must stall rename when the free list is low — which is fine, but it must be deliberate.

---

## 10. Front-End (F0 → IF3)

Covered structurally in the pipeline diagrams; the specification-level details:

| Structure | Size | Organization |
|---|---|---|
| BTB (fast, IF1) | 2048 entries | 4-way, indexed by fetch-block address |
| Bimodal (IF1) | 4096 × 2b | |
| TAGE (IF2/IF3) | 5 tables × 1024 × (3b ctr + 8b tag + 2b useful) | histories 5/15/44/130/400 |
| ITTAGE (IF3) | 4 tables × 512 | for indirect `JALR` |
| RAS | 32 entries + repair stack | |
| I-TLB | 32-entry fully-assoc | |

### Override timing contract

| Predictor tier | Result ready | Bubbles if it overrides | Recovery needed |
|---|---|---|---|
| BTB + bimodal | end of IF1 | 0 | none |
| TAGE + RAS | end of IF2 | 1 | squash IF1 |
| ITTAGE + pre-decode check | end of IF3 | 2 | squash IF1–IF2 |
| Branch unit (EX) | ~cycle 12 | 10–20 | full RAT/ROB/LSQ recovery |

The whole design goal is to move mispredicts up this table.

### Global history

Maintain **two** histories:
- **Speculative GHR** — updated at IF1 with predicted outcomes, used for indexing
- **Committed GHR** — updated at retire with actual outcomes, used to restore the speculative one after a mispredict

Fold the history into index/tag bits (`folded_hist`) rather than hashing a 400-bit register every cycle.

---

## 11. Rename

### Structures

| Structure | Size | Ports (4-wide) |
|---|---|---|
| Speculative RAT | 32 × 7b | 8R, 4W |
| Committed RAT | 32 × 7b | 4W (at retire) |
| Free list | 96-entry FIFO | 4 pop, 4 push |
| Busy table | 128 × 1b | 8R, 4W (set), 6W (clear on writeback) |
| Checkpoints | 16 × (32 × 7b + free-list head) | 1R, 1W |

### Per-instruction sequence

1. Read `rs1`, `rs2` from the speculative RAT → physical numbers
2. **Intra-group bypass**: if an earlier instruction in the same 4-wide group writes this `rs`, use its newly allocated physical register instead of the RAT read. This is a small comparator matrix — 6 comparisons for a 4-wide group, per source operand.
3. Pop a physical register from the free list for `rd`
4. Record `rd_phys_prev` (the old mapping) in the ROB — this is what gets freed at commit
5. Write the new mapping to the speculative RAT
6. If the instruction is a branch, take a checkpoint

### `x0` handling

`x0` must always read zero and discard writes. Map architectural `x0` to physical register 0, hardwire physical 0 to zero, and never place it on the free list. Instructions with `rd == x0` still allocate nothing — set `rd_phys = 0`.

---

## 12. ROB Entry Format

96 entries, each ~120 bits:

| Field | Bits | Purpose |
|---|---|---|
| `valid` | 1 | |
| `done` | 1 | set at writeback |
| `pc` | 39 | Sv39 VA; needed for `mepc` and predictor training |
| `rd_arch` | 5 | |
| `rd_phys` | 7 | |
| `rd_phys_prev` | 7 | freed at commit |
| `is_branch` | 1 | |
| `br_taken` | 1 | actual outcome, for training |
| `br_mispredict` | 1 | |
| `is_load` / `is_store` | 2 | |
| `lsq_idx` | 6 | |
| `checkpoint_id` | 4 | valid only if `is_branch` |
| `exc_valid` | 1 | |
| `exc_cause` | 5 | |
| `is_csr` / `is_fence` | 2 | force serialization at commit |

Head and tail pointers, allocated in program order at dispatch, freed in program order at commit.

---

## 13. Issue Queue

### Entry format (integer IQ, 32 entries)

| Field | Bits |
|---|---|
| `valid` | 1 |
| `uop` | 8 |
| `rs1_phys` | 7 |
| `rs1_ready` | 1 |
| `rs2_phys` | 7 |
| `rs2_ready` | 1 |
| `rd_phys` | 7 |
| `rob_idx` | 7 |
| `imm_idx` | 5 (pointer into a separate immediate file — storing 64-bit immediates in every IQ entry is wasteful) |
| `fu_type` | 3 |

### Wakeup–select loop

```
Cycle N:   select 2 ready entries for the ALUs
Cycle N:   broadcast their rd_phys tags to all IQ entries
Cycle N:   entries compare rs1_phys/rs2_phys against the tags, set ready
Cycle N+1: those entries are selectable
```

For back-to-back dependent single-cycle ALU ops, **select + tag broadcast + compare must all fit in one cycle**. This is the hardest timing constraint in the core and it is what caps issue queue size — a 64-entry unified queue usually will not close timing where two 32-entry split queues will.

**Speculative wakeup for loads.** Loads are woken up assuming an L1 hit. On a miss you must *replay* the dependent instructions that were speculatively issued. Either keep them in the IQ until the load is confirmed (simpler, costs IQ occupancy) or implement a replay queue.

### Select policy

Oldest-first beats random by 3–5% IPC. Implement it with an age matrix (32×32 bits for a 32-entry queue) or by keeping the queue compacted in age order — the compacting shifter is expensive at 4-wide, so the age matrix is usually the better choice.

---

## 14. Load/Store Queue

### Load queue entry (32)

| Field | Bits |
|---|---|
| `valid`, `addr_valid`, `executed` | 3 |
| `paddr` | 44 (implementation choice; Sv39 permits up to 56) |
| `size`, `signed` | 3 |
| `rob_idx` | 7 |
| `sq_tail_at_dispatch` | 5 (which stores are older than me) |
| `fwd_from_sq` | 5 |

### Store queue entry (24)

| Field | Bits |
|---|---|
| `valid`, `addr_valid`, `data_valid`, `committed` | 4 |
| `paddr` | 44 (implementation choice; Sv39 permits up to 56) |
| `data` | 64 |
| `size` | 2 |
| `rob_idx` | 7 |

### Disambiguation rules

**Load executes:** CAM the store queue for older stores (`sq_idx < sq_tail_at_dispatch`, with wraparound) whose `paddr` overlaps.

| Case | Action |
|---|---|
| Match, `data_valid`, fully covers the load | forward from SQ |
| Match, `data_valid`, partial overlap | stall the load until the store commits |
| Match, `!addr_valid` | unknown — stall, or speculate (see below) |
| No match | go to cache |

**Store executes:** CAM the load queue for *younger* loads that already executed and whose address overlaps. Any hit is a **memory order violation** → squash from that load onward. This is a full redirect, as expensive as a branch mispredict.

**Memory dependence prediction.** Always stalling on an unknown store address costs a lot of IPC; always speculating causes frequent violations. Use a **store-set predictor**: a table indexed by load PC that records which store PCs have previously conflicted with it. Speculate unless the predictor says this load has a known conflicting store in flight. Roughly recovers 90% of the gap.

### Store commit

Stores write the cache only *after* retiring — a store is architecturally irreversible. The committed store queue drains in the background; a load that hits a committed-but-not-yet-drained store must still forward from it.

---

## 15. Execution Units

| Unit | Count | Latency | Pipelined |
|---|---|---|---|
| Simple ALU | 2 | 1 | — |
| Branch unit | 1 | 1 | — |
| MUL | 1 | 3 | yes |
| DIV | 1 | ~34 (radix-4, RV64) | no |
| AGU (load) | 1 | 1 + cache | yes |
| AGU (store) | 1 | 1 | yes |
| FP FMA | 1 | 4 | yes |
| FP DIV/SQRT | 1 | ~20 | no |

The unpipelined DIV units need a busy flag that blocks selection; don't let the scheduler issue into an occupied non-pipelined unit.

### Register file port budget

Read ports are driven by `ISSUE_WIDTH`, **not** `RENAME_WIDTH` — a common sizing mistake:

| Consumer | Read ports | Write ports |
|---|---|---|
| 2 × simple ALU | 4 | 2 |
| Branch unit | 2 | 0 (link value comes from PC) |
| MUL / DIV | 2 | 1 (shared result bus) |
| Load AGU | 1 (base) | 1 |
| Store AGU | 2 (base + data) | 0 |
| **Integer PRF total** | **11** | **4–6** |

An 11-read-port 128×64 register file is large and slow. The standard mitigations, in order of preference:

1. **Bank it** — 2 banks of 64 registers, arbitrate on conflict, replay on the rare double-conflict
2. **Cluster it** — replicate the file per execution cluster, halving the ports on each copy at the cost of a cross-cluster bypass delay
3. **Read a cycle early** — issue reads operands in the following cycle anyway (already in this design as the Register Read stage)

Do the port arithmetic *before* choosing issue width. Going from 4-issue to 6-issue costs more in the register file than in the execution units.

---

## 16. Recovery Mechanisms

| Event | Detected at | Restore RAT | Squash | Cost |
|---|---|---|---|---|
| Front-end override | IF2/IF3 | not needed | fetch stages only | 1–2 cycles |
| Branch mispredict | EX | checkpoint restore, 1 cycle | ROB younger than branch, LSQ, free list | 10–20 cycles |
| Memory order violation | MEM | ROB walk from the load | everything younger than the load | 15–30 cycles |
| Exception / interrupt | Commit | copy committed RAT → spec RAT | everything | full drain |
| `fence.i` / CSR write | Commit | serialize | everything younger | full drain |

**Free list recovery is the subtle part.** On a mispredict you must return the physical registers allocated by squashed instructions. With checkpoints, save the free-list head pointer alongside the RAT snapshot and restore both — the entries between the restored head and the current head become free again automatically. This only works if the free list is a circular buffer that never reorders.

---

## 17. Core-O Module Hierarchy

```
core_o_top
├── frontend
│   ├── pc_sel                  // F0 priority mux
│   ├── bpu
│   │   ├── btb                 // 2K x 4-way
│   │   ├── bimodal
│   │   ├── tage                // 5 tables + base
│   │   ├── ittage
│   │   ├── ras
│   │   └── hist_mgr            // spec + committed GHR, folded
│   ├── ifu                     // IF1/IF2/IF3
│   │   ├── icache_if
│   │   ├── itlb
│   │   └── predecode           // RVC align, straddle, target check
│   └── fetch_buffer
├── decode
│   ├── rvc_decompressor  x4
│   └── decoder           x4
├── rename
│   ├── rat_spec
│   ├── rat_commit
│   ├── free_list
│   ├── busy_table
│   └── checkpoint_ram
├── dispatch
├── issue
│   ├── iq_int                  // 32, age matrix
│   ├── iq_mem                  // 24
│   ├── iq_fp                   // 16
│   └── select_logic
├── regread
│   ├── prf_int                 // 128 x 64, 11R 6W  (see §15 port budget)
│   ├── prf_fp
│   └── bypass_net
├── execute
│   ├── alu x2, branch_unit, mul, div
│   ├── agu x2
│   └── fpu
├── lsu
│   ├── load_queue              // 32
│   ├── store_queue             // 24
│   ├── mem_dep_pred            // store-set
│   ├── dtlb
│   └── dcache_if               // non-blocking, 8 MSHRs
├── rob                         // 96
└── commit
    ├── retire_logic
    └── pred_update
```

---

# PART III — TIMING, SIZING, VERIFICATION

## 18. Critical Paths

### Core-S

| Rank | Path | Mitigation |
|---|---|---|
| 1 | regfile read → forward mux → ALU → branch compare → PC mux | separate the branch comparator from the ALU; register the PC mux and accept +1 mispredict cycle |
| 2 | D-cache tag → hit → load align → WB mux | pipeline the align into WB |
| 3 | decoder → hazard unit → stall fanout | pre-decode `rs_used` in IF |

### Core-O

| Rank | Path | Mitigation |
|---|---|---|
| 1 | **select → tag broadcast → CAM compare → ready** | split the IQ; shrink each queue; use a matrix scheduler not a CAM |
| 2 | rename intra-group dependency check | limit rename width to 4, or add a rename pipeline stage |
| 3 | LSQ address CAM (32 entries × 44 bits) | bank by `addr[5:4]`, compare partial addresses first |
| 4 | PRF read → bypass mux → ALU | dedicated register-read stage (already in the design) |
| 5 | ROB commit: 4-wide exception priority encode | precompute the "oldest exception" at writeback |

Path 1 is the one that determines your clock frequency. Budget for it first; everything else follows.

## 19. Sizing Rationale

Do not copy these numbers blindly — derive them:

- **ROB** ≈ `IPC_target × memory_latency`. With 2 IPC and ~50-cycle L2 latency you need ~100 entries to cover an L2 miss. Beyond that, returns fall off sharply.
- **Issue queue** ≈ `ROB × fraction_not_ready`. Typically 30–40% of the window is waiting, so 32 integer entries against a 96-entry ROB is balanced.
- **LQ/SQ** ≈ `ROB × memory_op_fraction`. Memory ops are ~35% of instructions, split roughly 60/40 load/store → 32/24 against a 96-entry ROB.
- **Physical registers** = `32 + ROB` minimum (§9). 128 against a 96-entry ROB is *exactly* the minimum, not headroom — it guarantees no deadlock but rename will still stall when the free list empties. If you want rename to keep flowing, go to 160.
- **Branch checkpoints** ≈ in-flight branches. Branches are ~15% of instructions, so a 96-entry ROB holds ~14 → 16 checkpoints.

Everything scales off the ROB. Pick that first from your memory latency, then derive the rest.

## 20. Verification Plan

Phased, and this is not optional for Core-O:

| Phase | Method | Gate |
|---|---|---|
| 1 | `riscv-tests` ISA suite | all pass |
| 2 | `riscv-arch-test` (RISCOF) | compliance signature match |
| 3 | **Spike lockstep co-simulation** | every committed instruction's PC + arch state matches |
| 4 | `riscv-dv` constrained-random generation | 10⁹ instructions, no mismatch |
| 5 | Directed stress: LSQ | back-to-back partial-overlap store→load, all sizes |
| 6 | Directed stress: recovery | mispredict inside mispredict, exception inside mispredict shadow |
| 7 | Coverage closure | ROB full, IQ full, LQ/SQ full, free-list empty, checkpoint exhaustion |
| 8 | Benchmarks | CoreMark, Dhrystone, then SPEC subset for Core-O |

**Spike lockstep is the highest-value item on this list.** Comparing architectural state after every retirement finds bugs in cycles that random testing finds in weeks. Build it in phase 3, not at the end.

Bug classes that only show up in phase 5/6, in rough order of how often they bite:

1. Store→load forwarding with partial overlap (`sd` then `lw` of the upper half)
2. Free-list corruption after a mispredict inside another mispredict's shadow
3. RAS corruption on deeply nested calls past the stack depth
4. Exception in the shadow of a mispredicted branch being taken anyway
5. `x0` allocated on the free list
6. Memory order violation squash that doesn't roll back the store queue tail

---

## 21. Recommended Build Order

| Step | Deliverable | Effort |
|---|---|---|
| 1 | Single-cycle RV32I, no pipeline | 1 week |
| 2 | 5-stage, stall on all hazards | 1 week |
| 3 | Full forwarding + load-use interlock | 1 week |
| 4 | CSRs, traps, M-mode | 2 weeks |
| 5 | BTB + bimodal predictor | 1 week |
| 6 | M and C extensions | 2 weeks |
| 7 | **Core-S complete** — passes riscv-tests, runs on FPGA | — |
| 8 | Rename + ROB, keep issue in-order | 6+ weeks |
| 9 | Out-of-order issue + IQ | 6+ weeks |
| 10 | LSQ + disambiguation | 6+ weeks |
| 11 | TAGE + override front-end | 4 weeks |
| 12 | **Core-O complete** | — |

Steps 1–7 are a semester. Step 8 alone typically exceeds all of it, because it's the first point where a bug can be *architecturally invisible until 50 cycles later*. Build Spike co-simulation before starting step 8, not during it.