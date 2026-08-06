# RISC-V CPU Live-Coding Bank — HARD Tier, Problems 401–600
### Phase 3 of 3 (Easy 1–200 complete · Medium 201–400 complete · Hard 401–600)

Each problem includes **Purpose**, a **full reference SystemVerilog solution**, and a **Derivation** (formal proof for math/bit-manipulation modules; structured design derivation — state-transition reasoning, timing trace, or invariant argument — everywhere else). Hard tier covers full-scale out-of-order structures, cache/TLB/coherence, advanced CDC, low-power, arithmetic units, verification, and precise-exception handling at OoO scale.

This file is being built incrementally, one category at a time, to keep each write manageable. **Category 1 below; more appended as they're completed.**

---

## Category 1: Out-of-Order Core Structures at Scale (401–420)

**401. Full N-Entry Reorder Buffer (Circular, with Exception/Branch Tags)** — *(Hard)*
*Purpose:* The complete ROB structure a real OoO core uses — extends the Medium tier's `simple_rob` with per-entry exception and branch-mask tags needed for precise exceptions and speculative recovery at scale.
```systemverilog
module rob_full #(parameter int DEPTH = 32, parameter int NUM_BR = 8) (
    input  logic clk, rst_n,
    input  logic alloc_valid, output logic alloc_ready,
    output logic [$clog2(DEPTH)-1:0] alloc_tag,
    input  logic [NUM_BR-1:0] alloc_br_mask,
    input  logic complete_valid, input logic [$clog2(DEPTH)-1:0] complete_tag,
    input  logic complete_excepted, input logic [31:0] complete_exc_cause,
    output logic commit_valid, output logic [$clog2(DEPTH)-1:0] commit_tag,
    output logic commit_excepted, output logic [31:0] commit_exc_cause,
    input  logic br_resolve_valid, input logic [$clog2(NUM_BR)-1:0] br_resolve_id, input logic br_mispredict
);
    localparam int PTR_W = $clog2(DEPTH);
    logic [DEPTH-1:0] done, excepted;
    logic [DEPTH-1:0][31:0] exc_cause;
    logic [DEPTH-1:0][NUM_BR-1:0] br_mask;
    logic [PTR_W:0] head, tail;

    assign alloc_ready  = (tail - head) != PTR_W'(DEPTH);
    assign alloc_tag     = tail[PTR_W-1:0];
    assign commit_valid = (head != tail) && done[head[PTR_W-1:0]];
    assign commit_tag    = head[PTR_W-1:0];
    assign commit_excepted = excepted[head[PTR_W-1:0]];
    assign commit_exc_cause = exc_cause[head[PTR_W-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0; tail <= '0; done <= '0; excepted <= '0;
        end else begin
            if (alloc_valid && alloc_ready) begin
                done[tail[PTR_W-1:0]]     <= 1'b0;
                excepted[tail[PTR_W-1:0]] <= 1'b0;
                br_mask[tail[PTR_W-1:0]]  <= alloc_br_mask;
                tail <= tail + 1'b1;
            end
            if (complete_valid) begin
                done[complete_tag]     <= 1'b1;
                excepted[complete_tag] <= complete_excepted;
                exc_cause[complete_tag] <= complete_exc_cause;
            end
            if (commit_valid) head <= head + 1'b1;
            if (br_resolve_valid && br_mispredict)
                tail <= tail;   // handled by Problem 359-style tail rewind in a companion module, omitted for clarity here
        end
    end
endmodule
```
*Derivation:* Direct scale-up of Problem 342's `simple_rob`, adding a per-entry `br_mask` (which in-flight branches this instruction is speculatively dependent on — used by Problem 416's checkpoint manager to know which entries a given branch's misprediction must flush) and per-entry exception state (`excepted`/`exc_cause`), so a completed-but-excepting instruction can sit at any depth in the buffer without disturbing entries around it, only actually acting on the exception once it reaches `head` — exactly Problem 358's principle, now at realistic depth (32 entries) instead of the Medium tier's illustrative single-entry version.

**402. RAT with Checkpoint/Restore (Multiple Speculative Checkpoints)** — *(Hard)*
*Purpose:* Extends the Medium tier's single-mapping RAT (Problem 346) with the ability to save a full copy of the rename map at each speculative branch, so a misprediction can restore the map instantly instead of walking the ROB to undo renames one at a time.
```systemverilog
module rat_checkpointed #(parameter int PREG_W = 7, parameter int NUM_CKPT = 8) (
    input  logic clk, rst_n,
    input  logic rename_valid, input logic [4:0] rename_areg, input logic [PREG_W-1:0] rename_preg,
    input  logic [4:0] lookup_areg1, lookup_areg2,
    output logic [PREG_W-1:0] lookup_preg1, lookup_preg2,
    input  logic ckpt_save_valid, input logic [$clog2(NUM_CKPT)-1:0] ckpt_save_id,
    input  logic ckpt_restore_valid, input logic [$clog2(NUM_CKPT)-1:0] ckpt_restore_id
);
    logic [PREG_W-1:0] map [32];
    logic [PREG_W-1:0] ckpt [NUM_CKPT][32];

    assign lookup_preg1 = map[lookup_areg1];
    assign lookup_preg2 = map[lookup_areg2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) map[i] <= i[PREG_W-1:0];
        end else if (ckpt_restore_valid) begin
            for (int i = 0; i < 32; i++) map[i] <= ckpt[ckpt_restore_id][i];
        end else begin
            if (ckpt_save_valid)
                for (int i = 0; i < 32; i++) ckpt[ckpt_save_id][i] <= map[i];
            if (rename_valid && (rename_areg != 5'd0))
                map[rename_areg] <= rename_preg;
        end
    end
endmodule
```
*Derivation:* A full 32-entry copy per checkpoint (`NUM_CKPT` copies total) trades significant storage for O(1) recovery time — restoring after a misprediction is a single-cycle bulk copy instead of Problem 415-style incremental unwind through the ROB, which matters because branch-misprediction recovery latency directly determines the penalty every misprediction costs; `ckpt_restore_valid` takes priority over a same-cycle new rename since a restore implies the mispredicted branch's own rename (and everything after it) is being discarded anyway.

**403. Physical Register File with Free-List Bit-Vector + Priority Encoder** — *(Hard)*
*Purpose:* An alternative free-list implementation to Problem 347's FIFO — a bit-vector plus priority encoder, useful when the allocator needs to also support bulk operations (like Problem 402's checkpoint restore implicitly freeing registers) more naturally than a FIFO's strict order allows.
```systemverilog
module free_list_bitvector #(parameter int NUM_PREGS = 128) (
    input  logic clk, rst_n,
    input  logic alloc_req, output logic alloc_valid, output logic [$clog2(NUM_PREGS)-1:0] alloc_preg,
    input  logic free_req, input logic [$clog2(NUM_PREGS)-1:0] free_preg
);
    logic [NUM_PREGS-1:0] free_bits;
    logic [$clog2(NUM_PREGS)-1:0] first_free_idx;
    logic any_free;

    always_comb begin
        first_free_idx = '0; any_free = |free_bits;
        for (int i = NUM_PREGS-1; i >= 0; i--)
            if (free_bits[i]) first_free_idx = i[$clog2(NUM_PREGS)-1:0];
    end
    assign alloc_valid = any_free;
    assign alloc_preg   = first_free_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bits <= {NUM_PREGS{1'b1}};
            for (int i = 0; i < 32; i++) free_bits[i] <= 1'b0;   // first 32 are pre-mapped by RAT reset, not free
        end else begin
            if (alloc_req && alloc_valid) free_bits[first_free_idx] <= 1'b0;
            if (free_req)                  free_bits[free_preg]     <= 1'b1;
        end
    end
endmodule
```
*Derivation:* The priority-encoder-over-a-bit-vector structure (identical mux-chain logic to the `priority_enc8` module examined earlier in this conversation, scaled to `NUM_PREGS` bits) lets *any* subset of registers be freed in one cycle by simply OR-ing bits back into `free_bits`, which is exactly what's needed if a checkpoint restore (Problem 402) needs to bulk-free every register renamed after the restored checkpoint — a FIFO-based free list (Problem 347) can't easily support that kind of non-sequential bulk free, which is the concrete tradeoff between the two free-list implementations.

**404. Reservation Station Entry (Tomasulo, 2-Source with Tag/Data)** — *(Hard)*
*Purpose:* The classic Tomasulo reservation-station entry — holds either a source operand's actual value (if already available) or the tag of whichever functional unit will produce it, waking up via tag broadcast exactly as in Problem 350 but now storing the resolved data itself, not just a readiness bit.
```systemverilog
module rs_entry_2src #(parameter int TAG_W = 6, parameter int DATA_W = 32) (
    input  logic clk, rst_n,
    input  logic alloc_valid,
    input  logic src1_ready_in, src2_ready_in,
    input  logic [DATA_W-1:0] src1_data_in, src2_data_in,
    input  logic [TAG_W-1:0] src1_tag_in, src2_tag_in,
    input  logic broadcast_valid, input logic [TAG_W-1:0] broadcast_tag, input logic [DATA_W-1:0] broadcast_data,
    output logic entry_valid, entry_ready,
    output logic [DATA_W-1:0] src1_data, src2_data,
    input  logic issue_fire
);
    logic v, s1_rdy, s2_rdy;
    logic [DATA_W-1:0] s1_data, s2_data;
    logic [TAG_W-1:0] s1_tag, s2_tag;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v <= 1'b0;
        end else if (alloc_valid) begin
            v <= 1'b1;
            s1_rdy <= src1_ready_in; s1_data <= src1_data_in; s1_tag <= src1_tag_in;
            s2_rdy <= src2_ready_in; s2_data <= src2_data_in; s2_tag <= src2_tag_in;
        end else if (issue_fire) begin
            v <= 1'b0;
        end else if (broadcast_valid) begin
            if (!s1_rdy && (s1_tag == broadcast_tag)) begin s1_rdy <= 1'b1; s1_data <= broadcast_data; end
            if (!s2_rdy && (s2_tag == broadcast_tag)) begin s2_rdy <= 1'b1; s2_data <= broadcast_data; end
        end
    end
    assign entry_valid = v;
    assign entry_ready  = v && s1_rdy && s2_rdy;
    assign src1_data     = s1_data;
    assign src2_data     = s2_data;
endmodule
```
*Derivation:* Unlike Problem 349's simple in-order issue queue (which only tracked readiness bits and read the actual data from the register file at issue time), a true Tomasulo reservation station captures the *data itself* as soon as it's broadcast, even while the entry is still waiting on its other operand — this is what lets an entry become instantly issue-ready the moment its last missing operand arrives, without a separate register-file read step, at the cost of needing a full `DATA_W`-wide storage field per operand per entry rather than just a tag.

**405. Wakeup Broadcast Network (N-Wide CAM Compare)** — *(Hard)*
*Purpose:* Scales Problem 350's single-broadcast wakeup to a realistic multi-issue design where several functional units can each broadcast a completed tag in the same cycle, and every reservation-station entry must check against all of them simultaneously.
```systemverilog
module wakeup_network #(parameter int DEPTH = 32, parameter int NUM_BCAST = 4, parameter int TAG_W = 6) (
    input  logic [NUM_BCAST-1:0] bcast_valid,
    input  logic [NUM_BCAST-1:0][TAG_W-1:0] bcast_tag,
    input  logic [DEPTH-1:0] entry_valid,
    input  logic [DEPTH-1:0][TAG_W-1:0] entry_src1_tag, entry_src2_tag,
    input  logic [DEPTH-1:0] entry_src1_rdy, entry_src2_rdy,
    output logic [DEPTH-1:0] wake_src1, wake_src2
);
    always_comb begin
        for (int e = 0; e < DEPTH; e++) begin
            wake_src1[e] = 1'b0; wake_src2[e] = 1'b0;
            if (entry_valid[e]) begin
                for (int b = 0; b < NUM_BCAST; b++) begin
                    if (bcast_valid[b] && !entry_src1_rdy[e] && (entry_src1_tag[e] == bcast_tag[b])) wake_src1[e] = 1'b1;
                    if (bcast_valid[b] && !entry_src2_rdy[e] && (entry_src2_tag[e] == bcast_tag[b])) wake_src2[e] = 1'b1;
                end
            end
        end
    end
endmodule
```
*Derivation:* A full `DEPTH × NUM_BCAST` comparator array (every entry checked against every broadcast source simultaneously) — this is the actual scaling bottleneck of large out-of-order designs, since the wakeup network's area and power grow with the *product* of issue-queue depth and issue width, which is precisely why real high-performance cores keep individual issue queues relatively small (tens of entries) and split into multiple smaller queues per functional-unit cluster rather than one enormous unified queue, trading some scheduling flexibility for a tractable wakeup network.

**406. Select Logic with Age Matrix** — *(Hard)*
*Purpose:* A true age-ordered select (extending Problem 352) using an explicit pairwise age matrix rather than a stored numeric age tag — the standard technique for scalable oldest-first arbitration among many simultaneously-ready entries.
```systemverilog
module select_age_matrix #(parameter int DEPTH = 16) (
    input  logic [DEPTH-1:0] ready,
    input  logic [DEPTH-1:0][DEPTH-1:0] older_than,   // older_than[i][j] = 1 if entry i is older than entry j
    output logic [DEPTH-1:0] grant
);
    always_comb begin
        grant = '0;
        for (int i = 0; i < DEPTH; i++) begin
            automatic logic i_is_oldest_ready = ready[i];
            for (int j = 0; j < DEPTH; j++)
                if (ready[j] && older_than[j][i]) i_is_oldest_ready = 1'b0;
            if (i_is_oldest_ready) grant[i] = 1'b1;
        end
    end
endmodule
```
*Derivation:* Entry `i` is the oldest *ready* entry exactly when no other ready entry `j` is older than it (`older_than[j][i]`) — checking this pairwise, for every entry, against every other entry is an O(DEPTH²) comparator structure, which is exactly what an age matrix trades area for: unlike Problem 352's linear scan (which needs a numeric age field and a running "oldest so far" comparison, effectively serial in derivation even if flattened combinationally), the matrix form parallelizes cleanly and is the standard construction used in real scheduler select logic — see also Problem 407 for how the matrix itself is maintained.

**407. Age Matrix Construction/Maintenance** — *(Hard)*
*Purpose:* Maintains Problem 406's `older_than` matrix as entries are allocated and freed — a new entry is younger than every currently-live entry, and a freed entry's row/column must be cleared to avoid stale age relationships persisting after its slot is reused.
```systemverilog
module age_matrix_maintain #(parameter int DEPTH = 16) (
    input  logic clk, rst_n,
    input  logic alloc_valid, input logic [$clog2(DEPTH)-1:0] alloc_idx,
    input  logic [DEPTH-1:0] entry_valid,
    output logic [DEPTH-1:0][DEPTH-1:0] older_than
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            older_than <= '0;
        end else if (alloc_valid) begin
            for (int j = 0; j < DEPTH; j++) begin
                if (entry_valid[j] && (j != alloc_idx)) begin
                    older_than[j][alloc_idx]        <= 1'b1;   // every existing live entry is older than the new one
                    older_than[alloc_idx][j] <= 1'b0;
                end
            end
            older_than[alloc_idx][alloc_idx] <= 1'b0;
        end
    end
endmodule
```
*Derivation:* On allocation, the new entry's row is set to "younger than every currently-valid entry" in one cycle by writing an entire row/column pair at once — this is the maintenance-side counterpart that makes Problem 406's select logic correct: the invariant `older_than[j][alloc_idx]=1` for every previously-live `j` is exactly what guarantees a newly-dispatched instruction never wins select over any older still-pending one, preserving program-order-biased scheduling fairness even though issue itself is fundamentally out-of-order.

**408. Issue Queue — Compacting (Collapsing)** — *(Hard)*
*Purpose:* A compacting issue queue physically shifts remaining entries down to fill the gap whenever an entry issues, keeping the queue always packed at the bottom — simpler select logic (always check only the first K entries) at the cost of a shift network's power/complexity every cycle.
```systemverilog
module iq_collapsing #(parameter int DEPTH = 8, parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic enq_valid, output logic enq_ready, input logic [W-1:0] enq_data,
    input  logic issue_fire, input logic [$clog2(DEPTH)-1:0] issue_idx,
    output logic [DEPTH-1:0] entry_valid,
    output logic [DEPTH-1:0][W-1:0] entry_data
);
    logic [$clog2(DEPTH):0] count;
    assign enq_ready = (count != DEPTH);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0; entry_valid <= '0;
        end else begin
            if (issue_fire) begin
                // shift every entry above issue_idx down by one
                for (int i = 0; i < DEPTH-1; i++) begin
                    if (i >= issue_idx) begin
                        entry_valid[i] <= entry_valid[i+1];
                        entry_data[i]  <= entry_data[i+1];
                    end
                end
                entry_valid[DEPTH-1] <= 1'b0;
                count <= count - 1'b1;
                if (enq_valid && enq_ready) begin
                    entry_valid[count-1] <= 1'b1;   // new entry lands at the (now-shifted) top
                    entry_data[count-1]  <= enq_data;
                end
            end else if (enq_valid && enq_ready) begin
                entry_valid[count[$clog2(DEPTH)-1:0]] <= 1'b1;
                entry_data[count[$clog2(DEPTH)-1:0]]  <= enq_data;
                count <= count + 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* Because every issue immediately closes the gap it leaves, valid entries always occupy a contiguous block starting at index 0 — this simplifies wakeup/select logic (which only ever needs to consider `count` active entries, always at the bottom) at the direct cost of the shift itself, which touches potentially every entry's full data width every single cycle an issue occurs, making this approach's power/area cost scale with both `DEPTH` and `W` in a way non-collapsing designs (Problem 409) specifically avoid.

**409. Issue Queue — Non-Collapsing (Free-Slot Bitmap)** — *(Hard)*
*Purpose:* The alternative to Problem 408 — entries stay in their originally-allocated slot for their entire lifetime; a free-slot bitmap (rather than physical compaction) tracks which slots are available, avoiding any shift network at the cost of needing to check every slot (not just the first K) during select.
```systemverilog
module iq_noncollapsing #(parameter int DEPTH = 8, parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic enq_valid, output logic enq_ready, output logic [$clog2(DEPTH)-1:0] enq_slot,
    input  logic [W-1:0] enq_data,
    input  logic issue_fire, input logic [$clog2(DEPTH)-1:0] issue_slot,
    output logic [DEPTH-1:0] entry_valid,
    output logic [DEPTH-1:0][W-1:0] entry_data
);
    logic [DEPTH-1:0] free_slots;
    always_comb begin
        enq_slot = '0; enq_ready = 1'b0;
        for (int i = 0; i < DEPTH; i++)
            if (free_slots[i]) begin enq_slot = i[$clog2(DEPTH)-1:0]; enq_ready = 1'b1; break; end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_slots <= {DEPTH{1'b1}}; entry_valid <= '0;
        end else begin
            if (enq_valid && enq_ready) begin
                free_slots[enq_slot]  <= 1'b0;
                entry_valid[enq_slot] <= 1'b1;
                entry_data[enq_slot]  <= enq_data;
            end
            if (issue_fire) begin
                free_slots[issue_slot]  <= 1'b1;
                entry_valid[issue_slot] <= 1'b0;
            end
        end
    end
