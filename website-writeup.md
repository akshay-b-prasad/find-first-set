---
title: "Find First Set: What Three Architectures Taught Me About Critical Path Discipline"
date: "2026-05-26"
tags: ["RTL", "SystemVerilog", "Digital Design", "ASIC", "Yosys", "Verilator"]
summary: "Three hardware implementations of Find First Set Bit in SystemVerilog — sequential FSM, parallel combinational, and pipelined binary search — synthesized against a 7nm-approximate library. 66,536 simulation vectors, zero failures."
github: "https://github.com/akshay-b-prasad/find-first-set"
---

# Find First Set: What Three Architectures Taught Me About Critical Path Discipline

---

## The Results

The numbers first. Everything below is from real synthesis (Yosys 0.52 + ABC, ASAP7-approximate 7nm liberty) and simulation (Verilator 5.032, 66,536 vectors, zero failures).

| Metric | Sequential | Combinational | Pipeline |
|---|---|---|---|
| Cells | 322 | 168 | 239 |
| Flip-flops | 81 | 8 | 90 |
| Logic levels | 7 | 20 | 6 |
| Est. Fmax | ~7.1 GHz | ~2.5 GHz | ~8.3 GHz |
| Throughput | 1 / 66 cyc (worst-case) | 1 / cycle | 1 / cycle |
| Latency (min / avg / max) | 3 / 4.0 / 66 cycles | 1 cycle | 6 cycles |

*Fmax = 1 / (logic levels x 20 ps/level). Wire delay and setup time not included — post-PnR numbers will be 30-40% lower. Relative rankings hold across process nodes.*

![Area Comparison](assets/area_comparison.png)

![Throughput vs Latency](assets/throughput_vs_latency.png)

Three things this data shows immediately:

**Latency and Fmax are not the same thing.** The sequential design has the shallowest critical path (7 levels, ~7.1 GHz estimated) while having the worst latency (up to 66 cycles). A fast clock helps only if your logic actually fires every cycle.

**The combinational design is the area winner but the timing loser.** 168 cells and 8 FFs — smallest by every count — yet 20 logic levels makes it the slowest at high frequency. It trades timing margin for a small cell budget.

**The pipeline is the answer for any high-frequency datapath.** 6 total logic levels, 1 result per cycle after fill, and a structure that scales gracefully to wider widths. The 82 extra flip-flops compared to the combinational design are a fair price for 3.3x better estimated Fmax.

---

## Why This Matters in Production Silicon

Find First Set is not an academic exercise. It's a primitive that lives on the critical path of systems that actually need to go fast.

In an out-of-order processor's issue queue, FFS selects the oldest ready instruction from a ready vector on every clock cycle. In a network packet arbiter, it picks the highest-priority pending request from a grant bitmap. In an interrupt controller, it resolves the first pending IRQ in a priority bitmap. In a physical memory allocator, it finds the first free page. Every one of these use cases has the same property: the FFS result feeds downstream logic that cannot start until it arrives, so your FFS implementation is your critical path, not just on it.

Scaling from 16-bit to 64-bit to 256-bit at clock targets above 2 GHz is where this gets uncomfortable. What closes timing at 500 MHz on a 16-bit version often falls apart at 64-bit on a 2+ GHz target. I designed three implementations specifically to explore that failure regime and understand exactly where each architecture breaks down.

---

## Architecture 1: Sequential Shifter — Paying the Latency Tax

The sequential shifter is a three-state FSM (`IDLE -> RUNNING -> DONE`) that shifts the input register right one bit per cycle and checks bit 0 at each step.

At W=64 it synthesizes to **322 cells and 81 FFs** — actually the largest of the three designs by cell count. That surprises most people. The cell overhead comes from the 64-bit shift register, the 6-bit counter, the FSM logic, and the comparator, none of which the combinational and pipeline designs ever instantiate. This is not an area win.

What it is: a deliberate trade of latency for simplicity and low switching activity. On any given cycle, only a tiny slice of the design is active — one shift, one bit check, one counter increment. That has real value in:

- Control paths with relaxed timing constraints, where FFS runs infrequently and latency budget is loose
- Low-clock-frequency mixed-signal SoCs where you're optimizing for leakage and dynamic power, not cycle time
- Scenarios where the sheer simplicity of the design makes verification and integration straightforward

