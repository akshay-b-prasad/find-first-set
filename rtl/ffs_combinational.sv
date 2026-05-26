// =============================================================================
// ffs_combinational.sv  —  Find First Set Bit: Full Parallel Combinational
// =============================================================================
// Architecture : Two modes via MODE parameter
//   MODE=0 : Isolate LSB (data & ~data+1) then OR-tree position encode
//   MODE=1 : Balanced binary mux tree via generate/genvar  ← default
// Latency      : 1 cycle (output registered on clock edge)
// Throughput   : 1 result per cycle
// Logic depth  : O(log N) for both modes (12 levels for W=64 at 7nm ASAP7)
// Reset        : Active-low synchronous
//
// WHY NOT casez?
//   casez priority encoder → O(N) gate chain (64 levels for W=64).
//   At 7nm ~18 ps/level that's ~1.15 ns — fails 1 GHz timing with no margin.
//   Both MODE=0 and MODE=1 achieve O(log N) ≈ 12 levels → ~216 ps → 4.6 GHz
//   theoretical ceiling before wire and setup time deductions.
// =============================================================================
module ffs_combinational #(
    parameter int W    = 64,
    parameter int MODE = 1    // 0 = isolate+encode, 1 = binary mux tree
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 valid_in,
    input  logic [W-1:0]         data,
    output logic [$clog2(W)-1:0] result,
    output logic                 valid_out,
    output logic                 no_set
);

    localparam int LOG2W = $clog2(W);

    // Internal combinational nets (pre-register)
    logic [LOG2W-1:0] result_comb;
    logic             no_set_comb;

    // NOR-reduce: high iff data is all zeros (single gate, O(log N) depth)
    assign no_set_comb = ~|data;

    // =========================================================================
    // MODE 0 — Isolate-LSB then OR-tree Encode
    // =========================================================================
    // Step 1: data & (~data + 1)  →  keeps only the lowest set bit (one-hot)
    //         Two's complement trick:  ~data + 1 = -data
    //         All bits BELOW the LSB flip (0→1 with carry propagation)
    //         The LSB itself becomes 1 AND the carry kills all bits above it
    //
    // Step 2: For each result bit b:
    //         result[b] = OR of lsb_hot[k] for all k where bit-b of k is set
    //         This encodes the one-hot position into binary via an OR tree
    // =========================================================================
    generate
        if (MODE == 0) begin : g_mode0

            logic [W-1:0] lsb_hot;
            assign lsb_hot = data & (~data + W'(1));

            genvar b, k;
            for (b = 0; b < LOG2W; b++) begin : g_enc_bit
                // Compile-time mask: bit k of mask is 1 iff bit b of k is set
                // Synthesizes to a subset of lsb_hot bits fed into an OR tree
                logic [W-1:0] bit_mask;
                for (k = 0; k < W; k++) begin : g_mask_bit
                    assign bit_mask[k] = (k >> b) & 1'b1;
                end
                assign result_comb[b] = |(lsb_hot & bit_mask);
            end

        end
    endgenerate

    // =========================================================================
    // MODE 1 — Balanced Binary Mux Tree  (default)
    // =========================================================================
    // Each of log2(W) stages halves the search window:
    //   - OR-reduce lower half → 1 gate level
    //   - Select lower or upper half → 1 gate level (mux)
    //   - Contribute 1 bit to result (offset_bit = ~lower_has_bit)
    // Total: 2 gate levels × log2(W) stages = 12 levels for W=64
    //
    // stage_win[i] holds the current search window entering stage i.
    // All stages use W-bit registers for uniform width; upper unused bits = 0.
    // =========================================================================
    generate
        if (MODE == 1) begin : g_mode1

            logic [W-1:0]     stage_win  [LOG2W+1];
            logic [LOG2W-1:0] result_bits;

            assign stage_win[0] = data;

            genvar i;
            for (i = 0; i < LOG2W; i++) begin : g_stage
                localparam int WSIZE = W >> i;        // window width at stage i
                localparam int HALF  = WSIZE >> 1;    // lower/upper split point
                localparam int RIDX  = LOG2W - 1 - i; // result bit driven here

                logic              lo_has_bit;
                logic [HALF-1:0]   next_win;

                // Check if any set bit exists in lower half of current window
                assign lo_has_bit = |stage_win[i][HALF-1:0];

                // Select: go lower if lower half has a set bit, else go upper
                assign next_win   = lo_has_bit ? stage_win[i][HALF-1:0]
                                               : stage_win[i][WSIZE-1:HALF];

                // Pack into uniform W-bit pipeline (zero-pad unused upper bits)
                // Single continuous assign — avoids multi-driver on logic type
                assign stage_win[i+1] = {{(W-HALF){1'b0}}, next_win};

                // This stage contributes bit RIDX to the result:
                //   0 → went lower (bit position is in lower half, no offset)
                //   1 → went upper (add HALF to offset = set this result bit)
                assign result_bits[RIDX] = ~lo_has_bit;
            end

            assign result_comb = result_bits;

        end
    endgenerate

    // ── Output register: registers combinational cone onto clock edge ─────────
    // This is the ONLY flip-flop stage in this design (log2W + 2 FFs).
    // valid_out follows valid_in with exactly 1 cycle of latency.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result    <= '0;
            no_set    <= 1'b0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_in;
            result    <= result_comb;
            no_set    <= no_set_comb;
        end
    end

endmodule