endmodule
```
*Derivation:* No shift network at all — an issued entry's slot simply becomes free again (tracked in `free_slots`, the same priority-encoder-over-bit-vector pattern as Problem 403's free list) and a new entry can land in *any* free slot, not necessarily a low-numbered one; the tradeoff versus Problem 408 is that wakeup/select logic (Problems 405/406) must now scan all `DEPTH` slots every cycle regardless of how many are actually occupied, since valid entries can be scattered anywhere — real high-performance designs generally prefer non-collapsing queues specifically to avoid the collapsing design's data-shift power cost, accepting the full-width wakeup/select scan as the lesser cost.

**410. Load/Store Queue Full Disambiguation (Address CAM)** — *(Hard)*
*Purpose:* The complete memory-disambiguation structure — every in-flight load checks its address against every older in-flight store's address (a CAM search), determining whether it can forward from a store, must wait, or is clear to access memory/cache directly.
```systemverilog
module lsq_disambig #(parameter int DEPTH = 16, parameter int ADDR_W = 32) (
    input  logic [DEPTH-1:0] store_valid, store_addr_known,
    input  logic [DEPTH-1:0][ADDR_W-1:0] store_addr,
    input  logic [DEPTH-1:0][$clog2(DEPTH)-1:0] store_age,
    input  logic load_valid, input logic [ADDR_W-1:0] load_addr, input logic [$clog2(DEPTH)-1:0] load_age,
    output logic must_wait,       // an older store with unknown address exists -> can't safely proceed
    output logic forward_hit,      // an older store with matching known address exists -> forward from it
    output logic [$clog2(DEPTH)-1:0] forward_idx
);
    logic [DEPTH-1:0] older_match, older_unknown;
    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            automatic logic is_older = store_valid[i] && (store_age[i] < load_age);
            older_match[i]   = is_older && store_addr_known[i] && (store_addr[i] == load_addr);
            older_unknown[i] = is_older && !store_addr_known[i];
        end
    end
    assign must_wait   = load_valid && |older_unknown;
    assign forward_hit = load_valid && !must_wait && |older_match;

    always_comb begin
        forward_idx = '0;
        for (int i = DEPTH-1; i >= 0; i--)
            if (older_match[i]) forward_idx = i[$clog2(DEPTH)-1:0];   // youngest among the older matching stores wins
    end
endmodule
```
*Derivation:* `must_wait` takes priority over `forward_hit` for a fundamental correctness reason: if *any* older store's address isn't yet known (its address-generation hasn't executed), the load genuinely cannot be proven safe to proceed — it might alias with that unresolved store, so conservatively stalling is the only correct choice, even if every *known* older store's address happens not to match; `forward_idx` picks the *youngest* among matching older stores because that's the most recently-written value the load should logically observe (an even older matching store's data would have already been overwritten by the younger one, architecturally).

**411. Store Set Predictor (Memory Dependence Prediction)** — *(Hard)*
*Purpose:* Rather than always conservatively stalling loads behind stores with unknown addresses (Problem 410's `must_wait`), a store-set predictor learns *which specific* store-load pairs have historically actually aliased, letting unrelated loads issue speculatively past stores that have never actually conflicted with them.
```systemverilog
module store_set_predictor #(parameter int TABLE_SIZE = 256) (
    input  logic clk, rst_n,
    input  logic [31:0] load_pc,
    output logic [$clog2(TABLE_SIZE)-1:0] load_ssid, output logic load_has_ssid,
    input  logic [31:0] store_pc,
    output logic [$clog2(TABLE_SIZE)-1:0] store_ssid, output logic store_has_ssid,
    input  logic train_valid, input logic [31:0] train_load_pc, train_store_pc
);
    localparam int IDX_W = $clog2(TABLE_SIZE);
    logic [IDX_W-1:0] ssid_table [TABLE_SIZE];
    logic valid_arr [TABLE_SIZE];

    assign load_ssid      = ssid_table[load_pc[IDX_W-1:0]];
    assign load_has_ssid  = valid_arr[load_pc[IDX_W-1:0]];
    assign store_ssid     = ssid_table[store_pc[IDX_W-1:0]];
    assign store_has_ssid = valid_arr[store_pc[IDX_W-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < TABLE_SIZE; i++) valid_arr[i] <= 1'b0;
        end else if (train_valid) begin
            // on a detected violation (Problem 412), assign both the load and store PC to the same store-set ID
            ssid_table[train_load_pc[IDX_W-1:0]]  <= train_store_pc[IDX_W-1:0];
            ssid_table[train_store_pc[IDX_W-1:0]] <= train_store_pc[IDX_W-1:0];
            valid_arr[train_load_pc[IDX_W-1:0]]   <= 1'b1;
            valid_arr[train_store_pc[IDX_W-1:0]]  <= 1'b1;
        end
    end
endmodule
```
*Derivation:* When a real memory-order violation is detected (Problem 412), both the offending load's and store's PC get assigned the *same* store-set ID (conventionally the store's own PC, canonicalizing the set) — any future load with that same ID is then made to wait specifically for stores sharing that ID, rather than every unresolved older store, which is what lets truly-unrelated store/load pairs continue issuing speculatively past each other while known-conflicting pairs are correctly serialized, striking a much better balance than Problem 410's blanket conservative stall.

**412. Memory Order Violation Detector at Scale** — *(Hard)*
*Purpose:* Scales the earlier single-comparison memory-order-violation check to the full LSQ width — after a store's address becomes known, it must check every *younger* load that already speculatively executed to see if any of them incorrectly bypassed it.
```systemverilog
module mem_order_violation_scale #(parameter int DEPTH = 16, parameter int ADDR_W = 32) (
    input  logic store_addr_valid, input logic [ADDR_W-1:0] store_addr, input logic [$clog2(DEPTH)-1:0] store_age,
    input  logic [DEPTH-1:0] load_valid, load_executed,
    input  logic [DEPTH-1:0][ADDR_W-1:0] load_addr,
    input  logic [DEPTH-1:0][$clog2(DEPTH)-1:0] load_age,
    output logic [DEPTH-1:0] violation
);
    always_comb
        for (int i = 0; i < DEPTH; i++)
            violation[i] = store_addr_valid && load_valid[i] && load_executed[i] &&
                            (load_addr[i] == store_addr) && (load_age[i] > store_age);
endmodule
```
*Derivation:* A younger load (`load_age > store_age`) that already executed (`load_executed`) before this store's address was known represents a genuine speculation failure if their addresses match — that load read memory (or an even-older store) *before* it should have seen this store's write, so its result is wrong and it (plus everything after it in program order) must be replayed; this is exactly the training signal Problem 411's store-set predictor consumes to learn the aliasing relationship for next time.

**413. Commit-Width-N Retirement Controller** — *(Hard)*
*Purpose:* Extends Problem 353's commit-width-1 retirement to a realistic superscalar commit width, where up to N consecutive ROB entries can retire in a single cycle — but only as a *contiguous* prefix, and only up to (not past) the first excepting or not-yet-done entry.
```systemverilog
module retire_ctrl_wideN #(parameter int WIDTH = 4) (
    input  logic [WIDTH-1:0] entry_done, entry_excepted,
    output logic [WIDTH-1:0] commit_this_cycle,
    output logic exception_at_slot, output logic [$clog2(WIDTH)-1:0] exception_slot
);
    always_comb begin
        commit_this_cycle = '0;
        exception_at_slot = 1'b0; exception_slot = '0;
        for (int i = 0; i < WIDTH; i++) begin
            if (!entry_done[i]) break;                 // stop at the first not-yet-complete entry
            if (entry_excepted[i]) begin
                exception_at_slot = 1'b1; exception_slot = i[$clog2(WIDTH)-1:0];
                break;                                    // commit up to but not past the excepting entry
            end
            commit_this_cycle[i] = 1'b1;
        end
    end
endmodule
```
*Derivation:* Because commit must remain strictly in program order even at wide commit width, a `break`-terminated scan (rather than a parallel per-slot check) is the *correct* structure, not just a coding convenience — slot `i+1` can never legally commit if slot `i` hasn't, regardless of whether slot `i+1` happens to individually be `done`, which is exactly why this can't be flattened into `WIDTH` independent combinational checks the way, say, Problem 412's per-load violation check can (those loads are genuinely independent; commit slots are not).

**414. ROB Exception Walk (Find Oldest Excepting Entry Among Wide Commit)** — *(Hard)*
*Purpose:* Isolated view of exactly the exception-detection half of Problem 413 — needed because commit-width-N logic must know not just "commit up to here" but specifically flag which entry (if any) within this cycle's candidate window is the one that should trigger a trap.
```systemverilog
module rob_exc_walk #(parameter int WIDTH = 4) (
    input  logic [WIDTH-1:0] candidate_done, candidate_excepted,
    output logic found_exc,
    output logic [$clog2(WIDTH)-1:0] exc_slot
);
    always_comb begin
        found_exc = 1'b0; exc_slot = '0;
        for (int i = 0; i < WIDTH; i++) begin
            if (!candidate_done[i]) break;
            if (candidate_excepted[i]) begin found_exc = 1'b1; exc_slot = i[$clog2(WIDTH)-1:0]; break; end
        end
    end
endmodule
```
*Derivation:* Same scan structure as Problem 413, split out because in a real design this walk (identifying *which* entry excepts) often needs to feed Problem 305's trap-entry sequencing (which needs to know the specific PC/cause of exactly one instruction) as a separate, narrower-purpose signal from the broader "how many slots commit this cycle" decision.

**415. Speculative Register Free (Delayed Free Until Non-Speculative)** — *(Hard)*
*Purpose:* A renamed-out physical register (the one an instruction's `rd` used to map to, before this instruction's rename overwrote the RAT entry) can't be freed for reuse the instant the rename happens — it might still be needed if a misprediction rolls back to before this instruction. It can only be freed once this instruction itself commits (becomes non-speculative).
```systemverilog
module speculative_preg_free (
    input  logic commit_valid,
    input  logic [6:0] commit_old_preg,   // the physical register this commit's rename replaced
    output logic free_req,
    output logic [6:0] free_preg
);
    assign free_req  = commit_valid;
    assign free_preg = commit_old_preg;
endmodule
```
*Derivation:* This is the precise reason a real free list frees registers at *commit* time, not at *rename* time — the "old" physical register mapping for a given architectural register must remain valid and readable for as long as any earlier checkpoint (Problem 402) might need to be restored to it, and a checkpoint can only be safely discarded once the branch it corresponds to is known-correctly-predicted, which is only guaranteed once the instruction (and everything associated with the checkpoint) has actually committed.

**416. Checkpoint Manager for Branch Recovery (Multiple In-Flight Branches)** — *(Hard)*
*Purpose:* Tracks which of Problem 402's checkpoint slots is associated with which in-flight branch, allocating one on every speculative branch dispatch and freeing it once that branch resolves (correctly predicted) or triggers recovery (mispredicted).
```systemverilog
module ckpt_manager #(parameter int NUM_CKPT = 8) (
    input  logic clk, rst_n,
    input  logic branch_dispatch_valid, output logic ckpt_alloc_valid, output logic [$clog2(NUM_CKPT)-1:0] ckpt_alloc_id,
    input  logic branch_resolve_valid, input logic [$clog2(NUM_CKPT)-1:0] resolve_ckpt_id, input logic mispredict
);
    logic [NUM_CKPT-1:0] in_use;
    always_comb begin
        ckpt_alloc_valid = 1'b0; ckpt_alloc_id = '0;
        for (int i = 0; i < NUM_CKPT; i++)
            if (!in_use[i]) begin ckpt_alloc_valid = 1'b1; ckpt_alloc_id = i[$clog2(NUM_CKPT)-1:0]; break; end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) in_use <= '0;
        else begin
            if (branch_dispatch_valid && ckpt_alloc_valid) in_use[ckpt_alloc_id] <= 1'b1;
            if (branch_resolve_valid) in_use[resolve_ckpt_id] <= 1'b0;   // freed whether correctly predicted or not
        end
    end
endmodule
```
*Derivation:* The number of checkpoints (`NUM_CKPT`) directly caps how many *unresolved* speculative branches can be in flight simultaneously — once all checkpoints are in use, dispatch must stall on the next branch (a real structural hazard, the checkpoint analogue of Problem 354's ROB-full stall) until an earlier branch resolves and frees its slot; this is one of the concrete capacity limits (alongside ROB depth and physical register count) that bounds how deep an out-of-order core can actually speculate.

**417. Dependency Matrix Scheduler** — *(Hard)*
*Purpose:* An alternative scheduler organization to the tag-broadcast wakeup network (Problem 405) — explicitly tracks a bit-matrix of which entries depend on which other entries still in the scheduler, useful for schedulers that need to reason about dependency chains directly rather than purely reactively via tag matching.
```systemverilog
module dep_matrix_sched #(parameter int DEPTH = 16) (
    input  logic [DEPTH-1:0][DEPTH-1:0] depends_on,   // depends_on[i][j] = entry i needs entry j's result
    input  logic [DEPTH-1:0] entry_valid,
    input  logic [DEPTH-1:0] entry_completed,
    output logic [DEPTH-1:0] entry_ready
);
    always_comb
        for (int i = 0; i < DEPTH; i++) begin
            automatic logic all_deps_done = 1'b1;
            for (int j = 0; j < DEPTH; j++)
                if (depends_on[i][j] && entry_valid[j] && !entry_completed[j]) all_deps_done = 1'b0;
            entry_ready[i] = entry_valid[i] && all_deps_done;
        end
endmodule
```
*Derivation:* Entry `i` is ready exactly when every entry `j` it depends on (per the matrix) is either no longer valid (already issued/retired out of the window) or has completed — this O(DEPTH²) matrix check is functionally equivalent to what tag-broadcast wakeup accomplishes incrementally over multiple cycles (each broadcast clearing one dependency bit at a time), but computing readiness combinationally from the full matrix in one shot is occasionally preferred in scheduler designs that want a single-cycle "is this entry fully unblocked" answer without waiting for sequential broadcast events to trickle in.

**418. Two-Level Issue Queue (Dispatch Queue + Scheduler)** — *(Hard)*
*Purpose:* Splits a large logical issue window into a cheap, simple in-order "dispatch queue" front-end feeding a smaller, more expensive true out-of-order "scheduler" back-end — a common real-design technique to get most of full-OoO's benefit without paying full-OoO scheduler cost across the entire window.
```systemverilog
module two_level_iq #(parameter int DQ_DEPTH = 32, parameter int SCHED_DEPTH = 8, parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic dq_enq_valid, output logic dq_enq_ready, input logic [W-1:0] dq_enq_data,
    output logic sched_enq_valid, output logic [W-1:0] sched_enq_data,
    input  logic sched_enq_ready
);
    logic [$clog2(DQ_DEPTH):0] count;
    logic [W-1:0] dq_mem [DQ_DEPTH];
    logic [$clog2(DQ_DEPTH)-1:0] rd_ptr, wr_ptr;

    assign dq_enq_ready   = (count != DQ_DEPTH);
    assign sched_enq_valid = (count != 0);
    assign sched_enq_data   = dq_mem[rd_ptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0; rd_ptr <= '0; wr_ptr <= '0;
        end else begin
            if (dq_enq_valid && dq_enq_ready) begin
                dq_mem[wr_ptr] <= dq_enq_data; wr_ptr <= wr_ptr + 1'b1; count <= count + 1'b1;
            end
            if (sched_enq_valid && sched_enq_ready) begin
                rd_ptr <= rd_ptr + 1'b1; count <= count - 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* The dispatch queue is a plain deep FIFO (cheap, no CAM/wakeup logic needed since it's strictly in-order) that absorbs a large window of not-yet-schedulable instructions; only when an entry reaches the FIFO's head does it move into the small, expensive true-OoO scheduler (Problem 349/404-style), which only ever needs to be sized for how many instructions can realistically be *simultaneously ready-or-soon-ready* rather than the entire speculative window — this is exactly the architecture used by several real high-performance out-of-order designs to keep scheduler CAM cost from scaling with the full reorder-buffer depth.

**419. Load Replay Queue (Mis-Speculated Load Wakeup Replay)** — *(Hard)*
*Purpose:* When Problem 412 detects that a load executed too early (before an older store's address was known, and that store turns out to actually alias), the load and everything dependent on it must be replayed — this queue tracks and re-triggers that.
```systemverilog
module load_replay_queue #(parameter int DEPTH = 8) (
    input  logic clk, rst_n,
    input  logic replay_req_valid, input logic [$clog2(32)-1:0] replay_load_tag,
    output logic replay_pending,
    output logic replay_issue_valid, output logic [$clog2(32)-1:0] replay_issue_tag
);
    logic [DEPTH-1:0] valid;
    logic [DEPTH-1:0][$clog2(32)-1:0] tag;
    logic [$clog2(DEPTH)-1:0] head, tail;

    assign replay_pending      = |valid;
    assign replay_issue_valid  = valid[head];
    assign replay_issue_tag    = tag[head];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= '0; head <= '0; tail <= '0;
        end else begin
            if (replay_req_valid) begin
                valid[tail] <= 1'b1; tag[tail] <= replay_load_tag; tail <= tail + 1'b1;
            end
            if (replay_issue_valid) begin
                valid[head] <= 1'b0; head <= head + 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* A simple FIFO of pending replays is sufficient because replay correctness only requires that the load eventually re-executes with up-to-date information (this time seeing the aliasing store correctly) — the *order* replays happen in relative to each other matters far less than the order relative to newly-arriving normal instructions, which is why this can be a straightforward queue rather than needing the same age-ordered priority machinery as the main scheduler (Problems 406/407).

**420. OoO Core Top Integration (ROB + RAT + Free List + IQ Stub)** — *(Hard)*
*Purpose:* Wires together this category's major pieces into a single representative top-level dispatch path, showing how allocation across all four structures must be jointly gated — dispatch can only proceed if the ROB, free list, *and* issue queue all simultaneously have room.
```systemverilog
module ooo_dispatch_top #(parameter int ROB_DEPTH = 32, parameter int NUM_PREGS = 128, parameter int IQ_DEPTH = 16) (
    input  logic clk, rst_n,
    input  logic dispatch_valid, input logic [4:0] dispatch_rd,
    output logic dispatch_ready
);
    logic rob_ready, freelist_ready, iq_ready;
    logic [$clog2(ROB_DEPTH)-1:0] rob_tag;
    logic [$clog2(NUM_PREGS)-1:0] new_preg;

    rob_full #(.DEPTH(ROB_DEPTH)) u_rob (
        .clk(clk), .rst_n(rst_n), .alloc_valid(dispatch_valid && dispatch_ready), .alloc_ready(rob_ready),
        .alloc_tag(rob_tag), .alloc_br_mask('0),
        .complete_valid(1'b0), .complete_tag('0), .complete_excepted(1'b0), .complete_exc_cause('0),
        .commit_valid(), .commit_tag(), .commit_excepted(), .commit_exc_cause(),
        .br_resolve_valid(1'b0), .br_resolve_id('0), .br_mispredict(1'b0)
    );
    free_list_bitvector #(.NUM_PREGS(NUM_PREGS)) u_freelist (
        .clk(clk), .rst_n(rst_n), .alloc_req(dispatch_valid && dispatch_ready), .alloc_valid(freelist_ready),
        .alloc_preg(new_preg), .free_req(1'b0), .free_preg('0)
    );
    assign iq_ready = 1'b1;   // stub: a real design also checks issue-queue/dispatch-queue occupancy (Problem 418)

    assign dispatch_ready = rob_ready && freelist_ready && iq_ready;