The critical path (7 logic levels) is the shallowest of the three designs because each cycle does minimal work: `counter` FF to comparator to `state` FF. The price is up to 66 cycles of latency for an all-zeros or MSB-only input.

Average measured latency across 66,536 vectors was **4.0 cycles**, not 33. That's the geometric distribution at work: roughly half of all inputs have bit 0 set (3-cycle result), a quarter have bit 1 as the LSB (4 cycles), and so on. If your inputs aren't pathological, the sequential design is cheaper in practice than the worst case suggests.

![Latency Distribution](assets/latency_distribution.png)

```systemverilog
RUNNING: begin
    if (shift_reg[0]) begin
        result <= counter;  no_set <= 1'b0;  state <= DONE;
    end else if (counter == CNT_MAX) begin
        result <= '0;  no_set <= 1'b1;  state <= DONE;
    end else begin
        shift_reg <= shift_reg >> 1;
        counter   <= counter + 1'b1;
    end
end
```

One implementation note: `result` and `no_set` are driven directly in `RUNNING` and held stable through `DONE`. An earlier draft double-buffered them through staging registers and forwarded in `DONE`. Removing that indirection saved 7 FFs with no functional change. Every flip-flop should have a reason to exist.

**Synthesis results (W=64):**

| Metric | Value |
|---|---|
| Cells | 322 |
| Flip-flops | 81 |
| Logic levels | 7 |
| Est. Fmax | ~7.1 GHz |
| Latency (min / avg / max) | 3 / 4.0 / 66 cycles |

---

## Architecture 2: Pure Combinatorial Encoder — Where the Math Lies

The core structure is a 6-stage binary mux tree. Each stage asks one question: does the lower half of the current window contain a set bit? If yes, keep the lower half and contribute a 0 to the result. If no, keep the upper half and contribute a 1. Repeat for log2(W) = 6 stages.

```
Stage 0: 64-bit window  → check lower 32 → take lower or upper half
Stage 1: 32-bit window  → check lower 16 → take lower or upper half
Stage 2: 16-bit window  → check lower  8 → take lower or upper half
Stage 3:  8-bit window  → check lower  4 → take lower or upper half
Stage 4:  4-bit window  → check lower  2 → take lower or upper half
Stage 5:  2-bit window  → check bit 0    → result[0] = ~lo_has_bit
```

Each stage is two operations: an OR-reduce and a mux. At 7nm, that's roughly 36-40 ps per stage, which should give 12 total gate levels. Synthesis measured **20 logic levels**.

**The gap is the OR-reduce fan-in problem.** OR-reducing 32 bits at stage 0 does not take 1 gate level — it takes roughly 5, because fan-in limits on standard cells force the OR tree to be built in multiple tiers. Synthesis cannot flatten 32 inputs into a single gate. At 20 ps/level on ASAP7, that's 400 ps of combinatorial delay before any wire delay, setup margin, or derating.

If your timing target is 3 GHz+, this design does not close. Design Compiler will flag WNS violations on the path from `data` to `result`, and no useful restructuring directive fixes the fundamental fan-in constraint. You'd be fighting the tool in a war you can't win.

The combinational design synthesizes to **168 cells and just 8 FFs** (output register only). It's the smallest design by cell count and delivers 1-cycle throughput, making it genuinely useful for moderate-frequency systems below 2 GHz where area and FF budget matter more than logic depth.

```systemverilog
genvar i;
for (i = 0; i < LOG2W; i++) begin : g_stage
    assign lo_has_bit      = |stage_win[i][HALF-1:0];
    assign next_win        = lo_has_bit ? stage_win[i][HALF-1:0]
                                        : stage_win[i][WSIZE-1:HALF];
    assign stage_win[i+1]  = {{(W-HALF){1'b0}}, next_win};
    assign result_bits[RIDX] = ~lo_has_bit;
end
```

The `generate` loop here is not shorthand for a `for` loop. A behavioral `for` loop in `always_comb` unrolls into a sequential chain of assignments — O(N) depth. `generate` instantiates parallel hardware at elaboration time, creating independent combinatorial paths for each level. There is no software analog to this distinction. Getting it wrong means your "parallel" design actually synthesizes to a priority chain of 64 serially-dependent muxes, which fails 1 GHz timing at 7nm with no additional margin.

**Synthesis results (W=64):**

| Metric | Value |
|---|---|
| Cells | 168 |
| Flip-flops | 8 |
| Logic levels | 20 |
| Est. Fmax | ~2.5 GHz |

