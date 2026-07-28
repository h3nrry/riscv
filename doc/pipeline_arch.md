# RISC-V Pipeline — ASCII Diagram

Three-cycle fetch (IF1/IF2/IF3) with the branch prediction unit drawn **inline**, alongside the full out-of-order back-end. Flow is top → bottom.

> View in a monospace font. The diagram is 104 columns wide — code blocks scroll horizontally.

---

## 1. Out-of-Order Core — Full Pipeline

```text


      ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
      │ F0 · PC SELECT MUX                                                                           │◄┐
  ┌──►│                                                                                              │ │
  │ ┌►│ priority:  commit redirect > EX redirect > IF3 override > IF2 override > IF1 fast > PC+16    │ │
  │ │ │ selected PC drives I-cache index + ITLB in the SAME cycle   →   critical path                │ │
  │ │ └──────────────────────────────────────────────────────────────────────────────────────────────┘ │
  │ │                    ▲                                                ▼                            │
  │ │ ┌────────────────────────────────────┐      ┌──────────────────────────────────────────────┐     │
  │ │ │ FAST PREDICTOR  (NLP)              │      │ IF1 · FETCH CYCLE 1                          │     │
  │ │ │                                    │      │                                              │     │
  │ │ │ BTB — small, direct-mapped         │─────►│ I-cache tag + data array read starts         │     │
  │ │ │ + bimodal counters                 │      │ ITLB lookup, PC → set index                  │     │
  │ │ │ answer ready end of IF1            │      │ BTB indexed with the same PC                 │     │
  │ │ │ → 0-bubble next PC                 │      │ no instruction bytes yet                     │     │
  │ │ └────────────────────────────────────┘      └──────────────────────────────────────────────┘     │
  │ │                                                                     ▼                            │
  │ │ ┌────────────────────────────────────┐      ┌──────────────────────────────────────────────┐     │
  │ │ │ MAIN PREDICTOR                     │      │ IF2 · FETCH CYCLE 2                          │     │
  │ │ │                                    │      │                                              │     │
  │ └─│ TAGE tagged tables read            │─────►│ tag compare, way select, hit/miss            │     │
  │   │ folded global history              │      │ 16-32 B fetch block returned                 │     │
  │   │ RAS pop on predicted return        │      │ miss → allocate MSHR, stall F0               │     │
  │   │ → override = 1 bubble              │      │ TAGE vs BTB disagree → override              │     │
  │   └────────────────────────────────────┘      └──────────────────────────────────────────────┘     │
  │                                                                       ▼                            │
  │   ┌────────────────────────────────────┐      ┌──────────────────────────────────────────────┐     │
  │   │ FINAL PREDICTOR                    │      │ IF3 · PRE-DECODE / ALIGN                     │     │
  │   │                                    │      │                                              │     │
  └───│ TAGE winner + ITTAGE (JALR)        │─────►│ find 16/32-bit boundaries (RVC)              │     │
      │ pre-decode target check            │      │ detect straddling instruction                │     │
      │ catches stale / aliased BTB        │      │ extract branch offsets                       │     │
      │ → override = 2 bubbles             │      │ mask instrs after taken branch               │     │
      └────────────────────────────────────┘      └──────────────────────────────────────────────┘     │
                         ▲                                                ▼                            │
                         ┊                        ┌----------------------------------------------┐     │
                         ┊                        │ FETCH BUFFER   ·   16-32 instrs              │     │
                         ┊                        │ decouples front-end from back-end            │     │
                         ┊                        └----------------------------------------------┘     │
                         ┊                                                ▼                            │
                         ┊                        ┌──────────────────────────────────────────────┐     │
                         ┊                        │ ID · DECODE                                  │     │
                         ┊                        │                                              │     │
                         ┊                        │ RVC expand, immediate gen, illegal trap      │     │
                         ┊                        │ µop crack: AMO, unaligned, some FP           │     │
                         ┊                        └──────────────────────────────────────────────┘     │
                         ┊                                                ▼                            │
                         ┊                        ┌──────────────────────────────────────────────┐     │
                         ┊                        │ RENAME                                       │     │
                         ┊                        │                                              │     │
                         ┊                        │ RAT lookup + free-list pop, x0 hardwired     │     │
                         ┊                        │ checkpoint RAT at branch ← point of no return│     │
                         ┊                        └──────────────────────────────────────────────┘     │
                         ┊                                                ▼                            │
                         ┊                        ┌──────────────────────────────────────────────┐     │
                         ┊                        │ DISPATCH                                     │     │
                         ┊                        │                                              │     │
                         ┊                        │ allocate ROB + IQ + LSQ; stall if any full   │     │
                         ┊                        └──────────────────────────────────────────────┘     │
                         ┊                                                ▼                            │
                         ┊                        ┌──────────────────────────────────────────────┐     │
                         ┊                        │ ISSUE / SELECT                               │     │
                         ┊                        │                                              │     │
                         ┊                        │ wakeup-select loop — the critical timing path│     │
                         ┊                        └──────────────────────────────────────────────┘     │
                         ┊                                                ▼                            │
                         ┊                        ┌──────────────────────────────────────────────┐     │
                         ┊                        │ REGISTER READ                                │     │
                         ┊                        │ physical regfile + bypass network            │     │
                         ┊                        └──────────────────────────────────────────────┘     │
                         ┊                                                ▼                            │
                         ┊                        ┌──────────────────────────────────────────────┐     │
                         ┊                        │ EX · EXECUTE            ◄ BRANCH RESOLVED    │     │
                         ┊                        │                                              │─────┘
                         ┊                        │ ALU x N · AGU · MUL/DIV · FPU · branch unit  │
                         ┊                        │ rs1 vs rs2 compare (no condition codes)      │
                         ┊                        └──────────────────────────────────────────────┘
                         ┊                                                ▼
                         ┊                        ┌──────────────────────────────────────────────┐
                         ┊                        │ MEM · LOAD / STORE                           │
                         ┊                        │                                              │
                         ┊                        │ LSQ disambiguation, store→load forwarding    │
                         ┊                        └──────────────────────────────────────────────┘
                         ┊                                                ▼
      ┌────────────────────────────────────┐      ┌──────────────────────────────────────────────┐
      │ PREDICTOR UPDATE                   │      │ COMMIT · ROB                                 │
      │                                    │◄─────│                                              │
      │ train BTB / TAGE / RAS at retire   │      │ in-order retire, precise traps, free regs    │
      └────────────────────────────────────┘      └──────────────────────────────────────────────┘


```