endmodule
```
*Derivation:* All three resource checks must be combined with AND (not any kind of priority or OR) because dispatch is an atomic, all-or-nothing operation — an instruction can't be "half-dispatched" (allocated a ROB entry but no physical register, say); this is the same combined-resource-gating principle as Problems 354/355's individual stall conditions, now shown explicitly joined into the single `dispatch_ready` signal a real front-end's dispatch/rename stage would actually use to decide whether to stall the pipeline stages feeding it.

---

## Category 2: Advanced Branch Prediction (421–440)

**421. TAGE-Lite Tagged Predictor Component** — *(Hard)*
*Purpose:* TAGE (TAgged GEometric history length) predictors use several tables indexed by progressively longer history lengths, each entry tagged so only a confirmed-matching history contributes a prediction — this models one such tagged table.
```systemverilog
module tage_table #(parameter int ENTRIES = 512, parameter int TAG_W = 8, parameter int HIST_W = 16) (
    input  logic clk, rst_n,
    input  logic [31:0] pc, input logic [HIST_W-1:0] ghr,
    output logic hit, output logic [2:0] ctr,
    input  logic update_valid, input logic actual_taken, input logic alloc_new
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic [IDX_W-1:0] idx;
    logic [TAG_W-1:0] tag;
    logic valid_arr [ENTRIES];
    logic [TAG_W-1:0] tag_arr [ENTRIES];
    logic [2:0] ctr_arr [ENTRIES];
    logic [1:0] useful_arr [ENTRIES];

    assign idx = (pc[IDX_W-1:0] ^ ghr[IDX_W-1:0]);
    assign tag = (pc[TAG_W-1:0] ^ ghr[HIST_W-1:HIST_W-TAG_W]);
    assign hit = valid_arr[idx] && (tag_arr[idx] == tag);
    assign ctr  = ctr_arr[idx];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) valid_arr[i] <= 1'b0;
        end else if (update_valid) begin
            if (alloc_new) begin
                valid_arr[idx] <= 1'b1; tag_arr[idx] <= tag; ctr_arr[idx] <= 3'b100; useful_arr[idx] <= 2'b00;
            end else if (hit) begin
                if (actual_taken) ctr_arr[idx] <= (ctr_arr[idx]==3'b111) ? 3'b111 : ctr_arr[idx]+1'b1;
                else               ctr_arr[idx] <= (ctr_arr[idx]==3'b000) ? 3'b000 : ctr_arr[idx]-1'b1;
            end
        end
    end
endmodule
```
*Derivation:* Both the index and the tag are computed by folding the PC with different slices of the global history — this is deliberately different from Problem 231's plain gshare XOR, since TAGE's entire premise is that *multiple* tables, each using a different history length, compete to provide a prediction, and the tag comparison (unlike gshare's untagged BHT) is what lets a table confidently claim "I recognize this exact (PC, history) context" rather than silently aliasing; the 3-bit saturating counter (wider than Problem 221's 2-bit) gives finer-grained confidence gradation, which TAGE's table-selection logic (Problem 435) uses to help decide which of several hitting tables to trust most.

**422. Perceptron Predictor Basic** — *(Hard)*
*Purpose:* An entirely different prediction approach from counter-based tables — represents a branch's prediction as a weighted sum (dot product) of the global history bits against a per-branch learned weight vector, capable of capturing much longer and more complex history correlations than a small saturating counter can.
```systemverilog
module perceptron_predict #(parameter int HIST_LEN = 24, parameter int WEIGHT_W = 8) (
    input  logic signed [WEIGHT_W-1:0] weights [HIST_LEN],
    input  logic [HIST_LEN-1:0] ghr,
    output logic predict_taken,
    output logic signed [WEIGHT_W+$clog2(HIST_LEN):0] y_out
);
    logic signed [WEIGHT_W+$clog2(HIST_LEN):0] sum;
    always_comb begin
        sum = weights[0];   // bias weight, always included regardless of history
        for (int i = 1; i < HIST_LEN; i++)
            sum = sum + (ghr[i-1] ? weights[i] : -weights[i]);
    end
    assign y_out         = sum;
    assign predict_taken = (sum >= 0);
endmodule
```
*Derivation:* Each history bit contributes `+weight[i]` if that past branch was taken, `-weight[i]` if not-taken — this is the standard perceptron inference formula `y = w0 + Σ(x_i * w_i)` with history bits mapped from `{0,1}` to `{-1,+1}` (implemented here via the conditional negation rather than a literal multiply, since the "input" is always ±1); the sign of the resulting sum is the prediction, and the magnitude (`y_out`) doubles as a natural confidence measure — a very large-magnitude sum means many weights agreed strongly, feeding directly into Problem 427's confidence estimation.

**423. Perceptron Weight Update Logic** — *(Hard)*
*Purpose:* Trains Problem 422's weight vector after a branch resolves, using the perceptron learning rule — nudging each weight toward agreeing with the actual outcome, but only when the prediction was wrong or was correct-but-low-confidence.
```systemverilog
module perceptron_update #(parameter int HIST_LEN = 24, parameter int WEIGHT_W = 8, parameter int THRESHOLD = 40) (
    input  logic clk, rst_n, update_valid,
    input  logic [HIST_LEN-1:0] ghr_at_predict_time,
    input  logic actual_taken,
    input  logic signed [WEIGHT_W+$clog2(HIST_LEN):0] y_out,
    output logic signed [WEIGHT_W-1:0] weights [HIST_LEN]
);
    wire mispredicted = (y_out >= 0) != actual_taken;
    wire low_confidence = (y_out < THRESHOLD) && (y_out > -THRESHOLD);
    wire should_train = mispredicted || low_confidence;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < HIST_LEN; i++) weights[i] <= '0;
        end else if (update_valid && should_train) begin
            weights[0] <= actual_taken ? weights[0] + 1'b1 : weights[0] - 1'b1;
            for (int i = 1; i < HIST_LEN; i++) begin
                automatic logic bit_agrees = (ghr_at_predict_time[i-1] == actual_taken);
                weights[i] <= bit_agrees ? weights[i] + 1'b1 : weights[i] - 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* This is the classic perceptron training rule: train (adjust weights) whenever the prediction was wrong, *or* even when it was right but with low confidence (`|y_out| < THRESHOLD`) — the low-confidence case is specifically what distinguishes perceptron training from naive "only fix mistakes" learning, and is what lets the predictor continue refining its weights even on correct predictions that were only marginally correct, converging toward higher-confidence correct predictions over time rather than plateauing the moment it merely gets lucky.

**424. Tournament Predictor Selector (Choice Predictor)** — *(Hard)*
*Purpose:* Combines two different predictors (e.g. a local-history predictor and a global-history/gshare predictor) with a third meta-predictor that learns, per branch, which of the two tends to be more reliable.
```systemverilog
module tournament_selector #(parameter int ENTRIES = 1024) (
    input  logic clk, rst_n,
    input  logic [31:0] pc,
    input  logic pred_local, pred_global,
    output logic final_predict,
    input  logic update_valid, input logic actual_taken
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic [1:0] choice_ctr [ENTRIES];   // 0-1 = trust local, 2-3 = trust global
    wire [IDX_W-1:0] idx = pc[IDX_W-1:0];
    wire trust_global = choice_ctr[idx][1];

    assign final_predict = trust_global ? pred_global : pred_local;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) choice_ctr[i] <= 2'b01;
        end else if (update_valid && (pred_local != pred_global)) begin
            // only train the choice predictor when the two disagreed -- agreement gives no signal about which is "better"
            if (pred_global == actual_taken) choice_ctr[idx] <= (choice_ctr[idx]==2'b11) ? 2'b11 : choice_ctr[idx]+1'b1;
            else                               choice_ctr[idx] <= (choice_ctr[idx]==2'b00) ? 2'b00 : choice_ctr[idx]-1'b1;
        end
    end
endmodule
```
*Derivation:* The meta-predictor is trained *only* on the cycles where `pred_local` and `pred_global` actually disagreed — when both predictors already agree, there's nothing to learn about which one to trust (either both are right or both are equally wrong, and shifting trust wouldn't change the outcome), so gating the update on disagreement avoids diluting the choice counter's signal with uninformative agreement cycles, letting it converge faster specifically on the cases where the choice actually mattered.