![Logic Levels](assets/logic_levels.png)

---

## Architecture 3: Hierarchical Binary Search Pipeline — The Architect's Winner

This is the design I'd ship in a high-performance datapath.

The binary search from Architecture 2 makes exactly one decision per level: check the lower half, select which half to keep. Instead of resolving all 6 decisions in a single deep combinational cone, the pipeline executes each decision in a separate registered clock stage.

Each stage does two operations: one OR-reduce and one mux select. Rather than chaining all 6 stages into one long path, a flip-flop after each stage breaks the timing arc. Synthesis (using `ltp -noff`, which measures the longest path across all combinational logic) reported **6 total gate levels** — the most favorable of the three designs, and an estimated **~8.3 GHz** Fmax.

The structural advantage is that the stages are completely independent once intermediate state is registered. After the 6-cycle fill, one result emerges every clock cycle regardless of input value:

```
Cycle:     1    2    3    4    5    6    7    8    9
Input:     A    B    C    -    -    -    -    -    -
valid_in:  1    1    1    0    0    0    0    0    0
valid_out: 0    0    0    0    0    0    1    1    1
result:    -    -    -    -    -    -    A    B    C
```

If timing still doesn't close on an extreme frequency target, this structure offers one more lever: register between the OR-reduce and the mux within each stage, splitting 6 stages of 2 operations into 12 stages of 1 operation each. Latency rises to 12 cycles, throughput stays at 1 result per clock, and the per-stage critical path drops to a single gate level. No other FFS topology offers that kind of surgical timing leverage without a fundamental redesign.

```systemverilog
always_comb begin          // default-then-override, prevents latches
    nxt_res       = pipe_res[i];
    nxt_res[RIDX] = ~lo_has_bit;
end

always_ff @(posedge clk) begin
    if (!rst_n) begin ... end
    else begin
        pipe_win[i+1] <= nxt_win_w;
        pipe_res[i+1] <= nxt_res;
        pipe_vld[i+1] <= pipe_vld[i];
        pipe_nst[i+1] <= pipe_nst[i];
    end
end
```

One synthesis result worth highlighting: the theoretical FF count is 432 (6 stages x 72 bits of state per stage). Synthesis delivered **90 FFs**. The reason is that `pipe_win` is padded to W bits at every stage for uniform indexing, but only half the bits carry live data at each step. By stage 2, only 16 bits of the window are live. Yosys + ABC aggressively trim the zero-padded upper bits, reducing 432 theoretical FFs to 90 actual. You write the clean parameterized RTL; the tool handles the optimization.

**Synthesis results (W=64):**

| Metric | Value |
|---|---|
| Cells | 239 |
| Flip-flops | 90 |
| Logic levels | 6 |
| Est. Fmax | ~8.3 GHz |

---

## Architect's Notes: The Pitfalls That Actually Bite

### The All-Zeros Hazard

