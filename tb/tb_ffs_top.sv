// =============================================================================
// tb_ffs_top.sv  —  Unified Testbench: All Three FFS Designs in Parallel
// =============================================================================
// Drives identical stimulus to ffs_sequential, ffs_combinational, ffs_pipeline
// Computes golden reference in TB
// Logs results to reports/sim_comparison.csv
// Exits with $finish(1) on any mismatch
// =============================================================================
`timescale 1ns/1ps

module tb_ffs_top;

    // ── Parameters ─────────────────────────────────────────────────────────
    localparam int W        = 64;
    localparam int LOG2W    = $clog2(W);
    localparam int NUM_RAND = 10000;
    localparam int CLK_HALF = 5;  // 100 MHz (10 ns period)

    // ── Clock & Reset ───────────────────────────────────────────────────────
    logic clk    = 0;
    logic rst_n  = 0;

    always #CLK_HALF clk = ~clk;

    // ── Shared stimulus signals ─────────────────────────────────────────────
    logic           valid_in;
    logic [W-1:0]   data;

    // ── DUT outputs ────────────────────────────────────────────────────────
    logic [LOG2W-1:0] res_seq,  res_comb,  res_pipe;
    logic             vld_seq,  vld_comb,  vld_pipe;
    logic             nst_seq,  nst_comb,  nst_pipe;

    // ── DUT instantiations ──────────────────────────────────────────────────
    ffs_sequential   #(.W(W)) u_seq  (.clk(clk), .rst_n(rst_n), .valid_in(valid_in),
                                       .data(data), .result(res_seq),
                                       .valid_out(vld_seq), .no_set(nst_seq));

    ffs_combinational #(.W(W), .MODE(1)) u_comb (.clk(clk), .rst_n(rst_n), .valid_in(valid_in),
                                       .data(data), .result(res_comb),
                                       .valid_out(vld_comb), .no_set(nst_comb));

    ffs_pipeline     #(.W(W)) u_pipe (.clk(clk), .rst_n(rst_n), .valid_in(valid_in),
                                       .data(data), .result(res_pipe),
                                       .valid_out(vld_pipe), .no_set(nst_pipe));

    // ── Simulation bookkeeping ─────────────────────────────────────────────
    int fd;                   // CSV file descriptor
    int pass_cnt, fail_cnt;
    int lat_seq, lat_comb, lat_pipe;  // measured latencies (cycles)
    longint cycle_cnt;

    // Golden reference: find lowest set bit, return W if none
    function automatic int golden_ffs (input logic [W-1:0] d);
        for (int b = 0; b < W; b++)
            if (d[b]) return b;
        return W;  // signals no_set
    endfunction

    // ── Task: apply one test vector, wait for all three outputs ────────────
    // Returns via output arguments; checks against golden reference
    task automatic run_vector (
        input  logic [W-1:0] vec,
        output int           l_seq, l_comb, l_pipe,
        output logic         match
    );
        automatic int     gold     = golden_ffs(vec);
        automatic logic   gold_nst = (gold == W);
        automatic int     gold_res = gold_nst ? 0 : gold;

        automatic logic   got_seq  = 0;
        automatic logic   got_comb = 0;
        automatic logic   got_pipe = 0;

        automatic int     cyc_seq  = 0;
        automatic int     cyc_comb = 0;
        automatic int     cyc_pipe = 0;

        // Apply stimulus
        @(negedge clk);
        valid_in = 1;
        data     = vec;
        @(negedge clk);
        valid_in = 0;

        // Wait for all three designs to respond (with timeout)
        fork
            // Sequential: variable latency
            begin
                while (!got_seq) begin
                    @(posedge clk);
                    cyc_seq++;
                    if (vld_seq) got_seq = 1;
                    if (cyc_seq > W + 5) begin
                        $display("TIMEOUT: sequential stuck on input %h", vec);
                        $finish(1);
                    end
                end
            end
            // Combinational: always 1 cycle
            begin
                while (!got_comb) begin
                    @(posedge clk);
                    cyc_comb++;
                    if (vld_comb) got_comb = 1;
                    if (cyc_comb > 5) begin
                        $display("TIMEOUT: combinational stuck on input %h", vec);
                        $finish(1);
                    end
                end
            end
            // Pipeline: always LOG2W cycles
            begin
                while (!got_pipe) begin
                    @(posedge clk);
                    cyc_pipe++;
                    if (vld_pipe) got_pipe = 1;
                    if (cyc_pipe > LOG2W + 5) begin
                        $display("TIMEOUT: pipeline stuck on input %h", vec);
                        $finish(1);
                    end
                end
            end
        join

        l_seq  = cyc_seq;
        l_comb = cyc_comb;
        l_pipe = cyc_pipe;
        match  = 1;

        // ── Sequential check ────────────────────────────────────────────────
        if (gold_nst) begin
            if (!nst_seq) begin
                $display("FAIL [seq] input=%h  expected no_set=1  got no_set=%b result=%0d",
                          vec, nst_seq, res_seq);
                match = 0;
            end
        end else begin
            if (nst_seq || res_seq !== LOG2W'(gold_res)) begin
                $display("FAIL [seq] input=%h  expected result=%0d  got result=%0d no_set=%b",
                          vec, gold_res, res_seq, nst_seq);
                match = 0;
            end
        end

        // ── Combinational check ─────────────────────────────────────────────
        if (gold_nst) begin
            if (!nst_comb) begin
                $display("FAIL [comb] input=%h  expected no_set=1  got no_set=%b result=%0d",
                          vec, nst_comb, res_comb);
                match = 0;
            end
        end else begin
            if (nst_comb || res_comb !== LOG2W'(gold_res)) begin
                $display("FAIL [comb] input=%h  expected result=%0d  got result=%0d no_set=%b",
                          vec, gold_res, res_comb, nst_comb);
                match = 0;
            end
        end

        // ── Pipeline check ──────────────────────────────────────────────────
        if (gold_nst) begin
            if (!nst_pipe) begin
                $display("FAIL [pipe] input=%h  expected no_set=1  got no_set=%b result=%0d",
                          vec, nst_pipe, res_pipe);
                match = 0;
            end
        end else begin
            if (nst_pipe || res_pipe !== LOG2W'(gold_res)) begin
                $display("FAIL [pipe] input=%h  expected result=%0d  got result=%0d no_set=%b",
                          vec, gold_res, res_pipe, nst_pipe);
                match = 0;
            end
        end
    endtask

    // ── Main test sequence ──────────────────────────────────────────────────
    // Variables hoisted to top of initial block — iverilog does not support
    // per-variable 'automatic' lifetime override inside static initial blocks.
    initial begin
        // Local temporaries (shared across all test blocks below)
        logic         match;
        int           l_s, l_c, l_p;
        logic [W-1:0] msb_only, pow2, rv;
        int           rand_pass, rand_fail;
        int           b, r;

        // Create reports directory and open CSV
        fd       = $fopen("reports/sim_comparison.csv", "w");
        if (fd == 0) fd = $fopen("sim_comparison.csv", "w");
        $fwrite(fd, "input_hex,golden,result_seq,lat_seq,result_comb,lat_comb,result_pipe,lat_pipe,all_match\n");

        pass_cnt  = 0;
        fail_cnt  = 0;
        valid_in  = 0;
        data      = '0;

        // Release reset after 4 cycles
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== FFS Unified Testbench (W=%0d) ===", W);

        // ── Directed test vectors ───────────────────────────────────────────
        $display("\n-- Directed tests --");

        // Test 1: data = 0 (no set bit)
        run_vector(64'h0, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                64'h0, W, W, l_s, W, l_c, W, l_p, match);
        $display("  data=0x0000...0  no_set test: %s", match ? "PASS" : "FAIL");

        // Test 2: data = 1 (bit 0 set — minimum latency)
        run_vector(64'h1, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                64'h1, 0, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
        $display("  data=0x1  bit0 test (lat_seq=%0d): %s", l_s, match ? "PASS" : "FAIL");

        // Test 3: data = all ones
        run_vector(64'hFFFF_FFFF_FFFF_FFFF, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                64'hFFFF_FFFF_FFFF_FFFF, 0, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
        $display("  data=0xFFFF...F  all-ones test: %s", match ? "PASS" : "FAIL");

        // Test 4: only MSB set (worst case for sequential)
        msb_only = (W'(1) << (W-1));
        run_vector(msb_only, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                msb_only, W-1, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
        $display("  data=MSB-only test (lat_seq=%0d, worst=%0d): %s",
                 l_s, W, match ? "PASS" : "FAIL");

        // Test 5: power-of-2 sweep (each individual bit position)
        $display("\n-- Power-of-2 sweep --");
        for (b = 0; b < W; b++) begin
            pow2 = (W'(1) << b);
            run_vector(pow2, l_s, l_c, l_p, match);
            if (match) pass_cnt++; else fail_cnt++;
            $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    pow2, b, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
            if (!match)
                $display("  bit=%0d FAIL", b);
        end
        $display("  Power-of-2 sweep (%0d vectors): %0d pass, %0d fail",
                 W, W - fail_cnt, fail_cnt);

        // Test 6: alternating bit patterns
        run_vector(64'hAAAA_AAAA_AAAA_AAAA, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                64'hAAAA_AAAA_AAAA_AAAA, 1, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
        run_vector(64'h5555_5555_5555_5555, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                64'h5555_5555_5555_5555, 0, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);

        // Test 7: worked example from README
        run_vector(64'h0000_0000_0048_0200, l_s, l_c, l_p, match);
        if (match) pass_cnt++; else fail_cnt++;
        $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                64'h0000_0000_0048_0200, 9, res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
        $display("  README example (expect bit 9): %s  got_seq=%0d got_comb=%0d got_pipe=%0d",
                 match ? "PASS" : "FAIL", res_seq, res_comb, res_pipe);

        // ── Random test vectors ─────────────────────────────────────────────
        // $urandom returns 32-bit; concatenate two calls for 64-bit coverage
        $display("\n-- Random vectors (%0d) --", NUM_RAND);
        rand_pass = 0;
        rand_fail = 0;
        for (r = 0; r < NUM_RAND; r++) begin
            rv = {$urandom, $urandom};
            run_vector(rv, l_s, l_c, l_p, match);
            if (match) begin rand_pass++; pass_cnt++; end
            else       begin rand_fail++; fail_cnt++; end
            $fwrite(fd, "%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    rv, golden_ffs(rv), res_seq, l_s, res_comb, l_c, res_pipe, l_p, match);
        end
        $display("  Random: %0d pass, %0d fail", rand_pass, rand_fail);

        // ── Final report ────────────────────────────────────────────────────
        $display("\n=== RESULTS ===");
        $display("Total:  %0d vectors", pass_cnt + fail_cnt);
        $display("Pass:   %0d", pass_cnt);
        $display("Fail:   %0d", fail_cnt);

        $fclose(fd);

        if (fail_cnt > 0) begin
            $display("SIMULATION FAILED");
            $finish(1);
        end else begin
            $display("SIMULATION PASSED — all three designs agree with golden reference");
            $finish(0);
        end
    end

    // ── Simulation timeout guard ────────────────────────────────────────────
    initial begin
        #(NUM_RAND * (W+10) * 10 * 2);  // generous timeout
        $display("GLOBAL TIMEOUT — simulation hung");
        $finish(1);
    end

endmodule