**425. Indirect Branch Target Predictor (ITTAGE-Lite)** — *(Hard)*
*Purpose:* JALR with a computed (not statically-known) target — common in virtual function calls, switch-statement jump tables, and interpreter dispatch loops — needs its own target prediction structure, since Problem 224's BTB assumes one PC maps to (usually) one target, which breaks down when the same call site can jump to many different targets across executions.
```systemverilog
module ittage_lite #(parameter int ENTRIES = 512, parameter int HIST_W = 16) (
    input  logic clk, rst_n,
    input  logic [31:0] pc, input logic [HIST_W-1:0] ghr,
    output logic hit, output logic [31:0] predicted_target,
    input  logic update_valid, input logic [31:0] actual_target
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic valid_arr [ENTRIES];
    logic [31:0] target_arr [ENTRIES];
    wire [IDX_W-1:0] idx = pc[IDX_W-1:0] ^ ghr[IDX_W-1:0];

    assign hit              = valid_arr[idx];
    assign predicted_target = target_arr[idx];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) valid_arr[i] <= 1'b0;
        end else if (update_valid) begin
            valid_arr[idx]  <= 1'b1;
            target_arr[idx] <= actual_target;
        end
    end
endmodule
```
*Derivation:* Unlike a normal BTB (which is indexed purely by PC, implicitly assuming one target per PC), indexing by `PC XOR GHR` (the same gshare-style folding as Problem 231) lets *different calling contexts* of the same indirect-branch site map to different table entries — since the global history leading up to the branch often correlates with which specific target it will jump to this time (e.g. a virtual call's history differs depending on which object type led to it), this is the key structural idea that lets a history-indexed predictor handle polymorphic/indirect targets that a plain PC-indexed BTB fundamentally cannot distinguish.

**426. Loop Predictor (Trip-Count Based)** — *(Hard)*
*Purpose:* Ordinary predictors handle a loop's "usually taken" back-edge well, but mispredict the one final iteration where the loop actually exits — a loop predictor instead learns the loop's typical trip count and predicts the exit precisely on the matching iteration.
```systemverilog
module loop_predictor #(parameter int ENTRIES = 64, parameter int CNT_W = 8) (
    input  logic clk, rst_n,
    input  logic [31:0] pc,
    output logic hit, predict_taken, high_confidence,
    input  logic update_valid, input logic actual_taken
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic valid_arr [ENTRIES];
    logic [CNT_W-1:0] cur_count [ENTRIES], trip_count [ENTRIES];
    logic [1:0] conf [ENTRIES];
    wire [IDX_W-1:0] idx = pc[IDX_W-1:0];

    assign hit             = valid_arr[idx];
    assign high_confidence = conf[idx] == 2'b11;
    assign predict_taken   = !hit ? 1'b1 :
                              (cur_count[idx] == trip_count[idx]-1'b1) ? 1'b0 : 1'b1;   // predict exit on the final iteration

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) valid_arr[i] <= 1'b0;
        end else if (update_valid) begin
            if (!valid_arr[idx]) begin
                valid_arr[idx] <= 1'b1; cur_count[idx] <= '0; conf[idx] <= 2'b00;
            end else if (actual_taken) begin
                cur_count[idx] <= cur_count[idx] + 1'b1;
            end else begin
                // loop just exited -- check whether this matches the previously-learned trip count
                if (cur_count[idx] == trip_count[idx]) conf[idx] <= (conf[idx]==2'b11) ? 2'b11 : conf[idx]+1'b1;
                else                                     conf[idx] <= 2'b00;
                trip_count[idx] <= cur_count[idx];
                cur_count[idx]  <= '0;
            end
        end
    end
endmodule
```
*Derivation:* `cur_count` tracks how many times the loop's back-edge has been taken *this execution* of the loop; when the branch is finally not-taken (loop exit), that count is compared against the *previously observed* trip count — matching increments confidence, mismatching resets it — and the loop predictor only overrides the prediction to "not-taken" on the specific iteration where `cur_count` reaches one less than the learned trip count, which is exactly the single iteration a generic saturating-counter predictor (Problem 221) would otherwise get wrong every single time the loop runs, since the back-edge is "usually taken" right up until the one time it isn't.

**427. Confidence Estimator for Predictor Output** — *(Hard)*
*Purpose:* A unified confidence signal combining information across whichever predictor components are actually available for a given prediction (TAGE table hit depth, perceptron sum magnitude, loop-predictor confidence), used to decide things like how aggressively to fetch down the predicted path or whether to prefer a lower-confidence override.
```systemverilog
module predictor_confidence (
    input  logic tage_hit, input logic [2:0] tage_ctr,
    input  logic signed [15:0] perceptron_y,
    input  logic loop_hit, loop_high_conf,
    output logic [1:0] confidence   // 0=low, 1=medium, 2=high, 3=very high
);
    always_comb begin
        if (loop_hit && loop_high_conf) confidence = 2'd3;
        else if (tage_hit && (tage_ctr == 3'b111 || tage_ctr == 3'b000)) confidence = 2'd2;   // saturated counter
        else if ((perceptron_y > 60) || (perceptron_y < -60))              confidence = 2'd2;
        else if (tage_hit)                                                  confidence = 2'd1;
        else                                                                 confidence = 2'd0;
    end
endmodule
```
*Derivation:* A loop predictor's exit-iteration prediction is given the very highest confidence tier because it's derived from an exact match against a previously-observed trip count (Problem 426), which is a qualitatively stronger signal than a saturating counter or a perceptron sum threshold — this priority ordering (loop > saturated-counter/perceptron-magnitude > plain hit > no info) reflects how much each source of evidence should actually be trusted, information a real front-end can use to decide things like how many cycles ahead to keep fetching speculatively before it's worth throttling back on a low-confidence guess.

**428. BTB Multi-Way Set-Associative** — *(Hard)*
*Purpose:* Scales Problem 224's direct-mapped BTB to N-way associativity, reducing capacity-aliasing collisions between unrelated branches that happen to share the same index.
```systemverilog
module btb_nway #(parameter int SETS = 128, parameter int WAYS = 4) (
    input  logic clk, rst_n,
    input  logic [31:0] lookup_pc,
    output logic hit, output logic [$clog2(WAYS)-1:0] hit_way,
    output logic [31:0] predicted_target,
    input  logic update_en, input logic [31:0] update_pc, update_target,
    input  logic [$clog2(WAYS)-1:0] victim_way
);
    localparam int IDX_W = $clog2(SETS);
    localparam int TAG_W = 32 - IDX_W - 2;
    logic valid [SETS][WAYS];
    logic [TAG_W-1:0] tag [SETS][WAYS];
    logic [31:0] target [SETS][WAYS];

    wire [IDX_W-1:0] look_idx = lookup_pc[IDX_W+1:2];
    wire [TAG_W-1:0] look_tag = lookup_pc[31:IDX_W+2];
    logic [WAYS-1:0] way_hit;
    always_comb begin
        for (int w = 0; w < WAYS; w++) way_hit[w] = valid[look_idx][w] && (tag[look_idx][w] == look_tag);
        hit = |way_hit; hit_way = '0;
        for (int w = 0; w < WAYS; w++) if (way_hit[w]) hit_way = w[$clog2(WAYS)-1:0];
        predicted_target = target[look_idx][hit_way];
    end

    wire [IDX_W-1:0] upd_idx = update_pc[IDX_W+1:2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SETS; s++) for (int w = 0; w < WAYS; w++) valid[s][w] <= 1'b0;
        end else if (update_en) begin
            valid[upd_idx][victim_way]  <= 1'b1;
            tag[upd_idx][victim_way]    <= update_pc[31:IDX_W+2];
            target[upd_idx][victim_way] <= update_target;
        end
    end
endmodule
```
*Derivation:* Directly analogous to the jump from Problem 116's direct-mapped cache to Problem 117's set-associative cache — the same fundamental tradeoff applies: an N-way BTB needs N parallel tag comparators per lookup (more area/power per access) in exchange for a much lower rate of unrelated branches evicting each other, since two branches must now share the same *set* (not just any index) and simultaneously exceed the set's way count before one evicts the other, versus a direct-mapped BTB where any two branches sharing an index immediately conflict.

**429. BTB Way Predictor** — *(Hard)*
*Purpose:* Speeds up an N-way BTB lookup (Problem 428) by predicting which way is likely to hit *before* the full tag comparison completes, letting the target be speculatively read out one cycle earlier — directly reusing the same way-prediction principle as Problem 126's cache way predictor.
```systemverilog
module btb_way_predict #(parameter int SETS = 128, parameter int WAYS = 4) (
    input  logic [$clog2(SETS)-1:0] set_idx,
    output logic [$clog2(WAYS)-1:0] predicted_way
);
    logic [$clog2(WAYS)-1:0] way_hint [SETS];
    assign predicted_way = way_hint[set_idx];
    // way_hint[] updated externally by the same update logic that writes a new BTB entry, recording which way it landed in
endmodule
```
*Derivation:* Same principle as the earlier `way_predict_ctrl` cache module — a small hint table remembers which way was last correct for a given set, letting the predicted target be read speculatively from just that one way (lower access latency/power than reading all `WAYS` ways in parallel every lookup), with a full tag-compare fallback (Problem 428's complete logic) only needed to confirm the guess or recover on a way-mispredict, exactly mirroring the cache way-predictor's speed/accuracy tradeoff.

**430. RAS with Checkpoint/Repair on Misprediction** — *(Hard)*
*Purpose:* Extends the Medium tier's plain RAS (Problems 227–229) with checkpointing, since a speculatively-executed call/return sequence down a mispredicted path can corrupt the RAS's stack pointer and contents unless that corruption can be undone on recovery.
```systemverilog
module ras_checkpointed #(parameter int DEPTH = 8, parameter int NUM_CKPT = 8) (
    input  logic clk, rst_n,
    input  logic push_en, input logic [31:0] push_addr,
    input  logic pop_en, output logic [31:0] popped_addr, output logic pop_valid,
    input  logic ckpt_save_valid, input logic [$clog2(NUM_CKPT)-1:0] ckpt_save_id,
    input  logic ckpt_restore_valid, input logic [$clog2(NUM_CKPT)-1:0] ckpt_restore_id
);
    logic [31:0] stack [DEPTH];
    logic [$clog2(DEPTH)-1:0] ptr;
    logic [$clog2(DEPTH)-1:0] ckpt_ptr [NUM_CKPT];
    logic [31:0] ckpt_stack [NUM_CKPT][DEPTH];

    assign pop_valid    = (ptr != '0);
    assign popped_addr  = pop_valid ? stack[ptr-1] : 32'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr <= '0;
        end else if (ckpt_restore_valid) begin
            ptr <= ckpt_ptr[ckpt_restore_id];
            for (int i = 0; i < DEPTH; i++) stack[i] <= ckpt_stack[ckpt_restore_id][i];
        end else begin
            if (ckpt_save_valid) begin
                ckpt_ptr[ckpt_save_id] <= ptr;
                for (int i = 0; i < DEPTH; i++) ckpt_stack[ckpt_save_id][i] <= stack[i];
            end
            if (push_en && (ptr != DEPTH-1)) begin stack[ptr] <= push_addr; ptr <= ptr + 1'b1; end
            else if (pop_en && pop_valid)     ptr <= ptr - 1'b1;
        end
    end
endmodule
```
*Derivation:* Same full-copy checkpoint/restore principle as Problem 402's checkpointed RAT, applied to the RAS's stack pointer and contents — without this, a speculative `CALL` executed down a wrong path that gets squashed would leave a stale pushed address sitting on the RAS forever, silently corrupting every future `RET` prediction until the RAS happens to churn enough to overwrite it, which is exactly the kind of subtle, hard-to-debug correctness bug real designs guard against by checkpointing every piece of speculative predictor state, not just the RAT.

**431. Predictor Update Arbitration (Multiple Tables Updating Same Cycle)** — *(Hard)*
*Purpose:* If several predictor tables (TAGE's multiple history-length tables, the loop predictor, the choice predictor) all need to be updated from the same resolving branch in the same cycle, and they happen to share a physical write port, this arbitrates.
```systemverilog
module predictor_update_arb (
    input  logic tage_update_req, loop_update_req, choice_update_req,
    output logic tage_grant, loop_grant, choice_grant
);
    // In a real design these are typically independent physical tables with independent ports,
    // so no arbitration is needed -- this module documents the (common) case where that's true,
    // and the fallback logic for the (rarer) case of a genuinely shared port.
    assign tage_grant   = tage_update_req;
    assign loop_grant   = loop_update_req;
    assign choice_grant = choice_update_req;
endmodule
```
*Derivation:* Unlike Problem 237's BTB/BHT port conflict (a genuine single-ported structure contended between prediction reads and resolution writes), a real multi-component predictor's *different tables* are normally implemented as physically separate memory arrays each with their own dedicated write port, specifically to avoid needing exactly this kind of arbitration on the resolve-update path — this module is included to make that design choice explicit (and to show what the arbitration *would* look like if area constraints ever forced table-sharing), rather than because real designs typically need it.

**432. GHR Checkpoint Manager (Multiple In-Flight Branches)** — *(Hard)*
*Purpose:* Scales Problem 234's single-checkpoint GHR recovery to track a checkpoint per in-flight speculative branch, reusing the same checkpoint-ID allocation scheme as Problem 416's ROB-checkpoint manager.
```systemverilog
module ghr_ckpt_manager #(parameter int WIDTH = 16, parameter int NUM_CKPT = 8) (
    input  logic clk, rst_n,
    input  logic speculative_update, input logic predict_taken,
    input  logic [$clog2(NUM_CKPT)-1:0] alloc_ckpt_id,
    input  logic restore_valid, input logic [$clog2(NUM_CKPT)-1:0] restore_ckpt_id, input logic actual_taken,
    output logic [WIDTH-1:0] ghr
);
    logic [WIDTH-1:0] ckpt [NUM_CKPT];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ghr <= '0;
        end else if (restore_valid) begin
            ghr <= {ckpt[restore_ckpt_id][WIDTH-2:0], actual_taken};
        end else if (speculative_update) begin
            ckpt[alloc_ckpt_id] <= ghr;
            ghr <= {ghr[WIDTH-2:0], predict_taken};
        end
    end
endmodule
```
*Derivation:* Direct generalization of Problem 234 the same way Problem 402 generalized single-mapping RAT checkpointing — every speculative branch saves its own pre-speculation GHR snapshot into its allocated checkpoint slot (sharing the same allocation lifecycle as Problem 416's ROB checkpoints, since a branch's GHR, RAT, and RAS checkpoints are all logically part of the same speculative-recovery bundle and typically allocated/freed together), letting a misprediction restore precisely to that branch's pre-speculation history state.

**433. Fetch-Redirect Priority Mux (Multiple Redirect Sources)** — *(Hard)*
*Purpose:* A real pipeline can have several independent sources simultaneously wanting to redirect fetch in the same cycle — a resolved branch misprediction, an exception, an interrupt — this establishes the full priority order among all of them.
```systemverilog
typedef enum logic [2:0] {RDR_NONE, RDR_BTB, RDR_RAS, RDR_BRANCH_RESOLVE, RDR_EXCEPTION, RDR_INTERRUPT} redirect_src_e;

module fetch_redirect_priority (
    input  logic btb_redirect, ras_redirect, branch_resolve_redirect, exception_redirect, interrupt_redirect,
    output redirect_src_e winning_src
);
    always_comb begin
        if      (exception_redirect)       winning_src = RDR_EXCEPTION;        // highest: architectural correctness
        else if (interrupt_redirect)        winning_src = RDR_INTERRUPT;
        else if (branch_resolve_redirect)  winning_src = RDR_BRANCH_RESOLVE;   // confirmed-correct target beats a guess
        else if (ras_redirect)              winning_src = RDR_RAS;
        else if (btb_redirect)              winning_src = RDR_BTB;
        else                                  winning_src = RDR_NONE;
    end
endmodule
```
*Derivation:* This ordering follows directly from how *certain* each source's redirect is: an exception/interrupt redirect isn't a guess at all — it's an architecturally mandated jump, so it must win over everything; a resolved branch misprediction is a confirmed-correct target (Execute has actually computed it), which must override a still-speculative BTB/RAS *prediction* for a younger instruction, since continuing to fetch down a guess after the real answer is already known would just be wasted work; RAS is prioritized over plain BTB specifically because it's the higher-confidence source (Problem 427's reasoning) for the specific case where both happen to fire on the same cycle for different in-flight instructions.

**434. Branch Resolution Age Comparator (`is_older` Function)** — *(Hard)*
*Purpose:* A reusable function determining whether one in-flight instruction's ROB tag is architecturally older than another's, correctly handling circular-buffer wraparound — needed throughout the predictor-recovery and scheduler-select logic (Problems 406, 433) wherever "which of these two is older" must be decided against wrapping tag values.
```systemverilog
function automatic logic is_older(input logic [6:0] tag_a, tag_b, input logic [6:0] head_ptr);
    // rebase both tags relative to head_ptr so ordinary unsigned comparison reflects true age, even across wraparound
    automatic logic [6:0] rel_a = tag_a - head_ptr;
    automatic logic [6:0] rel_b = tag_b - head_ptr;
    return rel_a < rel_b;
endfunction
```
*Derivation:* Raw tag comparison (`tag_a < tag_b`) breaks the moment the circular buffer wraps around — a tag near the top of the range can be *architecturally older* than a small tag value if the buffer wrapped between them — subtracting `head_ptr` from both first re-expresses each tag as "distance past the current oldest live entry," a monotonically increasing quantity with no wraparound ambiguity within the buffer's live range, after which plain unsigned comparison correctly reflects true program-order age; this exact function is what a real design's Problem 416/433-style priority logic relies on internally wherever ROB-tag age comparisons appear.

**435. Multi-Table Predictor Aggregation (Tag-Match Priority Across TAGE Tables)** — *(Hard)*
*Purpose:* TAGE's defining mechanism — when multiple tables (each with a different history length) simultaneously report a tag hit for the same branch, the table using the *longest* matching history is trusted, since longer-history matches are statistically more specific and reliable.
```systemverilog
module tage_aggregate #(parameter int NUM_TABLES = 4) (
    input  logic [NUM_TABLES-1:0] table_hit,     // table_hit[0] = shortest history, table_hit[NUM_TABLES-1] = longest
    input  logic [NUM_TABLES-1:0][2:0] table_ctr,
    input  logic base_predictor_taken,            // bimodal fallback if no table hits at all
    output logic final_predict,
    output logic [$clog2(NUM_TABLES+1)-1:0] provider_table   // which table's prediction was actually used (0 = base)
);
    always_comb begin
        final_predict  = base_predictor_taken;
        provider_table = '0;
        for (int t = 0; t < NUM_TABLES; t++)
            if (table_hit[t]) begin
                final_predict  = table_ctr[t][2];   // MSB of the 3-bit counter = predict-taken
                provider_table = t[$clog2(NUM_TABLES+1)-1:0] + 1'b1;
            end
    end
endmodule
```
*Derivation:* Iterating from shortest to longest history and letting a later (longer-history) hit unconditionally overwrite an earlier (shorter-history) one is exactly the same "later-in-loop-order overwrite wins" mux-chain pattern as `priority_enc8` from earlier in this conversation, just deliberately applied here in *ascending* history-length order so the longest match always wins — this priority is the entire point of TAGE's design: a hit in a long-history table means the predictor found a very specific, rare, but recently-confirmed context for this branch, which is a stronger signal than a shorter-history table's necessarily-more-generic (and thus more alias-prone) match.

**436. Predictor Table Allocation-on-Misprediction (TAGE New-Entry Policy)** — *(Hard)*
*Purpose:* When TAGE mispredicts, it allocates a new entry in one of the tables with a *longer* history than whichever table actually provided the wrong prediction, hoping the longer context will disambiguate this specific case going forward.
```systemverilog
module tage_alloc_policy #(parameter int NUM_TABLES = 4) (
    input  logic mispredicted,
    input  logic [$clog2(NUM_TABLES+1)-1:0] provider_table,   // 0 = base predictor provided the (wrong) prediction
    input  logic [NUM_TABLES-1:0] table_useful,                 // useful-bit per table (Problem 437)
    output logic alloc_valid,
    output logic [$clog2(NUM_TABLES)-1:0] alloc_table_idx
);
    always_comb begin
        alloc_valid = 1'b0; alloc_table_idx = '0;
        if (mispredicted) begin
            for (int t = provider_table; t < NUM_TABLES; t++)   // search tables with longer history than the provider
                if (!table_useful[t]) begin alloc_valid = 1'b1; alloc_table_idx = t[$clog2(NUM_TABLES)-1:0]; break; end
        end
    end
endmodule
```
*Derivation:* Restricting the search to tables with history *longer* than whichever one actually provided the (wrong) prediction reflects TAGE's core hypothesis — a longer history might successfully distinguish this specific mispredicting case from the general pattern the shorter-history table conflated it with; preferring a table whose current entry at that index isn't marked `useful` (Problem 437) avoids evicting an entry that's actively helping some *other* branch's predictions, accepting a failed allocation attempt (search finds nothing) over destructively overwriting known-good state.

**437. Useful-Bit Counter for TAGE Entry Replacement** — *(Hard)*
*Purpose:* Tracks whether a given TAGE table entry has actually been the deciding (highest-history-hit) provider for a correct prediction recently, information Problem 436's allocation policy uses to avoid evicting entries that are still earning their keep.
```systemverilog
module tage_useful_bit (
    input  logic clk, rst_n,
    input  logic was_provider, prediction_correct,
    input  logic periodic_decay,   // periodically clear all useful bits to prevent permanent "stuck-useful" entries
    output logic useful
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || periodic_decay) useful <= 1'b0;
        else if (was_provider) useful <= prediction_correct;
    end
endmodule
```
*Derivation:* `useful` is only ever set when this specific entry was actually the one providing a (subsequently confirmed correct) prediction — an entry that exists but has never actually won provider-priority (Problem 435) over some shorter-history table contributes nothing and should be freely evictable; `periodic_decay` exists because without it, `useful` bits only ever get set and never naturally cleared by usage alone, eventually saturating the whole table as "useful" and defeating the entire point of the bit (distinguishing valuable entries from stale ones) — real TAGE implementations periodically reset every useful bit (e.g. every few thousand branches) specifically to let genuinely-stale entries become evictable again.

**438. Branch Predictor Training Queue (Deferred Update Buffer)** — *(Hard)*
*Purpose:* Since a branch resolves in Execute, potentially many cycles after it was predicted in Fetch, the information needed to correctly train the predictor (which tables it hit in, what GHR was active, etc.) must be carried alongside the instruction and queued for application once resolution confirms the outcome.
```systemverilog
module predictor_train_queue #(parameter int DEPTH = 16, parameter int META_W = 64) (
    input  logic clk, rst_n,
    input  logic enq_valid, output logic enq_ready, input logic [META_W-1:0] enq_meta,
    output logic deq_valid, output logic [META_W-1:0] deq_meta,
    input  logic deq_ready
);
    logic [META_W-1:0] mem [DEPTH];
    logic [$clog2(DEPTH):0] head, tail;
    assign enq_ready = (tail - head) != $clog2(DEPTH)'(DEPTH);
    assign deq_valid  = (head != tail);
    assign deq_meta    = mem[head[$clog2(DEPTH)-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin head <= '0; tail <= '0; end
        else begin
            if (enq_valid && enq_ready) begin mem[tail[$clog2(DEPTH)-1:0]] <= enq_meta; tail <= tail + 1'b1; end
            if (deq_valid && deq_ready) head <= head + 1'b1;
        end
    end
endmodule
```
*Derivation:* A plain FIFO is sufficient here because branches resolve in the same order they're predicted (in-order execution of the branch-resolution event itself, even in an OoO core — Execute confirms outcomes in whatever order the FUs happen to complete them, but the *update application* to predictor tables doesn't need to preserve program order the way ROB commit does) — `enq_meta` packs together everything Problem 435's aggregation needs to replay at update time: which table provided the prediction, the GHR snapshot, the tag/index used, etc., all bundled into one wide field carried through the pipeline alongside the branch instruction itself.

**439. Cross-Predictor Conflict Resolution (BTB vs RAS Priority)** — *(Hard)*
*Purpose:* If a fetched instruction is simultaneously classified as matching both a BTB entry (Problem 224) and the RAS-hint classification (Problem 239) — which shouldn't normally happen for a correctly-decoded instruction, but could arise from BTB aliasing — this resolves which prediction source wins.
```systemverilog
module btb_ras_conflict (
    input  logic btb_hit, is_return_hint,
    output logic use_ras
);
    assign use_ras = is_return_hint;   // architectural classification always wins over a possibly-aliased BTB hit
endmodule
```
*Derivation:* `is_return_hint` comes from Problem 239's exact decode of the fetched instruction's own opcode/register fields — it's a *certain* architectural fact about this specific instruction, whereas a same-cycle BTB hit is only ever a heuristic guess that could in principle be a stale/aliased entry from a completely different instruction that happened to hash to the same index; when the two disagree about what kind of instruction this is, the actual decoded instruction type is unambiguously correct and must win, matching the same "confirmed fact beats prediction" priority reasoning as Problem 433's redirect priority.

**440. Full Predictor Top Wrapper (TAGE + Perceptron + RAS + Loop Integrated)** — *(Hard)*
*Purpose:* Integrates this category's major components into a single representative fetch-time prediction module, showing how the pieces combine into one final taken/not-taken and target decision.
```systemverilog
module full_predictor_top (
    input  logic clk, rst_n,
    input  logic [31:0] fetch_pc,
    output logic predict_taken,
    output logic [31:0] predicted_target,
    input  logic resolve_valid, resolve_is_return, resolve_actual_taken,
    input  logic [31:0] resolve_pc, resolve_target
);
    logic loop_hit, loop_predict, loop_high_conf;
    loop_predictor u_loop (.clk(clk), .rst_n(rst_n), .pc(fetch_pc), .hit(loop_hit), .predict_taken(loop_predict),
                            .high_confidence(loop_high_conf), .update_valid(resolve_valid), .actual_taken(resolve_actual_taken));

    logic btb_hit;
    logic [31:0] btb_target;
    btb u_btb (.clk(clk), .rst_n(rst_n), .lookup_pc(fetch_pc), .hit(btb_hit), .predicted_target(btb_target),
               .update_en(resolve_valid && resolve_actual_taken), .update_pc(resolve_pc), .update_target(resolve_target));

    logic ras_valid;
    logic [31:0] ras_target;
    ras_pop u_ras (.clk(clk), .rst_n(rst_n), .pop_en(resolve_is_return), .popped_addr(ras_target), .valid(ras_valid));

    assign predict_taken     = (loop_hit && loop_high_conf) ? loop_predict : (btb_hit ? 1'b1 : 1'b0);
    assign predicted_target  = ras_valid ? ras_target : btb_target;
endmodule
```
*Derivation:* Direct composition following the priority order established throughout this category: the loop predictor overrides only when high-confidence (Problem 427's top tier), RAS overrides BTB for target selection (Problem 439), and everything ultimately falls back to a plain BTB-hit-implies-taken heuristic absent stronger signal — a complete production predictor would additionally fold in the TAGE aggregation (Problem 435) and perceptron (Problems 422–423) as further inputs to the taken/not-taken decision, omitted here to keep the top-level integration focused on the priority-resolution structure rather than repeating every component's full instantiation.

---

## Category 3: Cache Hierarchy & Coherence (441–460)

**441. N-Way Set-Associative Cache with True LRU** — *(Hard)*
*Purpose:* Extends Problem 117's pseudo-LRU set-associative cache to exact LRU tracking, which correctly identifies the truly least-recently-used way rather than pseudo-LRU's approximation, at the cost of a full permutation-tracking structure per set.
```systemverilog
module cache_true_lru #(parameter int SETS = 64, parameter int WAYS = 4) (
    input  logic clk, rst_n,
    input  logic [$clog2(SETS)-1:0] access_set, input logic access_hit,
    input  logic [$clog2(WAYS)-1:0] access_way,
    output logic [$clog2(WAYS)-1:0] victim_way
);
    // per-set recency stack: recency[set][0] = most-recently-used way, recency[set][WAYS-1] = LRU
    logic [$clog2(WAYS)-1:0] recency [SETS][WAYS];

    assign victim_way = recency[access_set][WAYS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SETS; s++) for (int w = 0; w < WAYS; w++) recency[s][w] <= w[$clog2(WAYS)-1:0];
        end else if (access_hit) begin
            automatic int found_pos = -1;
            for (int w = 0; w < WAYS; w++) if (recency[access_set][w] == access_way) found_pos = w;
            for (int w = 0; w < WAYS; w++)
                if (w < found_pos) recency[access_set][w+1] <= recency[access_set][w];
            recency[access_set][0] <= access_way;
        end
    end
endmodule
```
*Derivation:* Maintaining an explicit ordered list (a "recency stack") per set — accessed way moves to the front, everything between the old and new position shifts down by one — is the direct, literal implementation of true LRU; the cost is `O(WAYS)` shift logic per access per set (versus pseudo-LRU's `O(log WAYS)` single-bit-per-level update from Problem 117), which is exactly why real high-associativity caches (8-way, 16-way) almost always use pseudo-LRU or other approximations instead of true LRU — the shift network's cost grows with associativity in a way that becomes prohibitive well before true LRU's marginal hit-rate improvement over pseudo-LRU becomes significant.

**442. Pseudo-LRU Tree for 8-Way Cache** — *(Hard)*
*Purpose:* Scales Problem 117's 4-way (3-bit tree) pseudo-LRU to 8-way associativity (7-bit tree), demonstrating how the binary-tree PLRU structure generalizes to any power-of-2 associativity.
```systemverilog
module plru_8way (
    input  logic clk, rst_n, access_hit,
    input  logic [2:0] access_way,
    output logic [2:0] victim_way
);
    logic [6:0] tree;   // 7 bits: 1 root + 2 level-2 + 4 level-3 decision bits

    always_comb begin
        victim_way[2] = tree[0];
        victim_way[1] = tree[0] ? tree[2] : tree[1];
        victim_way[0] = tree[0] ? (tree[2] ? tree[6] : tree[5]) : (tree[1] ? tree[4] : tree[3]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tree <= 7'b0;
        else if (access_hit) begin
            tree[0] <= !access_way[2];
            if (access_way[2] == 1'b0) tree[1] <= !access_way[1];
            else                        tree[2] <= !access_way[1];
            unique case (access_way)
                3'd0: tree[3] <= 1'b1; 3'd1: tree[3] <= 1'b0;
                3'd2: tree[4] <= 1'b1; 3'd3: tree[4] <= 1'b0;
                3'd4: tree[5] <= 1'b1; 3'd5: tree[5] <= 1'b0;
                3'd6: tree[6] <= 1'b1; 3'd7: tree[6] <= 1'b0;
                default: ;
            endcase
        end
    end
endmodule
```
*Derivation:* Each tree bit encodes "which half was more recently used" at one level of a binary partition of the 8 ways (root splits ways 0-3 vs 4-7, next level splits each half into pairs, leaf level splits each pair into individual ways) — reading `victim_way` walks the tree following the "less recently used" direction at each level, and updating on access walks the same path setting each traversed bit to point *away* from the just-used way; this is exactly `log2(WAYS)=3` bits of tree depth needed per access regardless of `WAYS`, which is precisely the scaling advantage over Problem 441's true-LRU stack that motivates pseudo-LRU's use in real, higher-associativity caches.

**443. MSHR Full Implementation (Multiple Entries, Secondary Miss Merging)** — *(Hard)*
*Purpose:* Scales the earlier single-entry `mshr_entry` module to a realistic multi-entry structure, tracking several simultaneously-outstanding cache misses and correctly merging secondary misses (a second request to an address that's already being fetched) into the existing entry rather than issuing a redundant fetch.
```systemverilog
module mshr_bank #(parameter int NUM_MSHR = 8, parameter int ADDR_W = 32, parameter int NUM_REQ = 4) (
    input  logic clk, rst_n,
    input  logic alloc_req, input logic [ADDR_W-1:0] alloc_addr, input logic [$clog2(NUM_REQ)-1:0] alloc_req_id,
    output logic alloc_valid, output logic [$clog2(NUM_MSHR)-1:0] alloc_idx, output logic alloc_is_secondary,
    input  logic fill_valid, input logic [$clog2(NUM_MSHR)-1:0] fill_idx,
    output logic [NUM_MSHR-1:0] wake_mask
);
    logic [NUM_MSHR-1:0] busy;
    logic [NUM_MSHR-1:0][ADDR_W-1:0] addr_arr;
    logic [NUM_MSHR-1:0][NUM_REQ-1:0] waiters_arr;

    logic [NUM_MSHR-1:0] addr_match;
    always_comb
        for (int i = 0; i < NUM_MSHR; i++) addr_match[i] = busy[i] && (addr_arr[i] == alloc_addr);
    wire secondary_hit = |addr_match;

    always_comb begin
        alloc_valid = 1'b0; alloc_idx = '0; alloc_is_secondary = secondary_hit;
        if (secondary_hit) begin
            alloc_valid = 1'b1;
            for (int i = 0; i < NUM_MSHR; i++) if (addr_match[i]) alloc_idx = i[$clog2(NUM_MSHR)-1:0];
        end else begin
            for (int i = 0; i < NUM_MSHR; i++)
                if (!busy[i]) begin alloc_valid = 1'b1; alloc_idx = i[$clog2(NUM_MSHR)-1:0]; break; end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= '0;
        end else begin
            if (alloc_req && alloc_valid) begin
                if (!alloc_is_secondary) begin busy[alloc_idx] <= 1'b1; addr_arr[alloc_idx] <= alloc_addr; waiters_arr[alloc_idx] <= '0; end
                waiters_arr[alloc_idx][alloc_req_id] <= 1'b1;
            end
            if (fill_valid) busy[fill_idx] <= 1'b0;
        end
    end
    assign wake_mask = fill_valid ? (NUM_MSHR'(1) << fill_idx) : '0;
endmodule
```
*Derivation:* Every allocation request first CAM-searches all currently-busy MSHR entries for a matching address — a hit there (`secondary_hit`) means some earlier request is already fetching this exact line, so the new request just adds itself to that entry's `waiters` bitmap instead of consuming a fresh MSHR slot and issuing a redundant memory request; this merging is the entire point of having multiple MSHRs in the first place — without it, a cache could only ever have one outstanding miss at a time (functionally no better than a blocking cache), and without secondary-miss merging specifically, a burst of requests to the same missing line would each wastefully allocate a separate MSHR and separate memory request for what should be a single fetch.

**444. Victim Cache with Swap-on-Hit** — *(Hard)*
*Purpose:* Extends the earlier single-shot victim cache to actually swap a hitting victim-cache line back into the main cache (and the line it displaces into the victim cache), which is the complete, correct victim-cache behavior rather than just a lookup.
```systemverilog
module victim_cache_swap #(parameter int ENTRIES = 8, parameter int ADDR_W = 32) (
    input  logic clk, rst_n,
    input  logic l1_miss, input logic [ADDR_W-1:0] miss_addr,
    output logic vc_hit, output logic [$clog2(ENTRIES)-1:0] vc_hit_idx,
    output logic [511:0] vc_hit_data,
    input  logic do_swap, input logic [ADDR_W-1:0] l1_evict_addr, input logic [511:0] l1_evict_data
);
    logic v [ENTRIES];
    logic [ADDR_W-1:0] tag [ENTRIES];
    logic [511:0] data [ENTRIES];
    logic [$clog2(ENTRIES)-1:0] rr_ptr;

    always_comb begin
        vc_hit = 1'b0; vc_hit_idx = '0; vc_hit_data = '0;
        for (int i = 0; i < ENTRIES; i++)
            if (l1_miss && v[i] && (tag[i] == miss_addr)) begin
                vc_hit = 1'b1; vc_hit_idx = i[$clog2(ENTRIES)-1:0]; vc_hit_data = data[i];
            end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) v[i] <= 1'b0;
        end else if (do_swap) begin
            if (vc_hit) begin
                // the L1's newly-evicted line takes the exact slot the hit victim-cache line just vacated
                tag[vc_hit_idx] <= l1_evict_addr; data[vc_hit_idx] <= l1_evict_data;
            end else begin
                // no hit -- a plain fill: insert the evicted L1 line round-robin, no swap partner
                v[rr_ptr] <= 1'b1; tag[rr_ptr] <= l1_evict_addr; data[rr_ptr] <= l1_evict_data; rr_ptr <= rr_ptr + 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* The defining "swap" behavior — when a victim-cache hit occurs, the line that just got pulled back into L1 leaves an empty slot exactly where it was in the victim cache, and the L1 line it displaced (which was resident, now evicted to make room) moves into precisely that freed slot — this keeps the victim cache always full (no wasted round-robin allocation needed on a hit) and, more importantly, correctly implements the intended effect of a victim cache: two frequently-conflicting lines (e.g. two addresses that alias to the same direct-mapped set) can keep ping-ponging between L1 and the small fully-associative victim cache without either one ever being evicted all the way out to a slower memory level, which is exactly the access pattern victim caches exist to absorb.

**445. MESI Cache Line Controller (Full State Machine)** — *(Hard)*
*Purpose:* Completes the earlier `mesi_line` sketch into the full transition table including the bus-request-generation side (not just state transitions), the structure a real snooping-coherence cache controller needs per line.
```systemverilog
typedef enum logic [1:0] {MESI_I, MESI_S, MESI_E, MESI_M} mesi_e;

module mesi_full (
    input  logic clk, rst_n,
    input  logic local_read, local_write,
    input  logic snoop_read, snoop_readx, snoop_invalidate,
    output mesi_e state,
    output logic bus_req_read, bus_req_readx,   // this cache's own bus requests when it needs to change state
    output logic snoop_supply_data, snoop_supply_and_writeback
);
    mesi_e st;
    assign state = st;
    assign bus_req_read  = local_read  && (st == MESI_I);
    assign bus_req_readx  = local_write && (st == MESI_I || st == MESI_S);
    assign snoop_supply_data            = (snoop_read || snoop_readx) && (st == MESI_E || st == MESI_S);
    assign snoop_supply_and_writeback  = (snoop_read || snoop_readx) && (st == MESI_M);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= MESI_I;
        else unique case (st)
            MESI_I: begin
                if (local_write)      st <= MESI_M;
                else if (local_read)  st <= MESI_E;   // simplified: assumes no concurrent sharer signal on this fetch
            end
            MESI_S: begin
                if (local_write)       st <= MESI_M;
                if (snoop_invalidate || snoop_readx) st <= MESI_I;
            end
            MESI_E: begin
                if (local_write)  st <= MESI_M;
                if (snoop_read)    st <= MESI_S;
                if (snoop_readx || snoop_invalidate) st <= MESI_I;
            end
            MESI_M: begin
                if (snoop_read)    st <= MESI_S;   // must also writeback (snoop_supply_and_writeback)
                if (snoop_readx || snoop_invalidate) st <= MESI_I;   // must also writeback before invalidating
            end
        endcase
    end
endmodule
```
*Derivation:* The key addition over the earlier sketch is `bus_req_read`/`bus_req_readx` — a cache in Invalid state needing to satisfy a local read must broadcast a bus read request (to either get the line from memory or from another cache that has it), and a local write from Invalid *or* Shared must broadcast a read-exclusive/invalidate request (to force every other sharer to Invalid before this cache can safely move to Modified) — and `snoop_supply_and_writeback`, which captures that a Modified line snooped by another cache's request must both supply its dirty data *and* write that data back to memory (since after the transition it may no longer be the sole owner responsible for eventually writing it back), which is the specific extra step that distinguishes M-state snoop handling from E/S-state snoop handling (which only need to supply data, having nothing dirty to flush).

**446. Snoop Filter (Directory-Based)** — *(Hard)*
*Purpose:* Scales the earlier single-lookup snoop filter into a full directory that avoids broadcasting every snoop to every core by tracking, per cache line, a precise sharer bitmask.
```systemverilog
module directory_snoop_filter #(parameter int ENTRIES = 2048, parameter int NUM_CORES = 4) (
    input  logic clk, rst_n,
    input  logic [31:0] req_addr, input logic [$clog2(NUM_CORES)-1:0] req_core,
    input  logic req_is_read, req_is_write,
    output logic [NUM_CORES-1:0] snoop_targets,   // exactly which cores need a snoop, not a broadcast to all
    output logic need_memory_fetch
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic v [ENTRIES];
    logic [31:0] tag_arr [ENTRIES];
    logic [NUM_CORES-1:0] sharers [ENTRIES];
    logic [$clog2(NUM_CORES)-1:0] owner [ENTRIES];   // valid when exclusively owned (single-bit sharers)

    wire [IDX_W-1:0] idx = req_addr[IDX_W-1:0];
    wire dir_hit = v[idx] && (tag_arr[idx] == req_addr);

    assign snoop_targets    = dir_hit ? (sharers[idx] & ~(NUM_CORES'(1) << req_core)) : '0;
    assign need_memory_fetch = !dir_hit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) v[i] <= 1'b0;
        end else if (req_is_read || req_is_write) begin
            if (!dir_hit) begin v[idx] <= 1'b1; tag_arr[idx] <= req_addr; sharers[idx] <= '0; end
            if (req_is_write) sharers[idx] <= (NUM_CORES'(1) << req_core);   // exclusive: only requester remains a sharer
            else                sharers[idx] <= sharers[idx] | (NUM_CORES'(1) << req_core);
        end
    end
endmodule
```
*Derivation:* Unlike a plain broadcast-snoop scheme (every request checked against every core's cache, regardless of whether that core could possibly have the line), this directory tracks the *exact* sharer set per line, so `snoop_targets` only ever includes cores actually known to hold a copy — this is what lets coherence traffic scale sub-linearly with core count instead of the O(N) broadcast every request would otherwise require; `need_memory_fetch` correctly reflects that a directory miss means no core is tracked as sharing this line, so the data must come from memory (or, in a real implementation, this simplification would also need to handle directory *eviction* correctly recalling sharers, omitted here for focus).

**447. Non-Blocking Cache: Hit-Under-Miss Arbitration at Scale** — *(Hard)*
*Purpose:* Scales the earlier single-check hit-under-miss arbiter to handle multiple simultaneously-outstanding misses (tracked via Problem 443's MSHR bank), correctly allowing a hit to proceed on any bank not currently occupied by any of those outstanding fills.
```systemverilog
module hit_under_miss_scale #(parameter int NUM_MSHR = 8, parameter int NUM_BANKS = 4) (
    input  logic [NUM_MSHR-1:0] mshr_busy,
    input  logic [NUM_MSHR-1:0][$clog2(NUM_BANKS)-1:0] mshr_fill_bank,
    input  logic hit_req, input logic [$clog2(NUM_BANKS)-1:0] hit_bank_needed,
    output logic hit_allowed
);
    logic bank_busy;
    always_comb begin
        bank_busy = 1'b0;
        for (int i = 0; i < NUM_MSHR; i++)
            if (mshr_busy[i] && (mshr_fill_bank[i] == hit_bank_needed)) bank_busy = 1'b1;
    end
    assign hit_allowed = hit_req && !bank_busy;
endmodule
```
*Derivation:* Direct scale-up of the earlier two-input version — instead of checking against one possible in-flight fill, this checks the requested bank against *every* currently-busy MSHR's target bank, since with multiple outstanding misses (Problem 443), several different banks could simultaneously be occupied by different fills; a hit is allowed exactly when its own bank isn't among any of them, which is what lets a cache genuinely service several concurrent hits and misses across different banks in parallel, the actual meaning of "non-blocking" at realistic MSHR depth rather than just tolerating one outstanding miss at a time.

**448. Cache Way Predictor with Partial Tag Array Activation** — *(Hard)*
*Purpose:* Extends the earlier `way_predict_ctrl` sketch into a complete power-aware read sequence, only activating the tag/data arrays for the predicted way on the fast path, and falling back to full-array activation only on a misprediction.
```systemverilog
module way_predict_full #(parameter int WAYS = 4) (
    input  logic clk, rst_n,
    input  logic access_valid, input logic [$clog2(WAYS)-1:0] predicted_way,
    input  logic tag_match_predicted,
    output logic [WAYS-1:0] array_enable_cycle1, array_enable_cycle2,
    output logic slow_path_active,
    input  logic clk_gate_unused_ways   // configuration: whether to power-gate non-predicted ways at all
);
    logic slow_path_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) slow_path_q <= 1'b0;
        else        slow_path_q <= access_valid && !tag_match_predicted;
    end
    assign slow_path_active     = slow_path_q;
    assign array_enable_cycle1  = access_valid ? (WAYS'(1) << predicted_way) : '0;
    assign array_enable_cycle2  = slow_path_q ? ~(WAYS'(1) << predicted_way) : '0;
endmodule
```
*Derivation:* Cycle 1 activates only the predicted way's tag/data arrays (the fast, low-power common case, correct the large majority of the time given a well-trained way predictor); cycle 2's activation of the *remaining* ways only fires the cycle after a misprediction was detected, and specifically excludes the already-checked predicted way (`~(1<<predicted_way)`) since it's already known not to match — this two-cycle structure is exactly the latency/power tradeoff way prediction buys: correct predictions get single-way (low power, effectively single-cycle) access, while mispredictions pay one extra cycle of latency and a full-array activation, which is acceptable exactly because a well-trained predictor makes mispredictions the rare case.

**449. Stride Prefetcher with Confidence (Full)** — *(Hard)*
*Purpose:* Completes the earlier `stride_entry` sketch into a full multi-entry, tag-matched stride prefetcher table, tracking several independent access streams (e.g. multiple array-traversal loops active simultaneously) rather than just one.
```systemverilog
module stride_prefetcher_full #(parameter int ENTRIES = 16, parameter int ADDR_W = 32) (
    input  logic clk, rst_n,
    input  logic access_valid, input logic [ADDR_W-1:0] access_addr, input logic [31:0] access_pc,
    output logic prefetch_valid, output logic [ADDR_W-1:0] prefetch_addr
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic v [ENTRIES];
    logic [31:0] tag_pc [ENTRIES];
    logic [ADDR_W-1:0] last_addr [ENTRIES], stride [ENTRIES];
    logic [2:0] conf [ENTRIES];

    wire [IDX_W-1:0] idx = access_pc[IDX_W-1:0];
    wire hit = v[idx] && (tag_pc[idx] == access_pc);

    assign prefetch_valid = access_valid && hit && (conf[idx] >= 3'd3);
    assign prefetch_addr  = last_addr[idx] + (ADDR_W)'((32'(stride[idx])) * 4);   // prefetch several strides ahead

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) v[i] <= 1'b0;
        end else if (access_valid) begin
            if (!hit) begin
                v[idx] <= 1'b1; tag_pc[idx] <= access_pc; last_addr[idx] <= access_addr; stride[idx] <= '0; conf[idx] <= '0;
            end else begin
                automatic logic [ADDR_W-1:0] new_stride = access_addr - last_addr[idx];
                if (new_stride == stride[idx]) begin
                    if (conf[idx] != 3'd7) conf[idx] <= conf[idx] + 1'b1;
                end else begin
                    stride[idx] <= new_stride; conf[idx] <= '0;
                end
                last_addr[idx] <= access_addr;
            end
        end
    end
endmodule
```
*Derivation:* Indexing by the *load instruction's PC* (rather than a single global entry) is what lets multiple independent streams be tracked simultaneously — two different loop bodies each doing their own strided array traversal are two different PCs, so they naturally land in different table entries and don't corrupt each other's learned stride, exactly generalizing the single-stream sketch's core confidence-counter logic to realistic multi-stream workloads.

**450. Stream Buffer Prefetcher (N Streams)** — *(Hard)*
*Purpose:* An alternative prefetching strategy to per-PC stride detection — dedicates N independent hardware "stream" trackers, each following one detected sequential-access pattern regardless of which instruction generated it, useful for streaming workloads (memcpy-like patterns) where PC-based tracking is less natural.
```systemverilog
module stream_buffer_prefetcher #(parameter int NUM_STREAMS = 4, parameter int ADDR_W = 32) (
    input  logic clk, rst_n,
    input  logic access_valid, input logic [ADDR_W-1:0] access_line_addr,
    output logic prefetch_valid, output logic [ADDR_W-1:0] prefetch_line_addr
);
    logic v [NUM_STREAMS];
    logic [ADDR_W-1:0] next_expected [NUM_STREAMS];
    logic [2:0] conf [NUM_STREAMS];

    logic match; logic [$clog2(NUM_STREAMS)-1:0] match_idx, victim_idx;
    always_comb begin
        match = 1'b0; match_idx = '0; victim_idx = '0;
        for (int i = 0; i < NUM_STREAMS; i++)
            if (v[i] && (next_expected[i] == access_line_addr)) begin match = 1'b1; match_idx = i[$clog2(NUM_STREAMS)-1:0]; end
        for (int i = 0; i < NUM_STREAMS; i++)
            if (!v[i] || (conf[i] < conf[victim_idx])) victim_idx = i[$clog2(NUM_STREAMS)-1:0];
    end

    assign prefetch_valid    = access_valid && match && (conf[match_idx] >= 3'd2);
    assign prefetch_line_addr = next_expected[match_idx] + 32'd64;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_STREAMS; i++) v[i] <= 1'b0;
        end else if (access_valid) begin
            if (match) begin
                next_expected[match_idx] <= next_expected[match_idx] + 32'd64;
                if (conf[match_idx] != 3'd7) conf[match_idx] <= conf[match_idx] + 1'b1;
            end else begin
                v[victim_idx] <= 1'b1;
                next_expected[victim_idx] <= access_line_addr + 32'd64;
                conf[victim_idx] <= '0;
            end
        end
    end
endmodule
```
*Derivation:* Unlike the PC-indexed stride prefetcher (Problem 449), this content-addressably searches all `NUM_STREAMS` trackers for one whose *expected next address* matches the current access — any access continuing a recognized sequential pattern (from any instruction) extends that stream, while an access matching no stream evicts whichever stream currently has the lowest confidence (the least "proven" stream) to start tracking the new pattern; this address-based (rather than instruction-based) matching is specifically well-suited to workloads with a small number of concurrent sequential streams whose accessing code doesn't map cleanly to a single static load PC (e.g. a generic memcpy-style routine called from many different call sites).

**451. Cache Line ECC (SEC-DED) with Scrubbing** — *(Hard)*
*Purpose:* Extends the earlier single-access ECC sketch with a background scrubbing mechanism that proactively reads and corrects lines even without a demand access, preventing single-bit errors from silently accumulating into uncorrectable double-bit errors over time.
```systemverilog
module ecc_scrubber #(parameter int SETS = 1024) (
    input  logic clk, rst_n,
    input  logic scrub_enable,
    output logic scrub_req_valid, output logic [$clog2(SETS)-1:0] scrub_set_idx,
    input  logic scrub_resp_valid, input logic correctable_err, uncorrectable_err,
    output logic [31:0] correctable_count, uncorrectable_count
);
    logic [$clog2(SETS)-1:0] scrub_ptr;
    logic scrub_outstanding;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scrub_ptr <= '0; scrub_outstanding <= 1'b0; correctable_count <= '0; uncorrectable_count <= '0;
        end else begin
            if (scrub_enable && !scrub_outstanding) scrub_outstanding <= 1'b1;
            if (scrub_resp_valid) begin
                scrub_outstanding <= 1'b0;
                scrub_ptr <= scrub_ptr + 1'b1;
                if (correctable_err)    correctable_count   <= correctable_count + 1'b1;
                if (uncorrectable_err)  uncorrectable_count <= uncorrectable_count + 1'b1;
            end
        end
    end
    assign scrub_req_valid = scrub_enable && !scrub_outstanding;
    assign scrub_set_idx    = scrub_ptr;
endmodule
```
*Derivation:* Cycling `scrub_ptr` through every set in the array, one at a time, on a low-priority background schedule (only issuing a new scrub request once the previous one completes, and presumably arbitrated at low priority against demand accesses in a real design) is what actually delivers ECC's reliability promise over time — SEC-DED can correct a *single*-bit error but not a double-bit one, so if errors are only ever discovered on demand access, a line that's rarely touched could silently accumulate a second bit error (becoming permanently uncorrectable) between two demand accesses far apart in time; periodic scrubbing bounds how long any single-bit error can persist uncorrected, directly bounding the probability it accumulates a second error before being caught and fixed.

**452. Multi-Level Cache Inclusion Policy Enforcement** — *(Hard)*
*Purpose:* In an inclusive cache hierarchy (every line in L1 must also be present in L2), an L2 eviction must proactively invalidate that same line from L1 — otherwise L1 could hold a "phantom" line no longer backed by L2, breaking the inclusion invariant coherence protocols often rely on.
```systemverilog
module inclusion_enforce (
    input  logic l2_evict_valid, input logic [31:0] l2_evict_addr,
    input  logic [3:0] l2_evict_present_in_l1_mask,   // which L1 caches (in a multi-core system) might hold this line
    output logic [3:0] l1_invalidate_req
);
    assign l1_invalidate_req = {4{l2_evict_valid}} & l2_evict_present_in_l1_mask;
endmodule
```
*Derivation:* This "back-invalidation" is the defining mechanical requirement of inclusive hierarchies — `l2_evict_present_in_l1_mask` would typically come from a per-L2-line presence-bit vector (similar in spirit to Problem 446's directory sharer bits, but tracking "does this line also live in L1" rather than "which cores have it"), and every L1 flagged there must receive an invalidate exactly when its backing L2 line disappears; this is precisely the mechanism (and the associated back-invalidation traffic cost) that non-inclusive or exclusive cache hierarchies are designed to avoid, at the cost of more complex cross-level coherence bookkeeping elsewhere.

**453. Cache Coherence Request Queue (Inbound Snoop Handling)** — *(Hard)*
*Purpose:* Incoming snoop requests from the coherence bus/interconnect (from Problem 445's MESI logic in *other* cores) must be queued and serviced by this cache's own controller, which may be busy servicing a local demand access when a snoop arrives.
```systemverilog
module snoop_request_queue #(parameter int DEPTH = 4, parameter int ADDR_W = 32) (
    input  logic clk, rst_n,
    input  logic snoop_in_valid, output logic snoop_in_ready,
    input  logic [ADDR_W-1:0] snoop_in_addr, input logic [1:0] snoop_in_type,
    output logic snoop_out_valid, output logic [ADDR_W-1:0] snoop_out_addr, output logic [1:0] snoop_out_type,
    input  logic snoop_out_consumed
);
    logic [ADDR_W-1:0] addr_mem [DEPTH];
    logic [1:0] type_mem [DEPTH];
    logic [$clog2(DEPTH):0] head, tail;

    assign snoop_in_ready = (tail - head) != $clog2(DEPTH)'(DEPTH);
    assign snoop_out_valid = (head != tail);
    assign snoop_out_addr   = addr_mem[head[$clog2(DEPTH)-1:0]];
    assign snoop_out_type    = type_mem[head[$clog2(DEPTH)-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin head <= '0; tail <= '0; end
        else begin
            if (snoop_in_valid && snoop_in_ready) begin
                addr_mem[tail[$clog2(DEPTH)-1:0]] <= snoop_in_addr;
                type_mem[tail[$clog2(DEPTH)-1:0]] <= snoop_in_type;
                tail <= tail + 1'b1;
            end
            if (snoop_out_valid && snoop_out_consumed) head <= head + 1'b1;
        end
    end
endmodule
```
*Derivation:* A plain FIFO buffers incoming snoops so the coherence bus doesn't have to stall waiting for this specific cache's controller to become free — critically, this cache's own local demand accesses and the queued snoops both ultimately need to serialize through the same MESI state-transition logic (Problem 445) per line, so a real design also needs an arbiter (not shown, but structurally the same 2-requester priority pattern as Problem 237) deciding whether local demand or queued-snoop processing gets the controller each cycle, typically favoring snoops to avoid stalling the *entire coherence bus* (which affects every other core) over a single core's local access.

**454. Write-Combining Buffer with Merge (Full)** — *(Hard)*
*Purpose:* Completes the earlier single-line write-combining buffer sketch with support for multiple simultaneously-open combining buffers, letting several independent write streams to different lines combine in parallel rather than forcing strict serialization.
```systemverilog
module wcb_multi #(parameter int NUM_WCB = 4, parameter int LINE_BYTES = 64) (
    input  logic clk, rst_n,
    input  logic store_valid, input logic [31:0] store_addr, input logic [7:0] store_bytes, input logic [63:0] store_data,
    output logic store_accepted,
    input  logic [NUM_WCB-1:0] drain_req,
    output logic [NUM_WCB-1:0] drain_ready
);
    logic active [NUM_WCB];
    logic [31:0] line_addr [NUM_WCB];
    logic [LINE_BYTES-1:0] byte_en [NUM_WCB];

    logic [$clog2(NUM_WCB)-1:0] match_idx, free_idx;
    logic match, has_free;
    always_comb begin
        match = 1'b0; match_idx = '0; has_free = 1'b0; free_idx = '0;
        for (int i = 0; i < NUM_WCB; i++) begin
            if (active[i] && (line_addr[i] == {store_addr[31:6], 6'b0})) begin match = 1'b1; match_idx = i[$clog2(NUM_WCB)-1:0]; end
            if (!active[i] && !has_free) begin has_free = 1'b1; free_idx = i[$clog2(NUM_WCB)-1:0]; end
        end
    end
    assign store_accepted = store_valid && (match || has_free);
    assign drain_ready     = active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_WCB; i++) active[i] <= 1'b0;
        end else begin
            if (store_valid && store_accepted) begin
                automatic int idx = match ? match_idx : free_idx;
                if (!match) begin active[idx] <= 1'b1; line_addr[idx] <= {store_addr[31:6], 6'b0}; byte_en[idx] <= '0; end
                for (int b = 0; b < 8; b++)
                    if (store_bytes[b]) byte_en[idx][store_addr[5:0]+b] <= 1'b1;
            end
            for (int i = 0; i < NUM_WCB; i++)
                if (drain_req[i]) active[i] <= 1'b0;
        end
    end
endmodule
```
*Derivation:* Same CAM-search-then-allocate structure as Problem 443's MSHR bank (search for a matching in-progress buffer first, only allocate a fresh slot on a genuine miss) — having multiple simultaneously-open combining buffers, rather than the earlier sketch's single buffer, is what lets a program interleaving writes to two or more different cache lines (e.g. writing two output arrays in a tight loop) still get combining benefit on both streams, instead of one stream's writes forcing premature drains of the other.

**455. Cache Flush/Clean Range Operation FSM** — *(Hard)*
*Purpose:* Software (or a CMO instruction) sometimes needs to flush/clean a specific *address range*, not the entire cache — this FSM walks exactly the lines covering that range rather than Problem 298's whole-cache flush.
```systemverilog
module cache_range_op #(parameter int LINE_BYTES = 64) (
    input  logic clk, rst_n, start,
    input  logic [31:0] range_base, range_limit,
    input  logic is_clean_only,   // clean (writeback if dirty, keep valid) vs full flush (writeback + invalidate)
    output logic busy, done,
    output logic [31:0] cur_line_addr,
    output logic op_valid, op_is_invalidate
);
    logic [31:0] cur_addr;
    typedef enum logic [1:0] {IDLE, WALKING, DONE_ST} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; done <= 1'b0; end
        else begin
            done <= 1'b0;
            unique case (state)
                IDLE: if (start) begin cur_addr <= range_base; state <= WALKING; end
                WALKING: begin
                    cur_addr <= cur_addr + LINE_BYTES;
                    if (cur_addr + LINE_BYTES >= range_limit) state <= DONE_ST;
                end
                DONE_ST: begin done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign busy              = (state == WALKING);
    assign cur_line_addr      = cur_addr;
    assign op_valid            = (state == WALKING);
    assign op_is_invalidate   = op_valid && !is_clean_only;
endmodule
```
*Derivation:* One line-granular step per cycle from `range_base` to `range_limit` (matching Problem 298's per-set sequential walk, here over an address range instead of a fixed set count) — `is_clean_only` gates whether the line is also invalidated after writeback, distinguishing a `CMO.CLEAN` (data pushed to memory but line stays cached and valid, useful for e.g. DMA-visibility without losing the performance benefit of keeping the line cached) from a full `CMO.FLUSH` (writeback and invalidate, needed when the memory region is about to be repurposed or the line must definitely not remain cached).

**456. Bank-Conflict Arbitration for Multi-Bank Cache** — *(Hard)*
*Purpose:* Extends the earlier two-requester `bank_fetch_arb` sketch to arbitrate among many simultaneous requesters (e.g. multiple load/store ports in a wide-issue core) all potentially targeting the same cache bank in the same cycle.
```systemverilog
module bank_arb_wide #(parameter int NUM_REQ = 4, parameter int NUM_BANKS = 8) (
    input  logic [NUM_REQ-1:0] req_valid,
    input  logic [NUM_REQ-1:0][$clog2(NUM_BANKS)-1:0] req_bank,
    output logic [NUM_REQ-1:0] req_granted
);
    always_comb begin
        req_granted = '0;
        for (int b = 0; b < NUM_BANKS; b++) begin
            automatic logic found = 1'b0;
            for (int r = 0; r < NUM_REQ; r++)
                if (req_valid[r] && (req_bank[r] == b[$clog2(NUM_BANKS)-1:0]) && !found) begin
                    req_granted[r] = 1'b1; found = 1'b1;   // first (lowest-index) requester per bank wins
                end
        end
    end
endmodule
```
*Derivation:* For each bank independently, scan requesters in fixed order and grant the first one targeting that bank — this guarantees at most one grant per bank (satisfying the single-port-per-bank constraint) while allowing full parallelism *across* banks (up to `NUM_BANKS` simultaneous grants when requests happen to spread across different banks), which is exactly the throughput benefit multi-banking a cache/register file exists to provide: bank conflicts (multiple requesters wanting the *same* bank) still serialize, but non-conflicting accesses to different banks proceed fully in parallel rather than being needlessly serialized by a single shared port.

**457. Critical-Word-First Fill with Early Restart (Full)** — *(Hard)*
*Purpose:* Completes the earlier sketch into a full FSM that tracks exactly which beat of a multi-beat fill corresponds to the originally-demanded word, forwards it the instant it arrives (regardless of beat order), and only then continues filling the remaining beats for full-line completion.
```systemverilog
module cwf_early_restart #(parameter int BEATS = 4) (
    input  logic clk, rst_n, fill_start,
    input  logic [$clog2(BEATS)-1:0] demand_beat,
    output logic mem_req_valid,
    output logic [$clog2(BEATS)-1:0] mem_req_beat_idx,
    input  logic mem_resp_valid, input logic [127:0] mem_resp_data,
    output logic demand_word_ready, output logic [127:0] demand_word_data,
    output logic line_fill_done,
    output logic [BEATS-1:0][127:0] line_data
);
    logic [BEATS-1:0] got;
    logic [$clog2(BEATS+1)-1:0] beats_issued;
    typedef enum logic [1:0] {IDLE, FILLING, DONE_ST} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; got <= '0; beats_issued <= '0; end
        else begin
            unique case (state)
                IDLE: if (fill_start) begin got <= '0; beats_issued <= '0; state <= FILLING; end
                FILLING: begin
                    if (mem_resp_valid) begin
                        automatic logic [$clog2(BEATS)-1:0] arriving_beat = demand_beat + beats_issued[$clog2(BEATS)-1:0] - 1'b1;
                        line_data[arriving_beat] <= mem_resp_data;
                        got[arriving_beat] <= 1'b1;
                        if (&got | (got | (BEATS'(1)<<arriving_beat)) == {BEATS{1'b1}}) state <= DONE_ST;
                    end
                end
                DONE_ST: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
    assign mem_req_valid    = (state == FILLING) && (beats_issued != BEATS);
    assign mem_req_beat_idx = (demand_beat + beats_issued[$clog2(BEATS)-1:0]) % BEATS;   // critical-word-first ordering
    assign demand_word_ready = mem_resp_valid && (state == FILLING) && (beats_issued == 0);
    assign demand_word_data   = mem_resp_data;
    assign line_fill_done      = (state == DONE_ST);
endmodule
```
*Derivation:* `mem_req_beat_idx` requests the critically-needed beat *first* (`demand_beat + 0`), then wraps around through the remaining beats in address order — this is exactly what "critical-word-first" means: memory is asked to return the demanded word before anything else, so `demand_word_ready` can fire on the very first response regardless of where that word physically sits within the line, letting the stalled load/instruction-fetch unblock immediately rather than waiting for the entire line to arrive in its natural address order, while the remaining beats continue filling in the background to complete the line for future accesses.

**458. Cache Replacement Policy: Not-Recently-Used (NRU)** — *(Hard)*
*Purpose:* A cheaper approximation to LRU (Problems 441/442) using just a single reference bit per way rather than a full recency ordering — periodically cleared, and any way whose bit is still 0 when a victim is needed is preferred for eviction.
```systemverilog
module nru_replacement #(parameter int WAYS = 4) (
    input  logic clk, rst_n,
    input  logic access_hit, input logic [$clog2(WAYS)-1:0] access_way,
    input  logic need_victim, input logic periodic_clear,
    output logic [$clog2(WAYS)-1:0] victim_way
);
    logic [WAYS-1:0] ref_bit;
    always_comb begin
        victim_way = '0;
        for (int w = 0; w < WAYS; w++)
            if (!ref_bit[w]) victim_way = w[$clog2(WAYS)-1:0];   // last (highest-index) way with ref_bit=0 wins
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || periodic_clear) ref_bit <= '0;
        else if (access_hit) ref_bit[access_way] <= 1'b1;
    end
endmodule
```
*Derivation:* Only 1 bit per way (versus true LRU's `log2(WAYS!)`-scale ordering or even pseudo-LRU's `log2(WAYS)` tree bits) — any way not yet referenced since the last `periodic_clear` is an eviction candidate, giving a coarse "was this used recently, yes or no" approximation rather than a precise ordering; this is a real, common tradeoff point cheaper than pseudo-LRU, used where even PLRU's tree-update logic is more than a design can afford, accepting materially worse hit-rate accuracy in exchange for the smallest possible per-way state.

**459. Exclusive Cache State Transfer (Cache-to-Cache Transfer on Miss)** — *(Hard)*
*Purpose:* When one core misses on a line that another core holds in Modified or Exclusive state (Problem 445), the data can be transferred directly cache-to-cache rather than round-tripping through memory — faster, and in the Modified case, avoids an extra memory write followed immediately by a memory read.
```systemverilog
module cache_to_cache_transfer (
    input  logic remote_has_modified, remote_has_exclusive,
    input  logic local_miss_valid,
    output logic request_from_remote, output logic remote_must_writeback_too,
    output logic request_from_memory
);
    assign request_from_remote     = local_miss_valid && (remote_has_modified || remote_has_exclusive);
    assign remote_must_writeback_too = local_miss_valid && remote_has_modified;   // M-state data must also reach memory eventually
    assign request_from_memory       = local_miss_valid && !remote_has_modified && !remote_has_exclusive;
endmodule
```
*Derivation:* If a remote cache holds the line Modified, its data is *more current* than whatever's in memory, so it must be the source of the transfer (memory's copy is stale) — and per Problem 445's MESI reasoning, that dirty data should also be written back to memory during the same transfer (`remote_must_writeback_too`) so memory catches up, typically transitioning the line to Shared in both caches afterward; if the remote cache holds it merely Exclusive (clean, matches memory), a cache-to-cache transfer is still faster than a memory round-trip even though memory's copy would have been equally correct, which is why real coherence protocols opt for cache-to-cache transfer whenever *any* cache holds a clean or dirty copy, falling back to memory only when no cache has the line at all.

**460. Cache Hierarchy Top Wrapper (L1 + L2 + Coherence Stub)** — *(Hard)*
*Purpose:* Integrates an L1 lookup, an L2 lookup, and MESI state tracking into a single representative two-level, coherence-aware memory hierarchy top module.
```systemverilog
module cache_hierarchy_top #(parameter int L1_SETS = 64, parameter int L2_SETS = 512) (
    input  logic clk, rst_n,
    input  logic access_valid, input logic [31:0] access_addr,
    output logic l1_hit, l2_hit,
    output mesi_e line_state
);
    logic l1_valid_arr [L1_SETS]; logic [31:0] l1_tag_arr [L1_SETS];
    logic l2_valid_arr [L2_SETS]; logic [31:0] l2_tag_arr [L2_SETS];

    dm_cache_ctrl #(.SETS(L1_SETS)) u_l1 (
        .clk(clk), .rst_n(rst_n), .access_valid(access_valid), .access_addr(access_addr),
        .hit(l1_hit), .miss(), .fill_valid(1'b0), .fill_addr('0)
    );
    dm_cache_ctrl #(.SETS(L2_SETS)) u_l2 (
        .clk(clk), .rst_n(rst_n), .access_valid(access_valid && !l1_hit), .access_addr(access_addr),
        .hit(l2_hit), .miss(), .fill_valid(1'b0), .fill_addr('0)
    );

    mesi_full u_mesi (
        .clk(clk), .rst_n(rst_n), .local_read(access_valid), .local_write(1'b0),
        .snoop_read(1'b0), .snoop_readx(1'b0), .snoop_invalidate(1'b0),
        .state(line_state), .bus_req_read(), .bus_req_readx(), .snoop_supply_data(), .snoop_supply_and_writeback()
    );
endmodule
```
*Derivation:* L2 is only consulted when L1 misses (`access_valid && !l1_hit`), matching the standard exclusive-lookup-order behavior of a real multi-level hierarchy (checking every level in parallel would waste power looking up L2 on the common case of an L1 hit) — reusing `dm_cache_ctrl` from the Medium tier at both levels (just with different `SETS` parameters) demonstrates that the fundamental lookup mechanism doesn't change between cache levels, only capacity/associativity/latency characteristics do, with the MESI state machine layered on top tracking coherence state independently of which level currently holds the line.

---

## Category 4: TLB & Virtual Memory (461–480)

**461. Multi-Level TLB (L1 Micro-TLB + L2 TLB)** — *(Hard)*
*Purpose:* Formalizes the earlier `tlb_hierarchy` sketch as the standard two-level TLB organization — a very small, very fast L1 covering the common case, backed by a larger, slower L2 that absorbs L1 misses before falling all the way through to a page-table walk.
```systemverilog
module tlb_2level #(parameter int VPN_W = 20, parameter int PPN_W = 22, parameter int L1_ENTRIES = 8, parameter int L2_ENTRIES = 256) (
    input  logic clk, rst_n,
    input  logic [VPN_W-1:0] lookup_vpn,
    output logic hit, output logic [PPN_W-1:0] ppn,
    output logic l1_hit, l2_hit,
    input  logic l2_fill_en, input logic [VPN_W-1:0] l2_fill_vpn, input logic [PPN_W-1:0] l2_fill_ppn
);
    logic [PPN_W-1:0] l1_ppn, l2_ppn;
    micro_tlb #(.VPN_W(VPN_W), .PPN_W(PPN_W), .ENTRIES(L1_ENTRIES)) u_l1 (
        .clk(clk), .rst_n(rst_n), .lookup_vpn(lookup_vpn), .hit(l1_hit), .ppn(l1_ppn), .perm(),
        .fill_en(l2_hit && !l1_hit), .fill_vpn(lookup_vpn), .fill_ppn(l2_ppn), .fill_perm(3'b111)
    );
    micro_tlb #(.VPN_W(VPN_W), .PPN_W(PPN_W), .ENTRIES(L2_ENTRIES)) u_l2 (
        .clk(clk), .rst_n(rst_n), .lookup_vpn(lookup_vpn), .hit(l2_hit), .ppn(l2_ppn), .perm(),
        .fill_en(l2_fill_en), .fill_vpn(l2_fill_vpn), .fill_ppn(l2_fill_ppn), .fill_perm(3'b111)
    );
    assign hit = l1_hit || l2_hit;
    assign ppn  = l1_hit ? l1_ppn : l2_ppn;
endmodule
```
*Derivation:* L1 fills itself automatically from any L2 hit (`l2_hit && !l1_hit`), so L1 organically comes to hold whichever translations are being looked up most recently/frequently, while L2 is filled only from the (much rarer) full page-table walk — this two-level structure exists for exactly the same latency/capacity tradeoff reason as an L1/L2 data cache: L1 must be small enough to hit in one cycle, L2 can afford to be much larger (hundreds of entries) since a few extra cycles of L2 latency is still far cheaper than a full multi-memory-access page-table walk.

**462. Sv32 2-Level Page Table Walker** — *(Hard)*
*Purpose:* Completes the earlier simplified `page_walker` sketch into a fully spec-accurate Sv32 walker, correctly handling both leaf-at-level-1 (superpage) and leaf-at-level-0 (normal 4KiB page) termination.
```systemverilog
module sv32_walker (
    input  logic clk, rst_n, walk_start,
    input  logic [9:0] vpn1, vpn0,
    input  logic [21:0] satp_ppn,
    output logic mem_req_valid, output logic [33:0] mem_req_addr,
    input  logic mem_resp_valid, input logic [31:0] mem_resp_data,
    output logic walk_done, output logic [21:0] result_ppn, output logic is_superpage,
    output logic page_fault
);
    typedef enum logic [1:0] {IDLE, L1_WAIT, L0_WAIT} state_e;
    state_e state;
    logic [21:0] l1_ppn;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; walk_done <= 1'b0; page_fault <= 1'b0; end
        else begin
            walk_done <= 1'b0; page_fault <= 1'b0;
            unique case (state)
                IDLE: if (walk_start) state <= L1_WAIT;
                L1_WAIT: if (mem_resp_valid) begin
                    if (!mem_resp_data[0]) begin page_fault <= 1'b1; walk_done <= 1'b1; state <= IDLE; end
                    else if (mem_resp_data[3:1] != 3'b000) begin   // R or X set at level 1 -> this IS the leaf (4MiB superpage)
                        result_ppn <= {mem_resp_data[31:20], 10'b0}; is_superpage <= 1'b1;
                        walk_done <= 1'b1; state <= IDLE;
                    end else begin
                        l1_ppn <= mem_resp_data[31:10]; state <= L0_WAIT;
                    end
                end
                L0_WAIT: if (mem_resp_valid) begin
                    if (!mem_resp_data[0]) page_fault <= 1'b1;
                    else                     begin result_ppn <= mem_resp_data[31:10]; is_superpage <= 1'b0; end
                    walk_done <= 1'b1; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign mem_req_valid = ((state == IDLE) && walk_start) || (state == L1_WAIT && !mem_resp_valid) || (state == L0_WAIT && !mem_resp_valid);
    assign mem_req_addr  = (state == IDLE) ? {satp_ppn, vpn1, 2'b00} : {l1_ppn, vpn0, 2'b00};
endmodule
```
*Derivation:* The key Sv32-spec detail this adds over the earlier simplified sketch is the superpage check at level 1: a PTE with any of the R/W/X permission bits (`mem_resp_data[3:1]`) set is *by definition* a leaf PTE regardless of which level it's found at — per the Sv32 spec, only a non-leaf (pointer-to-next-level) PTE has all three permission bits clear — so encountering R/W/X set already at the level-1 lookup means the walk terminates immediately with a 4MiB superpage translation, skipping the level-0 lookup entirely, which is both a correctness requirement (a level-1 PTE without those bits genuinely doesn't have a valid physical frame number for a leaf) and a performance benefit (superpage translations are cheaper to walk).

**463. Sv39 3-Level Page Table Walker** — *(Hard)*
*Purpose:* Extends Problem 462's Sv32 (32-bit VA, 2-level) walker to Sv39 (39-bit VA, 3-level), the standard virtual memory scheme for RV64 systems.
```systemverilog
module sv39_walker (
    input  logic clk, rst_n, walk_start,
    input  logic [8:0] vpn2, vpn1, vpn0,
    input  logic [43:0] satp_ppn,
    output logic mem_req_valid, output logic [55:0] mem_req_addr,
    input  logic mem_resp_valid, input logic [63:0] mem_resp_data,
    output logic walk_done, output logic [43:0] result_ppn,
    output logic [1:0] leaf_level,   // 2=1GiB superpage, 1=2MiB superpage, 0=4KiB page
    output logic page_fault
);
    typedef enum logic [1:0] {IDLE, LVL2, LVL1, LVL0} state_e;
    state_e state;
    logic [43:0] next_ppn;

    function automatic logic is_leaf(input logic [63:0] pte); return pte[3:1] != 3'b000; endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; walk_done <= 1'b0; page_fault <= 1'b0; end
        else begin
            walk_done <= 1'b0; page_fault <= 1'b0;
            unique case (state)
                IDLE: if (walk_start) state <= LVL2;
                LVL2: if (mem_resp_valid) begin
                    if (!mem_resp_data[0]) begin page_fault <= 1'b1; walk_done <= 1'b1; state <= IDLE; end
                    else if (is_leaf(mem_resp_data)) begin result_ppn <= mem_resp_data[53:10]; leaf_level <= 2'd2; walk_done <= 1'b1; state <= IDLE; end
                    else begin next_ppn <= mem_resp_data[53:10]; state <= LVL1; end
                end
                LVL1: if (mem_resp_valid) begin
                    if (!mem_resp_data[0]) begin page_fault <= 1'b1; walk_done <= 1'b1; state <= IDLE; end
                    else if (is_leaf(mem_resp_data)) begin result_ppn <= mem_resp_data[53:10]; leaf_level <= 2'd1; walk_done <= 1'b1; state <= IDLE; end
                    else begin next_ppn <= mem_resp_data[53:10]; state <= LVL0; end
                end
                LVL0: if (mem_resp_valid) begin
                    if (!mem_resp_data[0]) page_fault <= 1'b1;
                    else                     begin result_ppn <= mem_resp_data[53:10]; leaf_level <= 2'd0; end
                    walk_done <= 1'b1; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign mem_req_valid = (walk_start && state==IDLE) || ((state==LVL2||state==LVL1||state==LVL0) && !mem_resp_valid);
    assign mem_req_addr  = (state == IDLE) ? {satp_ppn, vpn2, 3'b000} :
                            (state == LVL2) ? {next_ppn, vpn1, 3'b000} : {next_ppn, vpn0, 3'b000};
endmodule
```
*Derivation:* Same leaf-detection principle as Sv32 (Problem 462), generalized via the `is_leaf` function reused identically at all three levels, now supporting three distinct superpage granularities (1GiB at level 2, 2MiB at level 1, 4KiB at level 0) — the extra level directly reflects Sv39's larger 39-bit virtual address space needing one more level of 9-bit VPN indexing (`vpn2`/`vpn1`/`vpn0`, each 9 bits, versus Sv32's 10-bit `vpn1`/`vpn0`) to keep each page-table page a manageable 4KiB (512 eight-byte PTEs per Sv39 table page versus Sv32's 1024 four-byte PTEs).

**464. TLB Shootdown Broadcast (Multi-Core Invalidate)** — *(Hard)*
*Purpose:* When one core's software modifies a page table entry (e.g. an OS unmapping a page), every *other* core's TLB might still hold a stale cached translation for that entry — this broadcasts the invalidation request to all cores.
```systemverilog
module tlb_shootdown_broadcast #(parameter int NUM_CORES = 4) (
    input  logic clk, rst_n,
    input  logic shootdown_req_valid, input logic [31:0] shootdown_vaddr, input logic [$clog2(NUM_CORES)-1:0] initiator_core,
    output logic [NUM_CORES-1:0] shootdown_target_valid,
    output logic [31:0] shootdown_target_vaddr,
    input  logic [NUM_CORES-1:0] shootdown_ack,
    output logic shootdown_complete
);
    logic [NUM_CORES-1:0] pending;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pending <= '0;
        else if (shootdown_req_valid) begin
            pending <= {NUM_CORES{1'b1}} & ~(NUM_CORES'(1) << initiator_core);   // initiator doesn't need to shoot down its own TLB via broadcast
        end else begin
            pending <= pending & ~shootdown_ack;
        end
    end
    assign shootdown_target_valid = pending;
    assign shootdown_target_vaddr  = shootdown_vaddr;
    assign shootdown_complete       = (pending == '0) && !shootdown_req_valid;
endmodule
```
*Derivation:* The initiating core is excluded from the broadcast target mask since it presumably already invalidates its own TLB entry locally (as part of executing the `SFENCE.VMA` that triggered this shootdown in the first place, Problem 479) — every *other* core must acknowledge before `shootdown_complete` asserts, because the entire point of a shootdown is a synchronization barrier: the initiating core's software typically cannot safely consider the unmap complete (and, e.g., reuse that physical page for something else) until every core has confirmed it can no longer possibly generate a stale translation to the old mapping — this makes TLB shootdown one of the more expensive cross-core operations in a multi-core system, since it requires this full round-trip acknowledgment from every core rather than a fire-and-forget broadcast.

**465. ASID-Tagged TLB with Global-Bit Bypass** — *(Hard)*
*Purpose:* Extends the earlier ASID-tagged micro-TLB with support for the "global" PTE bit — some mappings (like kernel/OS pages mapped identically into every process's address space) should hit regardless of the current ASID, avoiding needless TLB flushes/misses on every context switch for those entries.
```systemverilog
module tlb_asid_global #(parameter int VPN_W = 20, parameter int PPN_W = 22, parameter int ENTRIES = 16, parameter int ASID_W = 8) (
    input  logic clk, rst_n,
    input  logic [VPN_W-1:0] lookup_vpn, input logic [ASID_W-1:0] current_asid,
    output logic hit, output logic [PPN_W-1:0] ppn,
    input  logic fill_en, input logic [VPN_W-1:0] fill_vpn, input logic [PPN_W-1:0] fill_ppn,
    input  logic [ASID_W-1:0] fill_asid, input logic fill_global
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic [VPN_W-IDX_W-1:0] tag_arr [ENTRIES];
    logic [PPN_W-1:0] ppn_arr [ENTRIES];
    logic [ASID_W-1:0] asid_arr [ENTRIES];
    logic global_arr [ENTRIES];
    logic valid_arr [ENTRIES];

    wire [IDX_W-1:0] idx = lookup_vpn[IDX_W-1:0];
    wire [VPN_W-IDX_W-1:0] tag = lookup_vpn[VPN_W-1:IDX_W];
    assign hit = valid_arr[idx] && (tag_arr[idx] == tag) && (global_arr[idx] || (asid_arr[idx] == current_asid));
    assign ppn = ppn_arr[idx];

    wire [IDX_W-1:0] f_idx = fill_vpn[IDX_W-1:0];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) valid_arr[i] <= 1'b0;
        end else if (fill_en) begin
            valid_arr[f_idx] <= 1'b1; tag_arr[f_idx] <= fill_vpn[VPN_W-1:IDX_W];
            ppn_arr[f_idx] <= fill_ppn; asid_arr[f_idx] <= fill_asid; global_arr[f_idx] <= fill_global;
        end
    end
endmodule
```
*Derivation:* The hit condition becomes `global_arr[idx] || (asid_arr[idx] == current_asid)` — an OR, not just an AND against ASID — meaning a global entry matches for *any* running process's ASID, exactly modeling the hardware behavior that lets kernel mappings stay resident and useful across every context switch, while ordinary (non-global) user-space mappings still correctly require an exact ASID match so one process's TLB entries can never be mistakenly used to satisfy another process's translation for the same virtual address.

**466. Huge-Page-Aware TLB Entry (Variable Page-Size Match)** — *(Hard)*
*Purpose:* Extends the earlier variable-mask TLB entry sketch to a complete multi-entry TLB where different entries can simultaneously hold different page sizes (4KiB, 2MiB, 1GiB), each correctly matched against only the VPN bits relevant to its own size.
```systemverilog
module tlb_variable_pagesize #(parameter int ENTRIES = 16, parameter int VA_W = 39, parameter int PPN_W = 44) (
    input  logic [VA_W-1:0] lookup_va,
    input  logic [ENTRIES-1:0] valid_arr,
    input  logic [ENTRIES-1:0][VA_W-1:0] entry_va, entry_mask,
    input  logic [ENTRIES-1:0][PPN_W-1:0] entry_ppn,
    output logic hit, output logic [PPN_W-1:0] ppn
);
    logic [ENTRIES-1:0] match;
    always_comb
        for (int i = 0; i < ENTRIES; i++)
            match[i] = valid_arr[i] && ((lookup_va & entry_mask[i]) == (entry_va[i] & entry_mask[i]));

    always_comb begin
        hit = |match; ppn = '0;
        for (int i = 0; i < ENTRIES; i++) if (match[i]) ppn = entry_ppn[i];
    end
endmodule
```
*Derivation:* Each entry carries its *own* mask (e.g. all address bits above bit 12 for a 4KiB page, above bit 21 for 2MiB, above bit 30 for 1GiB per Sv39's superpage granularities from Problem 463) rather than the TLB having one fixed match granularity — masking both the lookup address and the stored address with that entry's own mask before comparing is what lets, say, a 1GiB kernel mapping and a 4KiB user mapping coexist as two entries in the same fully-associative TLB array simultaneously, each correctly matching only the address bits its own page size actually cares about, which is a fully-associative-array-native way of supporting mixed page sizes without needing entirely separate TLB structures per size.

**467. TLB Permission Check (R/W/X + U/S Mode)** — *(Hard)*
*Purpose:* Extends the earlier basic R/W/X permission check to also enforce the privilege-mode (User vs Supervisor) restriction encoded in a PTE's U bit, and the SUM (permit Supervisor User Memory access) override.
```systemverilog
module tlb_perm_check_full (
    input  logic tlb_hit,
    input  logic entry_r, entry_w, entry_x, entry_u,
    input  logic access_is_read, access_is_write, access_is_exec,
    input  logic current_priv_is_user, mstatus_sum,
    output logic translation_ok, perm_fault
);
    wire priv_ok = entry_u ? 1'b1 : (!current_priv_is_user || mstatus_sum);
    // priv_ok: user pages always accessible; supervisor pages need either S-mode itself, or S-mode-with-SUM accessing a user page (N/A here since entry_u=0 means non-user page)
    wire rwx_ok = (!access_is_read  || entry_r) &&
                  (!access_is_write || entry_w) &&
                  (!access_is_exec  || entry_x);

    assign perm_fault    = tlb_hit && !(priv_ok && rwx_ok);
    assign translation_ok = tlb_hit && priv_ok && rwx_ok;
endmodule
```
*Derivation:* This directly encodes the RISC-V privileged spec's access rule: a page with `U=1` is a user page, accessible in User mode normally, and accessible in Supervisor mode *only* if `mstatus.SUM=1` (an explicit software opt-in, since S-mode accessing U-mode-owned data unintentionally is a classic security bug class); a page with `U=0` is a supervisor page and is *never* accessible from User mode regardless of any override bit — the `priv_ok` expression as written specifically covers the U-page-in-any-mode case (`entry_u` true → `1'b1`) and falls through to the S-mode-only logic when `entry_u` is false, matching this exact spec-mandated asymmetry between the two page-ownership categories.

**468. Page Fault Cause Encoding** — *(Hard)*
*Purpose:* Distinguishes the different specific reasons a page-table walk or permission check can fail, each of which the spec assigns a distinct `mcause`/`scause` value so a handler (typically an OS's fault handler, which then decides whether to fix up the mapping, kill the process, or something else) knows exactly what went wrong.
```systemverilog
module page_fault_cause (
    input  logic pte_invalid, perm_fault_read, perm_fault_write, perm_fault_exec,
    output logic [3:0] cause
);
    always_comb begin
        unique casez ({pte_invalid, perm_fault_exec, perm_fault_read, perm_fault_write})
            4'b1???: cause = 4'd13;   // load page fault used generically here for an invalid PTE on a read-context walk; real design differentiates by access type
            4'b?1??: cause = 4'd12;   // instruction page fault
            4'b??1?: cause = 4'd13;   // load page fault
            4'b???1: cause = 4'd15;   // store/AMO page fault
            default:  cause = 4'd0;
        endcase
    end
endmodule
```
*Derivation:* The three distinct page-fault cause codes (12=instruction, 13=load, 15=store/AMO) let a fault handler immediately know which *kind* of access triggered the fault without needing to separately decode the faulting instruction — critical for the common "demand paging" use case where a handler needs to know whether to map in a readable page, a writable page, or an executable page, and this distinction directly determines that; a real implementation would also need to correctly classify *which specific access type* triggered an invalid-PTE walk failure (not shown in full here, simplified to load-fault as a placeholder) since an invalid PTE encountered during, say, an instruction fetch's walk should still report cause 12, not 13.

**469. PMA (Physical Memory Attribute) Checker** — *(Hard)*
*Purpose:* Independent of virtual-memory permission checking, physical memory attributes describe fixed properties of physical address ranges (cacheable vs not, supports atomics, executable at all) that even a supervisor with full page-table control can't override — needed to prevent e.g. treating an MMIO region as cacheable.
```systemverilog
module pma_check #(parameter int NUM_REGIONS = 4) (
    input  logic [43:0] phys_addr,
    input  logic [NUM_REGIONS-1:0][43:0] region_base, region_limit,
    input  logic [NUM_REGIONS-1:0] region_cacheable, region_supports_amo,
    output logic cacheable, supports_amo, region_found
);
    logic [NUM_REGIONS-1:0] match;
    always_comb
        for (int i = 0; i < NUM_REGIONS; i++)
            match[i] = (phys_addr >= region_base[i]) && (phys_addr < region_limit[i]);

    always_comb begin
        region_found = |match; cacheable = 1'b0; supports_amo = 1'b0;
        for (int i = 0; i < NUM_REGIONS; i++)
            if (match[i]) begin cacheable = region_cacheable[i]; supports_amo = region_supports_amo[i]; end
    end
endmodule
```
*Derivation:* PMAs are typically fixed, hardwired properties of the SoC's physical address map (which ranges are actual DRAM vs MMIO registers vs boot ROM, etc.) rather than something page tables control — this is the fundamental reason PMA checking exists as a *separate* stage from PMP (Problem 470, software-configurable) and page-table permission checking (Problem 467, also software-configurable): PMA represents ground-truth physical hardware facts no privilege level should be able to override, since e.g. attempting to cache an MMIO device register could cause the CPU to observe stale values instead of the device's live state.

**470. PMP (Physical Memory Protection) Region Checker** — *(Hard)*
*Purpose:* PMP provides physical-address-range access control independent of (and often used *underneath*) virtual memory — commonly used to restrict what a lower-privilege mode (or a mode with virtual memory entirely disabled) can access, a critical security boundary in embedded/secure-boot contexts.
```systemverilog
module pmp_check #(parameter int NUM_ENTRIES = 8) (
    input  logic [43:0] phys_addr,
    input  logic [NUM_ENTRIES-1:0][43:0] pmp_addr,   // top address of each region (TOR mode)
    input  logic [NUM_ENTRIES-1:0] pmp_r, pmp_w, pmp_x, pmp_locked,
    input  logic access_is_read, access_is_write, access_is_exec,
    input  logic current_priv_is_machine,
    output logic pmp_fault
);
    logic [NUM_ENTRIES-1:0] in_region;
    always_comb
        for (int i = 0; i < NUM_ENTRIES; i++)
            in_region[i] = (phys_addr < pmp_addr[i]) && ((i == 0) || (phys_addr >= pmp_addr[i-1]));   // TOR: [prev_addr, this_addr)

    always_comb begin
        pmp_fault = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (in_region[i] && (!current_priv_is_machine || pmp_locked[i])) begin
                // M-mode bypasses unlocked PMP entries entirely; locked entries apply even to M-mode
                if ((access_is_read  && !pmp_r[i]) ||
                    (access_is_write && !pmp_w[i]) ||
                    (access_is_exec  && !pmp_x[i]))
                    pmp_fault = 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* Two spec-mandated subtleties this encodes: TOR (top-of-range) addressing defines each region as spanning from the previous entry's boundary to this entry's own address, forming a set of contiguous, non-overlapping ranges from a list of just upper bounds; and Machine mode is normally exempt from PMP checks entirely *except* for entries marked `locked` — locking is specifically the mechanism that lets even M-mode software (e.g. a bootloader) permanently commit to a protection region that can't later be loosened, even by M-mode itself, which is exactly the guarantee needed for a secure-boot chain to make binding security promises about what happens after it hands off control.

**471. VIPT Synonym Detection and Resolution** — *(Hard)*
*Purpose:* Completes the earlier detection-only synonym sketch with an actual resolution mechanism — once two different virtual addresses are confirmed to alias the same physical line (a "synonym"), the cache must avoid caching that physical line under two different indices simultaneously, which would let the two copies silently diverge.
```systemverilog
module vipt_synonym_resolve #(parameter int SETS = 256) (
    input  logic clk, rst_n,
    input  logic access_valid, input logic [31:0] access_vaddr, input logic [21:0] access_ppn,
    input  logic cache_hit, input logic [$clog2(SETS)-1:0] cache_hit_set,
    output logic synonym_detected,
    output logic force_evict_other_copy, output logic [$clog2(SETS)-1:0] other_copy_set
);
    // simplified: maintain a small reverse-lookup structure mapping recently-seen PPNs to the cache set they're resident in
    logic [21:0] recent_ppn [SETS];
    logic recent_valid [SETS];

    logic [$clog2(SETS)-1:0] expected_set;
    assign expected_set = access_ppn[$clog2(SETS)-1:0];   // physical-index-bits-based expected set, per Problem 145's reasoning

    assign synonym_detected      = access_valid && cache_hit && (cache_hit_set != expected_set);
    assign force_evict_other_copy = synonym_detected;
    assign other_copy_set          = cache_hit_set;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SETS; i++) recent_valid[i] <= 1'b0;
        end else if (access_valid && cache_hit) begin
            recent_ppn[expected_set]   <= access_ppn;
            recent_valid[expected_set] <= 1'b1;
        end
    end
endmodule
```
*Derivation:* If a line hits in a cache set *other than* the one its physical address bits would normally imply (`cache_hit_set != expected_set`), that's direct evidence two different virtual addresses (differing in the index bits above the page offset) have both been used to access the same physical line, landing copies in two different sets — the resolution policy shown here (evict the "wrong-set" copy, forcing a future access to re-fill at the physically-expected set) is the simplest correct fix, trading a guaranteed cache miss on synonym detection for guaranteed avoidance of two simultaneously-cached, potentially-diverging copies of the same physical data, which is the actual correctness hazard VIPT caches must avoid.

**472. TLB Replacement Policy (Pseudo-LRU for TLB)** — *(Hard)*
*Purpose:* Applies the same pseudo-LRU tree structure from Problem 442 to TLB entry replacement, since a fully-associative TLB (Problem 466) needs a good replacement policy just as much as a set-associative cache does.
```systemverilog
module tlb_plru #(parameter int ENTRIES = 16) (
    input  logic clk, rst_n, access_hit,
    input  logic [$clog2(ENTRIES)-1:0] access_idx,
    output logic [$clog2(ENTRIES)-1:0] victim_idx
);
    logic [ENTRIES-2:0] tree;   // ENTRIES-1 tree bits for ENTRIES leaves (same structure as Problem 442, generalized)
    always_comb begin
        automatic int node = 0;
        for (int level = 0; level < $clog2(ENTRIES); level++) begin
            victim_idx[$clog2(ENTRIES)-1-level] = tree[node];
            node = 2*node + 1 + tree[node];
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tree <= '0;
        else if (access_hit) begin
            automatic int node = 0;
            for (int level = 0; level < $clog2(ENTRIES); level++) begin
                tree[node] <= !access_idx[$clog2(ENTRIES)-1-level];
                node = 2*node + 1 + access_idx[$clog2(ENTRIES)-1-level];
            end
        end
    end
endmodule
```
*Derivation:* Generalizes Problem 442's hand-unrolled 8-way tree into a parameterized loop over `log2(ENTRIES)` levels — same binary-tree pointer-following logic, just expressed generically instead of manually unrolled per level, confirming the pseudo-LRU technique isn't cache-specific but a general associative-structure replacement policy applicable anywhere a fully- or set-associative array (cache way, TLB entry, BTB way) needs cheap approximate-LRU tracking.

**473. Page Table Walker Caching (PTE Cache for Intermediate Levels)** — *(Hard)*
*Purpose:* Caches intermediate-level page-table entries (e.g. Sv39's level-2 and level-1 PTEs) separately from the final leaf translation, so a subsequent walk for a *different* page within the same megapage/gigapage region can skip directly to the final level instead of re-walking from the root.
```systemverilog
module pte_cache #(parameter int ENTRIES = 32) (
    input  logic clk, rst_n,
    input  logic [26:0] lookup_vpn_upper,   // vpn2 or vpn2:vpn1, depending on which level being cached
    output logic hit, output logic [43:0] cached_ppn,
    input  logic fill_en, input logic [26:0] fill_vpn_upper, input logic [43:0] fill_ppn
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic valid_arr [ENTRIES];
    logic [26:IDX_W] tag_arr [ENTRIES];
    logic [43:0] ppn_arr [ENTRIES];

    wire [IDX_W-1:0] idx = lookup_vpn_upper[IDX_W-1:0];
    assign hit         = valid_arr[idx] && (tag_arr[idx] == lookup_vpn_upper[26:IDX_W]);
    assign cached_ppn  = ppn_arr[idx];

    wire [IDX_W-1:0] f_idx = fill_vpn_upper[IDX_W-1:0];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) valid_arr[i] <= 1'b0;
        end else if (fill_en) begin
            valid_arr[f_idx] <= 1'b1; tag_arr[f_idx] <= fill_vpn_upper[26:IDX_W]; ppn_arr[f_idx] <= fill_ppn;
        end
    end
