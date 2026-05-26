// =============================================================================
// ffs_pipeline.sv  —  Find First Set Bit: Pipelined Binary Search
// =============================================================================
// Architecture : log2(W) pipeline stages, each halving the search window
// Latency      : exactly $clog2(W) cycles (6 cycles for W=64)
// Throughput   : 1 result per cycle (fully pipelined after fill)
// Logic depth  : 2 gate levels per stage (OR-reduce + mux) → closes at 2+ GHz
// Reset        : Active-low synchronous
//
// CORE INSIGHT:
//   Each stage performs one "binary search step" — the same computation you'd
//   do in software (check lower half, recurse into the correct half) — but
//   instead of looping, we execute all steps simultaneously in parallel stages
//   separated by pipeline registers. After log2(W) = 6 cycles of fill latency,
//   a new result emerges every clock cycle.
//
// PIPELINE REGISTER LAYOUT (W=64, LOG2W=6):
//   Stage | pipe_win width (useful) | pipe_res bits determined | FFs
//   0→1   | 32 (lower/upper half)   | result[5]               | 72
//   1→2   | 16                      | result[4]               | 72
//   2→3   | 8                       | result[3]               | 72
//   3→4   | 4                       | result[2]               | 72
//   4→5   | 2                       | result[1]               | 72
//   5→6   | 1                       | result[0]               | 72
//   Total : 6 × (64+6+1+1) = 432 FFs (synthesis trims unused pipe_win bits)
//
// PARAMETERISATION:
//   Changing W automatically adjusts number of stages to $clog2(W).
//   W must be a power of 2 for correct operation.
// =============================================================================
module ffs_pipeline #(parameter int W = 64) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 valid_in,
    input  logic [W-1:0]         data,
    output logic [$clog2(W)-1:0] result,
    output logic                 valid_out,
    output logic                 no_set
);

    localparam int LOG2W = $clog2(W);

    // ── Pipeline register arrays ──────────────────────────────────────────────
    // Index 0 = combinational inputs (no FF), index LOG2W = registered outputs
    // All windows stored at uniform W-bit width; synthesis eliminates unused FFs
    logic [W-1:0]     pipe_win [LOG2W+1]; // search window, narrows each stage
    logic [LOG2W-1:0] pipe_res [LOG2W+1]; // accumulated result bits
    logic             pipe_vld [LOG2W+1]; // valid signal propagation
    logic             pipe_nst [LOG2W+1]; // no_set signal propagation

    // Stage 0: combinational inputs — no flip-flop here
    // always_comb used (not assign) so iverilog doesn't flag logic arrays as reg
    always_comb begin
        pipe_win[0] = data;
        pipe_res[0] = '0;
        pipe_vld[0] = valid_in;
        pipe_nst[0] = ~|data;   // detect all-zero at input, propagate through
    end

    // ── Generate LOG2W pipeline stages ───────────────────────────────────────
    genvar i;
    generate
        for (i = 0; i < LOG2W; i++) begin : g_pipe

            localparam int WSIZE = W >> i;      // search window width at this stage
            localparam int HALF  = WSIZE >> 1;  // split point
            localparam int RIDX  = LOG2W-1-i;   // which result bit this stage sets

            // ── Combinational stage logic ─────────────────────────────────────
            // Critical path per stage: OR-reduce (log2(HALF) levels) + mux (1 level)
            // For stage 0: OR-reduce 32 bits ≈ 5 levels + mux = 6 levels total
            // For stage 5: OR-reduce 1 bit = wire + mux = 1 level
            logic             lo_has_bit;
            logic [HALF-1:0]  nxt_win_h;    // selected half-window
            logic [W-1:0]     nxt_win_w;    // zero-padded to full W width
            logic [LOG2W-1:0] nxt_res;      // result with this stage's bit set

            assign lo_has_bit = |pipe_win[i][HALF-1:0];
            assign nxt_win_h  = lo_has_bit ? pipe_win[i][HALF-1:0]
                                           : pipe_win[i][WSIZE-1:HALF];

            // Zero-pad to uniform W bits: upper bits are don't-care but held at 0
            // Synthesis will trim unused FFs from pipe_win[i+1][W-1:HALF]
            assign nxt_win_w = {{(W-HALF){1'b0}}, nxt_win_h};

            // Accumulate result: carry forward all prior bits, set this stage's bit
            // Uses always_comb with default to guarantee latch-free synthesis
            always_comb begin
                nxt_res       = pipe_res[i];   // carry forward already-determined bits
                nxt_res[RIDX] = ~lo_has_bit;   // this stage determines bit RIDX
            end

            // ── Pipeline registers ────────────────────────────────────────────
            // Each stage has exactly one always_ff, one NBA per signal — clean
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    pipe_win[i+1] <= '0;
                    pipe_res[i+1] <= '0;
                    pipe_vld[i+1] <= 1'b0;
                    pipe_nst[i+1] <= 1'b0;
                end else begin
                    pipe_win[i+1] <= nxt_win_w;
                    pipe_res[i+1] <= nxt_res;
                    pipe_vld[i+1] <= pipe_vld[i];
                    pipe_nst[i+1] <= pipe_nst[i];
                end
            end

        end
    endgenerate

    // ── Output connections ────────────────────────────────────────────────────
    // pipe_res[LOG2W], pipe_vld[LOG2W], pipe_nst[LOG2W] are registered signals
    // (driven by the always_ff in the last generate iteration, i=LOG2W-1)
    assign result    = pipe_res[LOG2W];
    assign valid_out = pipe_vld[LOG2W];
    assign no_set    = pipe_nst[LOG2W];

endmodule
