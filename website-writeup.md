---
title: "Find First Set: What Three Architectures Taught Me About Critical Path Discipline"
date: "2026-05-26"
tags: ["RTL", "SystemVerilog", "Digital Design", "ASIC", "Yosys", "Verilator"]
summary: "Three hardware implementations of Find First Set Bit in SystemVerilog — sequential FSM, parallel combinational, and pipelined binary search — synthesized against a 7nm-approximate library. 10,071 simulation vectors, zero failures."
github: "https://github.com/akshay-b-prasad/find-first-set"
---

# Find First Set: What Three Architectures Taught Me About Critical Path Discipline

---

## Why This Matters in Production Silicon

Find First Set isn't an academic exercise. It's a primitive that lives on the critical path of systems that actually need to go fast.

In an out-of-order processor's issue queue, FFS selects the oldest ready instruction from a ready vector on every clock cycle. In a network packet arbiter, it picks the highest-priority pending request from a grant bitmap. In a cache radix-tree walker or a TLB miss handler, it resolves the first valid entry in a tag array. Every one of these use cases has the same property: the FFS result feeds downstream logic that cannot start until it arrives, which means your FFS implementation *is* your critical path, not just *on* it.

Scaling from 16-bit to 64-bit to 256-bit at clock targets above 2 GHz is where this gets uncomfortable. What closes timing at 500 MHz on a 16-bit version often falls apart at 64-bit on a 2+ GHz target. I designed three implementations specifically to explore that failure regime and understand exactly where each architecture breaks down.

All three were synthesized with Yosys against an ASAP7-approximate 7nm library and verified across 66,536 simulation vectors. The numbers below are real.

---

## The Three Architectures: An Honest Trade-off Analysis

### Architecture 1: Sequential Shifter — Paying the Latency Tax Deliberately

The sequential shifter is a three-state FSM (`IDLE → RUNNING → DONE`) that shifts the input register right one bit per cycle and checks bit 0 at each step.

The immediate reaction from most engineers is to dismiss this as "slow." That reaction is understandable but misses the point. There are real design scenarios where you *want* to pay a latency tax in exchange for area and power savings:

- **Control paths with relaxed timing constraints**, where FFS runs infrequently and latency budget is loose
- **Area-constrained designs** where every cell counts and the FFS result isn't on the microarchitectural critical path
- **Low-clock-frequency mixed-signal SoCs** where you're optimizing for leakage and dynamic power, not cycle time

At W=64, this design synthesized to **322 cells and 81 FFs** with a critical path of just 7 logic levels (~7.1 GHz estimated Fmax). The shallow critical path is a direct consequence of doing minimal work each cycle: one shift, one bit check, one counter increment. The price is up to 66 cycles of latency for an all-zeros or MSB-only input.

Average measured latency across 66,536 vectors was **4.0 cycles**, not 33. That's the geometric distribution at work: roughly half of all inputs have bit 0 set (3-cycle result), a quarter have bit 1 as the LSB (4 cycles), and so on. If your inputs aren't pathological, the sequential design is a lot cheaper than the worst case suggests.

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

![Latency Distribution](assets/latency_distribution.png)

---

### Architecture 2: Pure Combinatorial Encoder — Where the Math Lies

The two's complement isolation trick is one of those things that looks almost too clean on paper:

```
isolated_lsb = data & (~data + 1)
```

Negate the input, AND it with the original. The carry from `~data + 1` propagates through every trailing zero below the LSB, flipping them to 1. The LSB stops the carry. The AND masks everything above. You're left with a one-hot vector, which a parallel OR-tree then encodes to binary in O(log N) depth.

**The problem is that the math hides the silicon reality.**

The `~data + 1` computation requires a ripple-carry adder. Even though it maps to combinatorial logic, carry propagation creates a chain of dependent gate levels that synthesis cannot fully eliminate. The OR-tree stages compound on top of this. At W=64, this design measured **20 logic levels** in synthesis, compared to a theoretical minimum of 12.

The gap comes from OR-reduce fan-in at the wider early stages. OR-reducing 32 bits takes roughly 5 gate levels due to fan-in limits on standard cells, not 1. Synthesis cannot flatten this into a single gate. At 20 ps/level on ASAP7, that's 400 ps of combinatorial delay — a hard ceiling around 2.5 GHz before you've added any wire delay, setup margin, or derating.