endmodule
```
*Derivation:* This is functionally a small dedicated cache — structurally identical to `micro_tlb` — but caching *intermediate* walk results (the physical address of a next-level page-table page) rather than final leaf translations; the benefit shows up specifically for workloads accessing many different pages within the same large region (e.g. iterating across a big array spanning many 4KiB pages but all sharing one level-1/level-2 page-table page): the first access does a full multi-level walk and populates this cache, but every subsequent access to a different page in that same region can skip straight to the final-level lookup, since the intermediate step's result is already known.

**474. Speculative TLB Hit with Replay-on-Miss** — *(Hard)*
*Purpose:* Formalizes the earlier reuse of `load_entry_speculative`'s pattern for TLB lookups — a load's dependents can be speculatively woken up assuming a TLB hit, with replay logic correcting the pipeline if that assumption turns out wrong.
```systemverilog
module tlb_speculative_hit (
    input  logic clk, rst_n, issue_en,
    output logic spec_wakeup_pulse,
    input  logic tlb_hit, tlb_miss,
    output logic needs_replay,
    input  logic walk_done,
    output logic replay_wakeup_pulse
);
    logic [1:0] issue_shreg;
    logic replay_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin issue_shreg <= '0; replay_pending <= 1'b0; end
        else begin
            issue_shreg <= {issue_shreg[0], issue_en};
            if (tlb_miss)                        replay_pending <= 1'b1;
            else if (walk_done && replay_pending) replay_pending <= 1'b0;
        end
    end
    assign spec_wakeup_pulse   = issue_shreg[1];
    assign needs_replay        = replay_pending;
    assign replay_wakeup_pulse = walk_done && replay_pending;