A naive FFS implementation returns index 0 when the input is `64'h0`. That's a silent functional bug: the result is indistinguishable from "bit 0 is the lowest set bit," which is a valid result for an input of `64'h1`.

Downstream consumers that check only the result index will silently misfire on all-zero inputs. In a priority arbiter, this manifests as phantom grant signals. In a scheduler, it manifests as issuing to a non-ready instruction. Both are the kind of bug that passes directed testbenches and only surfaces under random regression or, worse, post-silicon.

The correct contract is to qualify `result` with a `no_set` flag on the same clock edge. No consumer should act on `result` without first checking that `no_set` is deasserted. All three designs implement this explicitly:

```systemverilog
output logic                  valid_out,
output logic                  no_set
```

If you're integrating an FFS block you didn't write, the first thing to verify is whether it exposes a valid `no_set` output and whether the consumer actually uses it.

### Synthesis-Simulation Mismatches in Behavioral Loop Implementations

Two patterns in behavioral RTL commonly produce simulation-synthesis divergence in FFS implementations:

**Unbounded loop variables.** A behavioral `for` loop scanning for the first set bit with a variable assigned conditionally inside the loop will simulate correctly but synthesize to a priority chain of muxes, not a parallel structure. The synthesis result is functionally correct but has O(N) depth — which you only discover when you look at the timing report and see 64 logic levels where you expected log2(64) = 6.

**X-propagation on reset.** If the shift register or pipeline stages aren't reset to a defined state, an X-propagating simulator (Cadence Xcelium in full X-prop mode, or VCS with appropriate flags) will propagate Xs through the result on the first cycle out of reset. Most simulators default to 0 for uninitialized flops, masking the issue. The physical design has no such guarantee. Synchronous resets to zero are not just good practice; they're necessary for X-clean simulation.

### Timing Sign-Off Reality

The Fmax estimates here use a simple formula: `1 / (logic levels x 20 ps/level)`. That's a reasonable first-order approximation for ASAP7 standard cells, but the actual post-layout number will be 30-40% lower once you add wire delay, setup time margin, derating for process/voltage/temperature corners, and clock skew between launch and capture FFs. The pipeline design at 8.3 GHz estimated becomes something closer to 5-6 GHz at sign-off. Still the clear winner among the three, but raw RTL numbers should never be quoted in a tape-out review without that caveat.

---

## Verification: 66,536 Test Vectors

Results were extracted through an automated flow, not manual runs.

**Functional simulation** uses a Python testbench generator that drives Icarus Verilog and Verilator via `make`. All three designs run against the same software golden reference (a simple bit-scan loop). The test suite is structured in two layers:

*Directed vectors* target specific boundary conditions and architectural corner cases:
- `data = 0` — verifies `no_set` assertion and no phantom result
- `data = 1` — minimum latency path (bit 0 set)
- `data = all-ones` — same fast path, all-ones input
- MSB-only — sequential worst case (66 cycles)
- Full power-of-2 sweep — exercises all 64 single-bit positions, confirming every result encoding
- Alternating patterns (`0xAAAA...`, `0x5555...`) — interleaved set/unset bits
- Known worked example from documentation (`0x0000_0000_0048_0200 -> bit 9`)

*Random vectors*: 10,000 uniformly random 64-bit inputs stress the full input space beyond directed coverage.

*Exhaustive 16-bit sweep*: all 65,536 possible 16-bit inputs were run through Verilator. This provides complete functional coverage of the 16-bit input space and is the primary regression check that catches any encoding error in the result logic.

**Synthesis automation** uses parameterized Yosys scripts per design. A shell wrapper sweeps all three, runs `ltp -noff` to extract combinational depth, and parses cell and FF counts into a structured summary table automatically.

**Latency profiling**: each Verilator harness logs the exact cycle count per input vector to CSV. Python postprocessing generates the latency distribution histogram and throughput-vs-latency scatter plots from real simulation data.

```
make syntax    OK  All 3 RTL files — iverilog syntax clean
make sim       OK  10,071 vectors, 0 failures  (Icarus Verilog 12.0)
make verilator OK  66,536 vectors x 3 designs, 0 failures  (Verilator 5.032)
make synth     OK  Yosys 0.52 + ABC, ASAP7-approximate 7nm
make plot      OK  5 charts generated from real simulation data
```

To reproduce with the actual ASAP7 PDK for sign-off-quality numbers, replace the approximate liberty stub in `synth/*.ys` with `asap7_TT_08032018.lib` and run with OpenSTA for proper timing analysis.

---

## What I'd Do Differently at 256-bit

Scaling to 256-bit is where the architectural decision becomes starker. The combinational design at W=256 has log2(256) = 8 theoretical stages, but the OR-reduce fan-in problem at stage 0 — now reducing 128 bits — pushes the measured depth well above 30 logic levels. At 7nm, that's 600+ ps before wire delay. It doesn't close above roughly 1.5 GHz.

The pipeline design scales gracefully: 8 stages instead of 6, 8-cycle fill latency instead of 6, same 2-operation critical path per stage. The RTL requires no changes beyond updating the `W` parameter. The `generate`-based structure is precisely why: the loop unrolls to as many stages as the width requires, and synthesis trims the zero-padded window bits at each stage exactly as it does at 64-bit.

That's the right answer for a 256-bit FFS in a high-performance datapath.

---

## Tools

| Tool | Version | Role |
|------|:-------:|------|
| Icarus Verilog | 12.0 | Functional simulation |
| Verilator | 5.032 | Cycle-accurate simulation, C++ harnesses |
| Yosys | 0.52 | Synthesis, ABC optimization |
| Python | 3.14 | Chart generation and test automation (matplotlib, numpy) |
| ASAP7 approx. lib | — | 7nm-approximate standard cell liberty stub |

**[View on GitHub](https://github.com/akshay-b-prasad/find-first-set)**
