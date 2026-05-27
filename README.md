# Find First Set Bit: Three RTL Architectures

![SystemVerilog](https://img.shields.io/badge/RTL-SystemVerilog-blue?logo=verilog&logoColor=white)
![Yosys](https://img.shields.io/badge/Synthesis-Yosys-orange?logo=gnubash&logoColor=white)
![Verilator](https://img.shields.io/badge/Simulation-Verilator-green?logo=cplusplus&logoColor=white)
![Library](https://img.shields.io/badge/Library-ASAP7_7nm-purple)
![License](https://img.shields.io/badge/License-MIT-brightgreen)

`BSF` on x86. `CTZ` on ARM. Find First Set shows up in round-robin arbiters, out-of-order schedulers, floating-point normalizers, interrupt controllers, and memory allocators, always on the critical path.

Three independent SystemVerilog implementations, synthesized against an ASAP7-approximate 7nm library, verified across 66,536 simulation vectors. The function is simple by design: the architecture choices, not the algorithm, are the point.

---

## The Problem

**Find First Set (FFS):** given an N-bit input vector, return the 0-indexed position of the lowest set bit. If no bit is set, assert a `no_set` flag.

```
Formal definition:
  result = min { k : data[k] = 1 }
  no_set = (data == '0)
```

This appears in more real systems than you might expect:

| Use Case | Why FFS? |
|---|---|
| Round-robin arbiter | Find next pending requestor in a rotating bitmap |
| Out-of-order scheduler | Find oldest ready instruction in the ready vector |
| Floating-point normalization | Leading zero count before mantissa shift |
| Interrupt controller | Find highest-priority pending IRQ |
| Memory allocator | Find first free page in a physical page bitmap |

In each of these, FFS sits on the critical path. That's where the design question gets interesting.

**Worked example:**

```
data  = 64'h0000_0000_0048_0200
      = 0000...0000 0100 1000 0000 0010 0000 0000

Bit positions set: 9, 11, 18, 22
FFS result        = 9  (the lowest set bit, 0-indexed)
```

---

## Design Space

Before writing a single line of RTL, a real designer asks: **what are the constraints?** Area, latency, and throughput form a triangle. You can optimize two, but the third fights back.

```
  ┌─────────────────────┬────────────┬──────────────┬───────────┐
  │ Design              │ Latency    │ Throughput   │ Area      │
  ├─────────────────────┼────────────┼──────────────┼───────────┤
  │ Sequential (FSM)    │ 3–66 cyc   │ 1/66 cyc⁻¹   │ ░░░░░░░   │
  │ Combinational       │ 1 cyc      │ 1 cyc⁻¹      │ ░░░       │
  │ Pipeline (log₂ BST) │ 6 cyc      │ 1 cyc⁻¹      │ ░░░░░     │
  └─────────────────────┴────────────┴──────────────┴───────────┘
```

The combinational and pipeline designs achieve identical throughput, but the combinational design packs all the work into a single deep cone while the pipeline spreads it across 6 shallow stages. That difference is the entire story of this project.

![Tradeoff Radar](assets/tradeoff_radar.png)

---

## Unified Interface

All three designs share the same port signature so they can be swapped without changing the surrounding system:

```systemverilog
module ffs_<name> #(parameter int W = 64) (
    input  logic                  clk,
    input  logic                  rst_n,      // active-low synchronous reset
    input  logic                  valid_in,   // assert for 1 cycle with new data
    input  logic [W-1:0]          data,
    output logic [$clog2(W)-1:0]  result,     // 0-indexed position of lowest set bit
    output logic                  valid_out,  // 1-cycle pulse when result is ready
    output logic                  no_set      // asserted alongside valid_out if data == '0
);
```

**Latency contract (W=64):**
- `ffs_combinational`: exactly 1 cycle
- `ffs_pipeline`: exactly 6 cycles (`$clog2(W)`)
- `ffs_sequential`: 3 to 66 cycles (data-dependent; 3 when bit 0 is set, 66 when all zeros)

---

## Design 1: Sequential Shift-and-Check

### Architecture

A three-state FSM walks bit-by-bit through the input, shifting right each cycle until it finds a set bit or exhausts all positions.

```
                     valid_in
  IDLE ──────────────────────────────► RUNNING
   ▲                                      │
   │                              shift_reg[0]=1
   │                              counter==W-1  ───► DONE ──► valid_out pulse
   │                                                   │
   └───────────────── valid_in=0 ─────────────────────┘
                          (or valid_in=1 → back to RUNNING immediately)

  RUNNING each cycle:
    shift_reg  ──shift right──►  shift_reg
    counter    ──+ 1──────────►  counter
    shift_reg[0]=1 ?  → DONE, result=counter
    counter==W-1 ?    → DONE, no_set=1
    else              → stay RUNNING
```

### RTL Highlight

```systemverilog
// rtl/ffs_sequential.sv — the full always_ff block
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state <= IDLE;  shift_reg <= '0;  counter <= '0;
        result <= '0;   no_set <= 0;      valid_out <= 0;
    end else begin
        valid_out <= 1'b0;          // default: deassert every cycle
        unique case (state)
            IDLE: begin
                counter <= '0;
                if (valid_in) begin shift_reg <= data; state <= RUNNING; end
            end
            RUNNING: begin
                if (shift_reg[0]) begin                  // found it
                    result <= counter;  no_set <= 0;  state <= DONE;
                end else if (counter == CNT_MAX) begin   // exhausted all bits
                    result <= '0;  no_set <= 1'b1;  state <= DONE;
                end else begin                           // keep searching
                    shift_reg <= shift_reg >> 1;
                    counter   <= counter + 1'b1;
                end
            end
            DONE: begin
                valid_out <= 1'b1;                       // 1-cycle pulse
                counter   <= '0;
                if (valid_in) begin shift_reg <= data; state <= RUNNING; end
                else               state <= IDLE;
            end
            default: state <= IDLE;
        endcase
    end
end
```

A few choices worth explaining:

- Synchronous reset throughout. The ASAP7 library has smaller cells for synchronous FFs, and it keeps reset-tree timing simpler than async.
- Shift right, not left. Bit 0 is always the check point, so one wire tap per cycle and no extra gate levels needed.
- `valid_out` defaults to 0 each clock to prevent the output register from inferring a latch.
- DONE chains directly to RUNNING on a back-to-back request, skipping IDLE entirely. No throughput penalty for streaming workloads.
- No staging registers. An earlier draft buffered `result` and `no_set` into `result_r`/`no_set_r` and forwarded them in DONE. Cutting those staging registers saved 7 FFs for no functional gain, since DONE holds the outputs stable anyway.

### Performance

Measured on 66,536 vectors (Verilator, exhaustive 16-bit sweep + random 64-bit):

| Metric | Value |
|---|---|
| Minimum latency | **3 cycles** (bit 0 set: IDLE→RUNNING, RUNNING→DONE, DONE→valid_out) |
| Maximum latency | **66 cycles** (W=64: all-zeros or MSB-only input) |
| Average latency | **4.00 cycles** (dominated by the many inputs with low-order bits set) |

The average of 4.0 reflects that in the exhaustive 16-bit sweep, roughly 50% of all inputs have bit 0 set (3-cycle result), 25% have bit 1 as LSB (4 cycles), and so on. The distribution is geometric.

![Latency Distribution](assets/latency_distribution.png)

### Synthesis Results (Yosys, ASAP7-approximate 7nm)

| Metric | Value |
|---|---|
| Cell count | **322** |
| Flip-flop count | **81** |
| Logic levels (critical path) | **7** |
| Estimated Fmax | **~7.1 GHz** |

FF breakdown for W=64:

| Register | Bits | Role |
|---|---|---|
| `shift_reg` | 64 | current search window |
| `counter` | 6 | current bit index (log₂64) |
| `state` | 2 | FSM state (3-state, binary encoded) |
| `result` | 6 | output, set on RUNNING→DONE |
| `valid_out` | 1 | output valid pulse |
| `no_set` | 1 | no-set flag |
| **Total** | **80** | (synthesis: 81 after mapping overhead) |

The critical path is `counter` FF → 6-bit comparator → `state` FF: roughly 7 gate levels, the shallowest of the three designs.

### When to Use

- Control paths where throughput is not a premium and latency budget is loose
- FFS sits off the critical path and fires infrequently
- Designs where simplicity and low switching activity matter more than cell count

---

## Design 2: Full Parallel Combinational

### Architecture

Two modes, same result: compute the answer entirely in combinational logic and register the output once.

#### MODE=0: Isolate-and-Encode

The two's complement trick: `data & (~data + 1)` isolates exactly the lowest set bit into a one-hot vector.

```
  data     = ...1101_1010_0000_0000
  ~data    = ...0010_0101_1111_1111
  ~data+1  = ...0010_0110_0000_0000   ← carry kills all bits above LSB
  AND      = ...0000_0010_0000_0000   ← only bit 9 remains (one-hot)
```

Why it works: `~data + 1` = `-data` in two's complement. The addition propagates a carry through all trailing zeros below the LSB, flipping them to 1. The LSB itself stops the carry. The AND masks out everything above.

After isolation, a parallel OR-tree encodes the one-hot position into binary: result bit `b` = OR of all one-hot positions `k` where bit `b` of `k` is set. Depth = log₂(W).

#### MODE=1: Binary Mux Tree *(default)*

Recursive binary search in hardware. Each of log₂(W) = 6 stages halves the search window:

```
  Stage 0: 64-bit window → check lower 32 bits → take lower or upper half
  Stage 1: 32-bit window → check lower 16 bits → take lower or upper half
  Stage 2: 16-bit window → check lower  8 bits → take lower or upper half
  Stage 3:  8-bit window → check lower  4 bits → take lower or upper half
  Stage 4:  4-bit window → check lower  2 bits → take lower or upper half
  Stage 5:  2-bit window → check bit 0         → result[0] = ~lo_has_bit

  result = concatenation of the 6 offset bits (0=went lower, 1=went upper)
```

Each stage is 2 gate levels: an OR-reduce and a mux. Six stages = 12 gate levels minimum; synthesis measured **20 levels** for W=64 due to OR-reduce fan-in at the wider early stages.

### Why Not casez?

A `casez` priority encoder for W=64 synthesizes to a priority chain: a sequence of 64 muxes where each depends on the previous. That's 64 gate levels. At 7nm (~18 ps/level) the delay is ~1.15 ns, capping Fmax at ~870 MHz before wire delay or setup time. The design fails 1 GHz timing with no margin.

A `for` loop in `always_comb` produces the same chain; the synthesizer unrolls it into 64 serial assignments.

The `generate`-based mux tree achieves O(log N) depth because the tree is explicit at **elaboration time**. Every level is computed independently. This is the fundamental reason `generate` exists in SystemVerilog: to express parallel hardware structure that a for-loop cannot.

### RTL Highlight

```systemverilog
// rtl/ffs_combinational.sv — the binary mux tree (MODE=1)
logic [W-1:0]     stage_win  [LOG2W+1];   // search window, narrows each stage
logic [LOG2W-1:0] result_bits;

assign stage_win[0] = data;

genvar i;
for (i = 0; i < LOG2W; i++) begin : g_stage
    localparam int WSIZE = W >> i;        // window width at this stage
    localparam int HALF  = WSIZE >> 1;    // lower/upper split point
    localparam int RIDX  = LOG2W - 1 - i; // which result bit this stage drives

    logic              lo_has_bit;
    logic [HALF-1:0]   next_win;

    assign lo_has_bit = |stage_win[i][HALF-1:0];              // OR-reduce: 1 level
    assign next_win   = lo_has_bit ? stage_win[i][HALF-1:0]   // mux: 1 level
                                   : stage_win[i][WSIZE-1:HALF];

    // Single continuous assign — zero-pads unused upper bits in one driver
    assign stage_win[i+1]  = {{(W-HALF){1'b0}}, next_win};
    assign result_bits[RIDX] = ~lo_has_bit; // 0=went lower, 1=went upper
end

assign result_comb = result_bits;
```

Changing `W` from 64 to 32 gives 5 stages automatically. `W=128` gives 7. No RTL changes required.

### Synthesis Results (Yosys, ASAP7-approximate 7nm)

| Metric | Value |
|---|---|
| Cell count | **168** |
| Flip-flop count | **8** (output register only) |
| Logic levels | **20** |
| Estimated Fmax | **~2.5 GHz** |

The 20-level result (vs 12 theoretical) comes from the OR-reduce fan-in at the early wide stages: OR-reducing 32 bits takes ~5 levels, not 1. The synthesizer cannot flatten this into a single gate.

### When to Use

- Moderate-frequency designs (< 2 GHz) where FF count matters more than logic depth
- As a reference/golden model to validate the other two designs
- When the FFS result is needed in-cycle with no pipeline fill latency budget

---

## Design 3: Pipelined Binary Search

### Architecture

The most interesting design and the right answer for most high-performance datapaths. The binary search in Design 2 makes exactly one decision per level: check the lower half, select which half to keep. Instead of doing all 6 decisions in one deep cone, the pipeline executes each decision in a separate clock stage.

```
  clk   ─┬───────┬───────┬───────┬───────┬───────┬───────┬──▶
  data ──►│ ST 0  │──FF──►│ ST 1  │──FF──►│ ST 2  │  ...  │──► result
          │OR+mux │       │OR+mux │       │OR+mux │       │
          └───────┘       └───────┘       └───────┘       │
          2 gate lvls     2 gate lvls     2 gate lvls (×6) │
```

Per-stage critical path: 2 gate levels. At 7nm (~18 ps/level) that's ~36 ps, clearing 2 GHz with substantial margin. Synthesis measured **6 logic levels** total, estimating **~8.3 GHz** Fmax.

After the 6-cycle fill latency, one result emerges every clock cycle regardless of input value.

### Stage-by-Stage Trace

Tracing `data = 64'h0000_0000_0000_0040` (only bit 6 set; expected result = 6):

| Stage | Window inspected | Lower half has set bit? | This stage's result bit | Offset |
|-------|-----------------|------------------------|------------------------|--------|
| 0 | `[63:0]` | YES, bit 6 is in `[31:0]` | result[5] = 0 | +0 |
| 1 | `[31:0]` | YES, bit 6 is in `[15:0]` | result[4] = 0 | +0 |
| 2 | `[15:0]` | YES, bit 6 is in `[7:0]` | result[3] = 0 | +0 |
| 3 | `[7:0]` | NO, bit 6 is in upper `[7:4]`, not `[3:0]` | result[2] = 1 | +4 |
| 4 | `[7:4]` (as `[3:0]`) | YES, bit 6 is at index 2 of this window | result[1] = 0 | +0 |
| 5 | `[7:6]` (as `[1:0]`) | YES, bit 6 is at index 0 of this window | result[0] = 0 | +0 |

**result = {0,0,0,1,0,0}₂ = 4 = … wait, +4 from stage 3, then lower from stage 4, lower from stage 5 = position 4+2+0 = 6** ✓

### Timing Diagram

After the 6-cycle fill, throughput is 1 result per cycle:

```
Cycle:     1    2    3    4    5    6    7    8    9
Input:     A    B    C    –    –    –    –    –    –
valid_in:  1    1    1    0    0    0    0    0    0
valid_out: 0    0    0    0    0    0    1    1    1
result:    –    –    –    –    –    –    A    B    C
```

Three consecutive inputs produce three consecutive outputs with zero throughput penalty.

### RTL Highlight

```systemverilog
// rtl/ffs_pipeline.sv — generate loop creates LOG2W registered stages
logic [W-1:0]     pipe_win [LOG2W+1];  // search window propagated per stage
logic [LOG2W-1:0] pipe_res [LOG2W+1];  // accumulated result bits
logic             pipe_vld [LOG2W+1];  // valid propagation
logic             pipe_nst [LOG2W+1];  // no_set propagation

// Stage 0: combinational inputs (no register)
always_comb begin
    pipe_win[0] = data;
    pipe_res[0] = '0;
    pipe_vld[0] = valid_in;
    pipe_nst[0] = ~|data;
end

genvar i;
generate
    for (i = 0; i < LOG2W; i++) begin : g_pipe
        localparam int WSIZE = W >> i;
        localparam int HALF  = WSIZE >> 1;
        localparam int RIDX  = LOG2W - 1 - i;

        logic             lo_has_bit;
        logic [HALF-1:0]  nxt_win_h;
        logic [W-1:0]     nxt_win_w;
        logic [LOG2W-1:0] nxt_res;

        assign lo_has_bit = |pipe_win[i][HALF-1:0];
        assign nxt_win_h  = lo_has_bit ? pipe_win[i][HALF-1:0]
                                       : pipe_win[i][WSIZE-1:HALF];
        assign nxt_win_w  = {{(W-HALF){1'b0}}, nxt_win_h};

        always_comb begin          // default-then-override: latch-free
            nxt_res       = pipe_res[i];
            nxt_res[RIDX] = ~lo_has_bit;
        end

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                pipe_win[i+1] <= '0;  pipe_res[i+1] <= '0;
                pipe_vld[i+1] <= 0;   pipe_nst[i+1] <= 0;
            end else begin
                pipe_win[i+1] <= nxt_win_w;   // zero-padded to uniform W bits;
                pipe_res[i+1] <= nxt_res;      // synthesis trims unused upper bits
                pipe_vld[i+1] <= pipe_vld[i];
                pipe_nst[i+1] <= pipe_nst[i];
            end
        end
    end
endgenerate

assign result    = pipe_res[LOG2W];
assign valid_out = pipe_vld[LOG2W];
assign no_set    = pipe_nst[LOG2W];
```

### Area Cost of Pipelining

The pipeline pays for throughput with flip-flops. For W=64:

```
Theoretical:  6 stages × (64 + 6 + 1 + 1) FFs = 432 FFs
After synthesis trimming of unused pipe_win upper bits: 90 FFs
```

Synthesis eliminates the zero-padded upper bits of `pipe_win` at each stage. By stage 1, only 32 bits of the window are live; by stage 5, only 2. Yosys + ABC reduce 432 theoretical FFs to **90 actual FFs**, a 4.8x reduction.

### Synthesis Results (Yosys, ASAP7-approximate 7nm)

| Metric | Value |
|---|---|
| Cell count | **239** |
| Flip-flop count | **90** (after synthesis trimming of unused window bits) |
| Logic levels (per stage) | **6** total (≈1 per stage) |
| Estimated Fmax | **~8.3 GHz** |

### When to Use

- High-throughput systems requiring 1 result/cycle with predictable, bounded latency
- Timing-critical datapaths where combinational depth must be explicitly controlled
- The correct default for modern VLSI pipelines when area permits

---

## Results

### Functional Simulation

Both simulators verified all three designs against a software golden reference (lowest set bit by for-loop scan):

```
make syntax    ✅  All 3 RTL files pass iverilog -g2012 -tnull
make sim       ✅  10,071 vectors — 0 failures  (Icarus Verilog 12.0)
make verilator ✅  66,536 vectors × 3 designs — 0 failures  (Verilator 5.032)
make synth     ✅  Yosys 0.52 + ABC, ASAP7-approximate 7nm liberty
make plot      ✅  5 charts generated from real data
```

Test suite coverage:
- Data = 0 (no_set assertion)
- Data = 1 (bit 0, minimum latency path)
- Data = all-ones (bit 0, same fast path)
- MSB-only (sequential worst case)
- Full power-of-2 sweep (all 64 bit positions)
- Alternating patterns (0xAAAA..., 0x5555...)
- README worked example (0x0000_0000_0048_0200 → bit 9)
- 10,000 uniformly random 64-bit vectors
- Exhaustive 16-bit sweep: all 65,536 inputs (Verilator)

### Area vs Performance

![Area Comparison](assets/area_comparison.png)

![Throughput vs Latency](assets/throughput_vs_latency.png)

### Master Comparison Table

| Metric | Sequential | Combinational | Pipeline |
|---|---|---|---|
| Latency (W=64) | 3–66 cycles | 1 cycle | 6 cycles |
| Throughput | 1 / 66 cyc⁻¹ | 1 cyc⁻¹ | 1 cyc⁻¹ |
| Cell count | **322** | **168** | **239** |
| Flip-flop count | **81** | **8** | **90** |
| Logic levels | **7** | **20** | **6** |
| Est. Fmax (7nm) | **~7.1 GHz** | **~2.5 GHz** | **~8.3 GHz** |

*Fmax = 1 / (logic levels × 20 ps). Wire delay and setup time not included; actual post-PnR Fmax will be lower.*

### Key Findings

**Latency and Fmax are not the same thing.** The sequential design has the shallowest critical path (7 levels, ~7.1 GHz) while having the worst latency (up to 66 cycles). High Fmax means the clock can tick fast. It says nothing about how many ticks the answer takes.

**The pipeline is strictly better than combinational for pipelined datapaths.** Both achieve 1 result/cycle throughput, but the pipeline's per-stage depth is 6 gate levels vs 20 for the combinational design. Same throughput, better timing margin, lower switching power. The only cost is 6-cycle fill latency and 82 more FFs.

**`casez` is a synthesis trap.** A `casez` priority encoder for W=64 creates 64 gate levels (O(N)) vs 20 for the generate tree (O(log N)). This is probably the most common mistake in RTL implementations of priority functions, and it fails timing at anything above ~870 MHz at 7nm.

**Synthesis trimming is real.** The pipeline was designed with 432 theoretical FFs; synthesis pruned it to 90. RTL area estimates without running synthesis are unreliable. The tool eliminates structure you wrote but didn't need.

---

## Reproducing the Results

### Prerequisites

```bash
# Ubuntu / Debian (tested: Ubuntu 25.04 on WSL2)
sudo apt install iverilog yosys verilator python3-matplotlib python3-numpy

# macOS (Homebrew)
brew install icarus-verilog verilator yosys
pip3 install matplotlib numpy
```

### Run Everything

```bash
git clone https://github.com/akshay-b-prasad/find-first-set
cd find-first-set
make all
# Reports → reports/    Charts → assets/
```

### Individual Targets

```bash
make syntax      # iverilog syntax check, run this first
make sim         # Icarus Verilog functional simulation (all 3 designs)
make verilator   # Verilator cycle-accurate simulation + latency CSVs
make synth       # Yosys synthesis, area reports and netlist JSONs
make plot        # Generate all 5 charts from reports/
make clean       # Remove all generated files
```

### For Real ASAP7 Numbers

```bash
# Get the actual ASAP7 PDK liberty:
git clone https://github.com/The-OpenROAD-Project/asap7
# Update LIB path in synth/*.ys to point at asap7_TT_08032018.lib
# Then run make synth for sign-off-quality area estimates
```

---

## Reflections

The most interesting result from actually running synthesis: the combinational design uses **168 cells and 8 FFs** while the pipeline uses **239 cells and 90 FFs**, yet they achieve identical throughput. The combinational design is smaller, but its 20 logic levels make it the timing-worst of the three. The pipeline, despite costing 82 more FFs and 71 more cells, closes timing at an estimated 8.3 GHz vs 2.5 GHz. There's no scenario where you'd choose the combinational design in a high-frequency pipelined datapath.

The numbers here use an approximate ASAP7 7nm liberty stub. With the full ASAP7 PDK and OpenSTA, the relative rankings stay the same but absolute Fmax numbers drop by 30–40% once wire delay and sign-off derating are applied. At Sky130 (130nm open-source), you'd multiply delays by roughly 15–20x. The pipeline would still be the right choice, but the combinational design's 20-level cone would fail to close at anything above ~100 MHz.

The full RTL, testbenches, synthesis scripts, and simulation data are in the repository. Everything needed to reproduce these results from a `git clone`.

---

## Repository Structure

```
find-first-set/
├── rtl/
│   ├── ffs_sequential.sv      # FSM + shift register (80 FFs, 7 logic levels)
│   ├── ffs_combinational.sv   # Parallel generate tree (8 FFs, 20 logic levels)
│   └── ffs_pipeline.sv        # log₂(W) pipeline stages (90 FFs, 6 logic levels)
├── tb/
│   └── tb_ffs_top.sv          # Unified testbench, all 3 designs driven in parallel
├── verilator/
│   ├── sim_sequential.cpp     # Cycle-accurate harness + per-vector latency logging
│   ├── sim_combinational.cpp
│   ├── sim_pipeline.cpp
│   └── Makefile
├── synth/
│   ├── synth_sequential.ys    # Yosys synthesis script
│   ├── synth_combinational.ys
│   ├── synth_pipeline.ys
│   ├── asap7_approx.lib       # Approximate 7nm liberty (ASAP7-derived stub)
│   └── run_synth.sh           # Run all synthesis passes, generate summary table
├── scripts/
│   └── plot_results.py        # 5 charts at 300 DPI from real simulation data
├── reports/                   # Generated: CSVs, synthesis reports, netlists
└── assets/                    # Generated: PNG charts embedded in this README
```

---

## License

MIT. Use freely, attribution appreciated.

## Author

**Akshay Prasad** | [akshayprasad.com](https://akshayprasad.com) · [GitHub](https://github.com/akshay-b-prasad/find-first-set)

---

*Synthesized with Yosys 0.52 using the ASAP7-approximate liberty stub (`synth/asap7_approx.lib`).
Timing estimates use 20 ps/level, a conservative 7nm approximation.
For sign-off accuracy, run with the full ASAP7 PDK liberty and OpenSTA.*