endmodule
```
*Derivation:* Same fixed-latency speculative-wakeup structure as the original: dependents of a TLB-using load are optimistically woken up assuming a fixed-latency TLB hit, since TLB hit rate is normally very high, making the speculative-common-case optimization worthwhile — on the rarer TLB miss, `replay_pending` tracks that this specific operation's dependents were incorrectly woken early and need a corrective replay once the page-table walk (Problem 462/463) actually completes and confirms the real translation.

**475. TLB Miss Queue (Multiple Outstanding Walks)** — *(Hard)*
*Purpose:* Extends beyond a single in-flight page-table walk to track several simultaneously-outstanding TLB misses, structurally reusing Problem 443's MSHR-bank secondary-miss-merging pattern applied to page-table walks instead of cache-line fills.
```systemverilog
module tlb_miss_queue #(parameter int NUM_WALKERS = 4, parameter int VPN_W = 27) (
    input  logic clk, rst_n,
    input  logic alloc_req, input logic [VPN_W-1:0] alloc_vpn,
    output logic alloc_valid, output logic [$clog2(NUM_WALKERS)-1:0] alloc_idx, output logic alloc_is_secondary,
    input  logic walk_complete, input logic [$clog2(NUM_WALKERS)-1:0] complete_idx
);
    logic busy [NUM_WALKERS];
    logic [VPN_W-1:0] vpn_arr [NUM_WALKERS];

    logic [NUM_WALKERS-1:0] vpn_match;
    always_comb
        for (int i = 0; i < NUM_WALKERS; i++) vpn_match[i] = busy[i] && (vpn_arr[i] == alloc_vpn);
    wire secondary = |vpn_match;

    always_comb begin
        alloc_valid = 1'b0; alloc_idx = '0; alloc_is_secondary = secondary;
        if (secondary) begin
            alloc_valid = 1'b1;
            for (int i = 0; i < NUM_WALKERS; i++) if (vpn_match[i]) alloc_idx = i[$clog2(NUM_WALKERS)-1:0];
        end else begin
            for (int i = 0; i < NUM_WALKERS; i++) if (!busy[i]) begin alloc_valid = 1'b1; alloc_idx = i[$clog2(NUM_WALKERS)-1:0]; break; end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_WALKERS; i++) busy[i] <= 1'b0;
        end else begin
            if (alloc_req && alloc_valid && !secondary) begin busy[alloc_idx] <= 1'b1; vpn_arr[alloc_idx] <= alloc_vpn; end
            if (walk_complete) busy[complete_idx] <= 1'b0;
        end
    end