If your timing target is 3 GHz+, this design simply does not close. Design Compiler or Fusion Compiler will flag WNS violations on the path from `data` to `result`, and there's no useful restructuring directive that fixes the fundamental fan-in problem. You'd be fighting the tool in a war you can't win.

The combinatorial design synthesized to **168 cells and just 8 FFs** (output register only). It's the smallest design and has 1-cycle throughput, which makes it attractive for moderate-frequency systems below 2 GHz where the FF budget matters more than the logic depth. Above that, it's a timing liability.

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

The `generate` loop here is not shorthand for a `for` loop. A behavioral `for` loop in `always_comb` unrolls into a sequential chain of assignments — O(N) depth. `generate` instantiates parallel hardware at elaboration time, creating independent combinatorial paths for each level. There is no software analog to this distinction. Getting it wrong means your "parallel" design actually synthesizes to a priority chain of 64 serially-dependent muxes, which fails 1 GHz timing at 7nm without much additional margin.

**Synthesis results (W=64):**

| Metric | Value |
|---|---|
| Cells | 168 |
| Flip-flops | 8 |
| Logic levels | 20 |
| Est. Fmax | ~2.5 GHz |

![Logic Levels](assets/logic_levels.png)

---

### Architecture 3: Hierarchical Binary Search Pipeline — The Architect's Winner

This is the one I'd ship in a high-performance datapath.

The binary search formulation divides the input vector into halves recursively. At each stage: does the lower half contain a set bit? If yes, restrict the search window to the lower half and contribute a `0` to the result. If no, restrict to the upper half and contribute a `1`. Repeat for log₂(W) = 6 stages.

Each stage does exactly 2 gate levels of work: one OR-reduce and one mux. At 7nm, that's roughly 36-40 ps of logic delay per stage, well within a sub-GHz register-to-register timing arc. Synthesis measured **6 logic levels** total, estimating **~8.3 GHz** Fmax.

The structural advantage is that the stages are completely independent once you register the intermediate state. A pipeline register after every stage gives you a 6-stage design with:

- **Throughput:** 1 result per clock cycle after fill
- **Latency:** exactly 6 cycles, deterministic regardless of input value
- **Critical path:** 2 gate levels per stage, trivially timing-closure friendly

More importantly, this structure gives you a lever that neither of the other two designs has. If you're targeting an unusually aggressive clock frequency and 6 logic levels still doesn't close, you can insert an additional register stage in the middle of the tree and cut the critical path to 1 gate level per stage. You pay a latency penalty (7 cycles instead of 6) but your throughput never drops. No other FFS topology offers that flexibility without a fundamental redesign.

```
Cycle:     1    2    3    4    5    6    7    8    9
Input:     A    B    C    –    –    –    –    –    –
valid_in:  1    1    1    0    0    0    0    0    0
valid_out: 0    0    0    0    0    0    1    1    1
result:    –    –    –    –    –    –    A    B    C
```

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

One synthesis result worth highlighting: the theoretical FF count is 432 (6 stages × 72 bits of state per stage). Synthesis delivered **90 FFs**. The reason is that `pipe_win` is padded to W bits at every stage for uniform indexing, but only half the bits carry live data at each step. By stage 2, only 16 bits of the window are live. Yosys + ABC aggressively trim the zero-padded upper bits, reducing 432 theoretical FFs to 90 actual. You write the clean parameterized RTL; the tool handles the optimization.

**Synthesis results (W=64):**

| Metric | Value |
|---|---|
| Cells | 239 |
| Flip-flops | 90 |
| Logic levels | 6 |
| Est. Fmax | ~8.3 GHz |

![Area Comparison](assets/area_comparison.png)

---

## Master Comparison

| Metric | Sequential | Combinatorial | Pipeline |
|---|---|---|---|
| Cells | 322 | 168 | 239 |
| Flip-flops | 81 | 8 | 90 |
| Logic levels | 7 | 20 | 6 |
| Est. Fmax | ~7.1 GHz | ~2.5 GHz | ~8.3 GHz |
| Throughput | 1 / 66 cyc | 1 / cycle | 1 / cycle |
| Latency (min/max) | 3–66 cyc | 1 cyc | 6 cyc |

*Fmax estimates use 20 ps/level. With full ASAP7 PDK and OpenSTA back-annotation, absolute numbers drop 30-40%. The relative rankings hold.*

