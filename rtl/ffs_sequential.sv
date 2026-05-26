// =============================================================================
// ffs_sequential.sv  —  Find First Set Bit: Sequential Shift-and-Check
// =============================================================================
// Architecture : FSM (IDLE → RUNNING → DONE) + W-bit shift register
// Latency      : 1 to W cycles (data-dependent; best=1, worst=W)
// Throughput   : 1 result per ≤W cycles
// Area         : ~80 FFs for W=64 (minimum-register design)
// Reset        : Active-low synchronous
// =============================================================================
module ffs_sequential #(parameter int W = 64) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 valid_in,
    input  logic [W-1:0]         data,
    output logic [$clog2(W)-1:0] result,
    output logic                 valid_out,
    output logic                 no_set
);

    localparam int LOG2W = $clog2(W);

    // ── FSM state encoding (binary, 2 bits for 3 states) ─────────────────────
    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        RUNNING = 2'b01,
        DONE    = 2'b10
    } state_t;

    state_t               state;
    logic [W-1:0]         shift_reg;          // W FFs: current search window
    logic [LOG2W-1:0]     counter;            // log2(W) FFs: current bit index

    // Max counter value (parameterised constant for clean comparison)
    localparam logic [LOG2W-1:0] CNT_MAX = LOG2W'(W - 1);

    // ── Sequential logic ─────────────────────────────────────────────────────
    // FF count: 2 (state) + W (shift_reg) + log2W (counter)
    //         + log2W (result) + 1 (no_set) + 1 (valid_out)
    //         = W + 2*log2W + 4  →  for W=64: 64 + 12 + 4 = 80 FFs
    // result/no_set are set in RUNNING on the transition cycle and held in
    // DONE — no staging register needed (saves 7 FFs vs double-buffering).
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= IDLE;
            shift_reg <= '0;
            counter   <= '0;
            result    <= '0;
            no_set    <= 1'b0;
            valid_out <= 1'b0;
        end else begin
            // Default: deassert valid_out every cycle (1-cycle pulse only)
            valid_out <= 1'b0;

            unique case (state)
                // ── IDLE: ready to accept new input ──────────────────────────
                IDLE: begin
                    counter <= '0;
                    if (valid_in) begin
                        shift_reg <= data;
                        state     <= RUNNING;
                    end
                end

                // ── RUNNING: shift right, inspect bit 0 each cycle ───────────
                //    Critical path: counter FF → 6-bit comparator → state FF
                //    Roughly 5–6 gate levels → closes timing easily at 1 GHz+
                RUNNING: begin
                    if (shift_reg[0]) begin
                        // Found: drive outputs now, valid_out fires next cycle in DONE
                        result <= counter;
                        no_set <= 1'b0;
                        state  <= DONE;
                    end else if (counter == CNT_MAX) begin
                        // All W bits checked with no hit — assert no_set
                        result <= '0;
                        no_set <= 1'b1;
                        state  <= DONE;
                    end else begin
                        // Keep searching: shift right to inspect next bit
                        shift_reg <= shift_reg >> 1;
                        counter   <= counter + 1'b1;
                    end
                end

                // ── DONE: pulse valid_out; result/no_set already hold correct values
                DONE: begin
                    valid_out <= 1'b1;
                    counter   <= '0;
                    if (valid_in) begin
                        // Zero-latency chaining: start next search immediately
                        shift_reg <= data;
                        state     <= RUNNING;
                    end else begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