**Legend**

| Symbol | Meaning |
|---|---|
| `▼` | instruction flow, one stage per cycle |
| `─────►` | prediction feeding the matching fetch cycle |
| left lane into F0 (row 4) | IF3 override — 2 bubbles |
| left lane into F0 (row 6) | IF2 override — 1 bubble |
| right lane into F0 | EX mispredict redirect — 10–20 cycles |
| `┊` | predictor training path, Commit → BPU |
| `▲` above FAST PREDICTOR | IF1 fast prediction — 0 bubbles |

---

## 2. In-Order Core — Same Thing, Collapsed

Fetch becomes one cycle, the predictor loses its override tiers, and everything below Rename disappears.

```text
      ┌────────────────────────────────────┐      ┌──────────────────────────────────────────────┐
   ┌─►│ BRANCH PREDICTION UNIT             │      │                                              │
   │  │                                    │      │                                              │
   │  │ BTB      64-256 entries            │─────►│ F0/IF · FETCH                                │
   │  │ bimodal  512-2K counters           │      │ I-cache read, predicted next PC              │
   │  │ RAS      4-8 entries               │      │ RVC realign                                  │
   │  │ (no TAGE, no override tiers)       │      │                                              │
   │  └────────────────────────────────────┘      └──────────────────────────────────────────────┘
   │                                                                ▼   IF/ID register
   │                                               ┌──────────────────────────────────────────────┐
   │                                               │ ID · DECODE                                  │
   │                                               │                                              │
   │                                               │ regfile read (2R), immediate gen             │
   │                                               │ hazard detect + interlock                    │
   │                                               └──────────────────────────────────────────────┘
   │                                                                ▼   ID/EX register
   │                                               ┌──────────────────────────────────────────────┐
   │                                               │ EX · EXECUTE          ◄ BRANCH RESOLVED      │
   │                                               │                                              │
   └───────────────────────────────────────────────│ ALU, rs1 vs rs2 comparator, AGU              │
     mispredict → flush IF/ID  ·  2 cycles         │ forward muxes (EX/MEM, MEM/WB)               │
                                                   └──────────────────────────────────────────────┘
                                                                    ▼   EX/MEM register
                                                   ┌──────────────────────────────────────────────┐
                                                   │ MEM · MEMORY                                 │
                                                   │                                              │
                                                   │ blocking D-cache — a miss stalls everything  │
                                                   └──────────────────────────────────────────────┘
                                                                    ▼   MEM/WB register
                                                   ┌──────────────────────────────────────────────┐
                                                   │ WB · WRITEBACK                               │
                                                   │                                              │
                                                   │ architectural regfile write = commit         │
                                                   └──────────────────────────────────────────────┘
```

---

## 3. Where the Two Diverge

| | In-order | Out-of-order |
|---|---|---|
| Fetch cycles | 1 | 3 (IF1/IF2/IF3) |
| Predictor tiers | 1 (BTB + bimodal) | 3 (BTB → TAGE → ITTAGE) |
| Override capability | none | 1–2 bubble corrections |
| Buffering | pipeline registers only | fetch buffer, IQ, ROB, LSQ |
| Recovery state | 2 pipeline registers | RAT checkpoint, ROB, LSQ, free list |
| Mispredict penalty | 2 cycles | 10–20 cycles |
| Commit | WB stage | dedicated ROB retire |

The structural boundary that matters is **Rename**. Everything above it is cheap to squash — an override costs a bubble or two and needs no recovery state. Everything below it has allocated resources that must be un-allocated, which is the whole reason a mispredict costs an order of magnitude more.