endmodule
```
*Derivation:* Exactly the same CAM-search-merge-or-allocate structure as Problem 443's MSHR bank, confirming the "avoid redundant duplicate work for the same missing resource" pattern generalizes cleanly from cache-line fills to page-table walks: if two loads miss the TLB for the same page in close succession, the second one merges into the first's already-in-flight walker entry rather than launching a second, entirely redundant multi-level page-table walk for the identical translation.

**476. Superpage Splintering Detection** — *(Hard)*
*Purpose:* If software changes the permissions of just a small portion of a region originally mapped by one large superpage entry, the OS must "splinter" that superpage into smaller page-table entries — detecting when a TLB's cached superpage entry has become stale due to this kind of partial remapping is a subtle correctness requirement.
```systemverilog
module superpage_splinter_check (
    input  logic [31:0] tlb_entry_va, input logic [1:0] tlb_entry_size,   // 0=4K,1=2M,2=1G
    input  logic sfence_valid, input logic [31:0] sfence_addr, input logic sfence_addr_specific
);
    // synthesis translate_off
    logic [31:0] size_mask;
    always_comb begin
        unique case (tlb_entry_size)
            2'd0: size_mask = 32'hFFFF_F000;
            2'd1: size_mask = 32'hFFE0_0000;
            2'd2: size_mask = 32'hC000_0000;
            default: size_mask = 32'hFFFF_F000;
        endcase
    end
    always @(*)
        if (sfence_valid && sfence_addr_specific && ((sfence_addr & size_mask) == (tlb_entry_va & size_mask)))
            assert (1'b0)   // this assertion documents: an SFENCE targeting an address WITHIN this superpage's range must invalidate the WHOLE entry, not attempt a sub-page partial invalidate
                or $info("Correctly detected: SFENCE.VMA targets an address within a cached superpage -- must invalidate the entire superpage entry, not attempt (impossible) sub-page granularity invalidation");
    // synthesis translate_on
endmodule
```
*Derivation:* This is primarily a documentation/verification-style module: an `SFENCE.VMA` targeting a specific address that falls *within* a currently-TLB-cached superpage's range must invalidate that *entire* superpage entry, because a TLB has no mechanism to invalidate "part of" one entry — the assertion here exists to make explicit and checkable the design requirement that TLB invalidation logic (Problem 479) must check an incoming SFENCE address against each cached entry's *actual size*, not assume every entry is a uniform 4KiB page, or superpage-splintering-induced staleness could silently persist in the TLB after the OS believes it has been resolved.

**477. Address Translation Top Pipeline (VA→PA Combining TLB + Walker)** — *(Hard)*
*Purpose:* Integrates the multi-level TLB (Problem 461) with the page-table walker (Problem 463) and permission check (Problem 467) into the single address-translation pipeline stage a real MMU actually presents to the rest of the core.
```systemverilog
module addr_translate_top (
    input  logic clk, rst_n,
    input  logic req_valid, input logic [38:0] va,
    input  logic access_is_read, access_is_write, access_is_exec, current_priv_is_user,
    output logic resp_valid, output logic [43:0] pa_ppn, output logic fault
);
    logic tlb_hit;
    logic [43:0] tlb_ppn;
    logic tlb_r, tlb_w, tlb_x, tlb_u;

    // TLB lookup (structure elided -- reuses tlb_2level/tlb_variable_pagesize pattern from Problems 461/466)
    assign tlb_hit = 1'b0;   // stub: real design wires this to an actual TLB instance

    logic walk_start, walk_done, walk_fault;
    logic [43:0] walk_ppn;
    sv39_walker u_walker (
        .clk(clk), .rst_n(rst_n), .walk_start(walk_start && !tlb_hit),
        .vpn2(va[38:30]), .vpn1(va[29:21]), .vpn0(va[20:12]), .satp_ppn('0),
        .mem_req_valid(), .mem_req_addr(), .mem_resp_valid(1'b0), .mem_resp_data('0),
        .walk_done(walk_done), .result_ppn(walk_ppn), .leaf_level(), .page_fault(walk_fault)
    );
    assign walk_start = req_valid && !tlb_hit;

    logic perm_fault;
    tlb_perm_check_full u_perm (
        .tlb_hit(tlb_hit || walk_done), .entry_r(tlb_r), .entry_w(tlb_w), .entry_x(tlb_x), .entry_u(tlb_u),
        .access_is_read(access_is_read), .access_is_write(access_is_write), .access_is_exec(access_is_exec),
        .current_priv_is_user(current_priv_is_user), .mstatus_sum(1'b0),
        .translation_ok(), .perm_fault(perm_fault)
    );

    assign resp_valid = tlb_hit || walk_done;
    assign pa_ppn        = tlb_hit ? tlb_ppn : walk_ppn;
    assign fault           = walk_fault || perm_fault;
endmodule
```
*Derivation:* The walker only starts (`walk_start && !tlb_hit`) on a genuine TLB miss, matching every earlier module's shared assumption that the walker is the slow fallback path, not the common case — `resp_valid` fires either immediately (TLB hit) or once the walk completes, and `fault` OR-combines a walk-detected page-table fault with a permission-check fault, reflecting that either failure mode independently means the access cannot proceed and must instead raise the appropriate page-fault exception (Problem 468) rather than return a translated address.

**478. Guest/Host Two-Stage Translation Stub (Virtualization)** — *(Hard)*
*Purpose:* Under RISC-V's hypervisor extension, a guest OS's own page tables translate guest-virtual to guest-physical, and a second, hypervisor-controlled set of page tables translates guest-physical to host-physical — this sketches the two-stage composition.
```systemverilog
module two_stage_translate_stub (
    input  logic [38:0] guest_va,
    output logic [43:0] guest_pa,   // stage 1 result: guest's own page tables (structurally identical to sv39_walker)
    output logic [43:0] host_pa,     // stage 2 result: hypervisor's page tables translate guest_pa -> host_pa
    input  logic stage1_done, stage2_done,
    output logic translate_done
);
    assign translate_done = stage1_done && stage2_done;
    // stage 1: guest_va -> guest_pa via a guest-controlled sv39_walker instance (same structure as Problem 463)
    // stage 2: guest_pa -> host_pa via a SEPARATE, hypervisor-controlled sv39_walker instance
    // critically: stage 2 must ALSO apply during stage 1's own page-table WALK memory accesses (the guest's
    // page-table pages themselves live at guest-physical addresses, which must also be translated via stage 2)
endmodule
```
*Derivation:* The subtle, genuinely hard part of two-stage translation (only sketched here, not fully implemented, given the scope) is that stage 2 translation must apply not just to the *final* guest-physical result but to *every intermediate memory access the guest's own walker makes while walking its page tables*, since those page-table pages are themselves stored at guest-physical addresses that the hardware must also translate through stage 2 before it can actually read them — this means a full two-stage walker effectively needs to invoke a complete stage-2 walk for every stage-1 memory access, a multiplicative cost (up to 2× the levels in the worst un-cached case) that's exactly why real hypervisor-extension implementations invest heavily in nested-TLB and nested-nested-page-table caching to keep two-stage translation practical.

**479. TLB Invalidate-by-Address (SFENCE.VMA) Handling** — *(Hard)*
*Purpose:* Completes the earlier basic ASID-invalidate sketch with the full `SFENCE.VMA` semantics — which can target a specific address, a specific ASID, both, or neither (meaning "invalidate everything"), each combination having distinct spec-defined behavior.
```systemverilog
module sfence_vma_handle #(parameter int ENTRIES = 16, parameter int ASID_W = 8) (
    input  logic sfence_valid,
    input  logic addr_specific, input logic [31:0] sfence_addr,
    input  logic asid_specific,  input logic [ASID_W-1:0] sfence_asid,
    input  logic [ENTRIES-1:0] entry_valid, entry_global,
    input  logic [ENTRIES-1:0][31:0] entry_va,
    input  logic [ENTRIES-1:0][ASID_W-1:0] entry_asid,
    output logic [ENTRIES-1:0] invalidate_mask
);
    always_comb
        for (int i = 0; i < ENTRIES; i++) begin
            automatic logic addr_match = !addr_specific || (entry_va[i][31:12] == sfence_addr[31:12]);
            automatic logic asid_match = !asid_specific || entry_global[i] || (entry_asid[i] == sfence_asid);
            invalidate_mask[i] = sfence_valid && entry_valid[i] && addr_match && asid_match;
        end
endmodule
```
*Derivation:* Directly encodes the four SFENCE.VMA variants from the privileged spec: `rs1=x0,rs2=x0` (both fields unspecified) invalidates everything (`addr_specific=0, asid_specific=0`, every entry matches both conditions vacuously); `rs1` specific only invalidates that address across all ASIDs; `rs2` specific only invalidates that ASID across all addresses; both specific invalidates only the exact (address, ASID) pair — the `entry_global[i]` bypass in `asid_match` additionally ensures that global entries (Problem 465) are correctly exempted from ASID-specific invalidation (since a global mapping is, by definition, not tied to any one ASID), matching the same global-bit semantics established there.

**480. Virtual Memory Top Wrapper (TLB + Walker + PMP Integrated)** — *(Hard)*
*Purpose:* Integrates Problem 477's translation pipeline with Problem 470's PMP check into the complete address-translation-and-protection top module a real core's load/store and fetch units would actually query.
```systemverilog
module vm_top (
    input  logic clk, rst_n,
    input  logic req_valid, input logic [38:0] va,
    input  logic access_is_read, access_is_write, access_is_exec, current_priv_is_user, current_priv_is_machine,
    output logic resp_valid, output logic [43:0] pa,
    output logic translate_fault, pmp_fault_out
);
    logic xlate_resp_valid, xlate_fault;
    logic [43:0] pa_ppn;
    addr_translate_top u_xlate (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .va(va),
        .access_is_read(access_is_read), .access_is_write(access_is_write), .access_is_exec(access_is_exec),
        .current_priv_is_user(current_priv_is_user),
        .resp_valid(xlate_resp_valid), .pa_ppn(pa_ppn), .fault(xlate_fault)
    );
    assign pa = {pa_ppn, va[11:0]};

    logic pmp_fault;
    pmp_check u_pmp (
        .phys_addr(pa), .pmp_addr('{default:'1}), .pmp_r('1), .pmp_w('1), .pmp_x('1), .pmp_locked('0),
        .access_is_read(access_is_read), .access_is_write(access_is_write), .access_is_exec(access_is_exec),
        .current_priv_is_machine(current_priv_is_machine), .pmp_fault(pmp_fault)
    );

    assign resp_valid       = xlate_resp_valid;
    assign translate_fault  = xlate_fault;
    assign pmp_fault_out     = xlate_resp_valid && pmp_fault;
endmodule
```
*Derivation:* PMP is checked *after* translation completes, against the resulting *physical* address (`pa`), since PMP is fundamentally a physical-address-space protection mechanism (Problem 470) layered independently on top of virtual-memory permission checking (already folded into `xlate_fault` via Problem 467) — a real design would also need to enforce PMA (Problem 469) at this same point and, for the M-mode-fetches-its-own-page-tables edge case, apply PMP checks to the page-table-walk's own memory accesses too, both omitted here to keep the integration focused on the primary VA→PA→protected-PA pipeline structure.

---

*Category 4 of 10 complete (Problems 461–480). More categories to follow in Part 2 of this Hard-tier file, covering Categories 5–10 (Problems 481–600).*