![Throughput vs Latency](assets/throughput_vs_latency.png)

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

If you're integrating an FFS block you didn't write, the first thing to check is whether it has a valid `no_set` output and whether the consumer actually uses it.

### Synthesis-Simulation Mismatches in Behavioral Loop Implementations

Two patterns in behavioral RTL commonly produce simulation-synthesis divergence in FFS implementations:

**Unbounded loop variables.** A behavioral `for` loop scanning for the first set bit with a variable that gets assigned conditionally inside the loop will simulate correctly but synthesize to a priority chain of muxes, not a parallel structure. The synthesis result is functionally correct but has O(N) depth — which you only discover when you look at the timing report and see 64 logic levels where you expected log₂(64) = 6.

**X-propagation on reset.** If the shift register or pipeline stages aren't reset to a defined state, an X-propagating simulator (Cadence Xcelium in full X-prop mode, Synopsys VCS with appropriate flags) will propagate Xs through the result on the first cycle out of reset. Most simulators default to 0 for uninitialized flops, masking the issue. The physical design has no such guarantee. Synchronous resets to zero are not just good practice; they're necessary for X-clean simulation.

### Timing Sign-Off Reality

The Fmax estimates here use a simple formula: `1 / (logic levels × 20 ps/level)`. That's a reasonable first-order approximation for ASAP7 standard cells, but the actual post-layout number will be 30-40% lower once you add wire delay, setup time margin, derating for process/voltage/temperature corners, and clock skew between launch and capture FFs. The pipeline design at 8.3 GHz estimated becomes something closer to 5-6 GHz at sign-off. Still the clear winner among the three, but raw RTL numbers should never be quoted in a tape-out review without that caveat.

---

## Benchmarking Methodology

Results were extracted through an automated flow rather than manual runs:

- **Functional simulation:** A Python testbench generator produces directed vectors (zero, all-ones, MSB-only, full power-of-2 sweep, alternating patterns) and random vectors, then drives Icarus Verilog and Verilator via `make`. All three designs run against the same software golden reference.
- **Synthesis automation:** Yosys synthesis scripts are parameterized per-design. A shell wrapper sweeps all three, runs `ltp -noff` to extract logic depth, and parses cell and FF counts into a structured summary table automatically.
- **Latency profiling:** Each Verilator harness logs the exact cycle count per input vector to CSV. Python postprocessing generates latency distribution histograms and throughput-vs-latency scatter plots from real simulation data.

```
make syntax    ✅  All 3 RTL files — iverilog syntax clean
make sim       ✅  10,071 vectors, 0 failures  (Icarus Verilog 12.0)
make verilator ✅  66,536 vectors × 3 designs, 0 failures  (Verilator 5.032)
make synth     ✅  Yosys 0.52 + ABC, ASAP7-approximate 7nm
make plot      ✅  5 charts generated from real simulation data
```

To reproduce with the actual ASAP7 PDK for sign-off-quality numbers, replace the approximate liberty stub in `synth/*.ys` with `asap7_TT_08032018.lib` and run with OpenSTA for proper timing analysis.

---

## What I'd Do Differently at 256-bit

Scaling to 256-bit is where the architectural decision becomes even starker. The combinatorial design at W=256 has log₂(256) = 8 theoretical stages, but the fan-in problem at stage 0 (OR-reducing 128 bits) pushes the measured depth well above 30 logic levels. At 7nm, that's 600+ ps before wire delay. It doesn't close above ~1.5 GHz.

The pipeline design scales gracefully: 8 stages instead of 6, 8-cycle fill latency instead of 6, same 2-gate-level critical path per stage. The RTL requires no changes beyond updating the `W` parameter. That's the right answer for a 256-bit FFS in a high-performance datapath, and the parameterized `generate` structure is precisely why.

---

## Tools

| Tool | Version | Role |
|------|:-------:|------|
| Icarus Verilog | 12.0 | Functional simulation |
| Verilator | 5.032 | Cycle-accurate simulation, C++ harnesses |
| Yosys | 0.52 | Synthesis, ABC optimization |
| Python | 3.14 | Chart generation and test automation (matplotlib, numpy) |
| ASAP7 approx. lib | — | 7nm-approximate standard cell library |

**[View on GitHub](https://github.com/akshay-b-prasad/find-first-set)**
