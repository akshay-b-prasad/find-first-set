// =============================================================================
// sim_sequential.cpp  —  Verilator harness for ffs_sequential
// =============================================================================
// Drives 65536 (16-bit exhaustive) + 1000 random W-bit test vectors
// Measures actual cycle count (latency) for each vector
// Logs: input_hex, cycles_taken, result, expected, pass to reports/verilator_seq.csv
// =============================================================================
#include "Vffs_sequential.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cassert>
#include <random>
#include <fstream>
#include <sstream>
#include <iomanip>

// ── Golden reference ──────────────────────────────────────────────────────────
static int golden_ffs(uint64_t data) {
    if (data == 0) return 64;  // no_set
    for (int b = 0; b < 64; b++)
        if ((data >> b) & 1ULL) return b;
    return 64;
}

// ── Clock cycle helper ────────────────────────────────────────────────────────
static void tick(Vffs_sequential* dut, int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }
}

// ── Reset DUT ─────────────────────────────────────────────────────────────────
static void reset(Vffs_sequential* dut) {
    dut->rst_n    = 0;
    dut->valid_in = 0;
    dut->data     = 0;
    tick(dut, 4);
    dut->rst_n = 1;
    tick(dut, 2);
}

// ── Run one test vector; return measured latency in cycles ───────────────────
static int run_vector(Vffs_sequential* dut, uint64_t input_data,
                      uint32_t& got_result, bool& got_noset) {
    // Apply stimulus for one cycle
    dut->valid_in = 1;
    dut->data     = input_data;
    tick(dut);
    dut->valid_in = 0;

    // Wait for valid_out (with timeout)
    int cycles = 0;
    while (!dut->valid_out) {
        tick(dut);
        cycles++;
        if (cycles > 70) {  // W + guard
            fprintf(stderr, "TIMEOUT: input=0x%016llx\n",
                    (unsigned long long)input_data);
            return -1;
        }
    }
    // valid_out is high — capture outputs
    got_result = dut->result;
    got_noset  = dut->no_set;
    return cycles + 1;  // +1 for the initial valid_in cycle
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* dut = new Vffs_sequential;
    reset(dut);

    std::ofstream csv("reports/verilator_seq.csv");
    if (!csv.is_open()) csv.open("verilator_seq.csv");
    csv << "input_hex,expected,result,no_set,cycles,pass\n";

    int pass = 0, fail = 0;
    uint64_t lat_sum = 0;
    int lat_min = INT32_MAX, lat_max = 0;

    auto test_vector = [&](uint64_t vec) {
        uint32_t got_res  = 0;
        bool     got_nst  = false;
        int      cycles   = run_vector(dut, vec, got_res, got_nst);
        int      expected = golden_ffs(vec);
        bool     is_nst   = (expected == 64);
        bool     ok;

        if (is_nst) {
            ok = got_nst;
        } else {
            ok = (!got_nst && (int)got_res == expected);
        }

        if (ok) { pass++; } else {
            fail++;
            fprintf(stderr, "FAIL: input=0x%016llx expected=%d got=%d no_set=%d\n",
                    (unsigned long long)vec, expected, got_res, got_nst);
        }

        lat_sum += cycles;
        if (cycles < lat_min) lat_min = cycles;
        if (cycles > lat_max) lat_max = cycles;

        csv << std::hex << std::setw(16) << std::setfill('0') << vec << ","
            << std::dec << expected << "," << got_res << ","
            << (int)got_nst << "," << cycles << "," << ok << "\n";
    };

    // ── Exhaustive 16-bit sweep (65536 vectors, zero-extended to 64 bits) ───
    printf("Running exhaustive 16-bit sweep (65536 vectors)...\n");
    for (uint32_t i = 0; i < 65536; i++)
        test_vector((uint64_t)i);

    // ── 1000 random full 64-bit vectors ──────────────────────────────────────
    printf("Running 1000 random 64-bit vectors...\n");
    std::mt19937_64 rng(0xDEADBEEF42ULL);
    for (int r = 0; r < 1000; r++)
        test_vector(rng());

    csv.close();

    double avg_lat = (pass + fail > 0) ? (double)lat_sum / (pass + fail) : 0.0;
    printf("\n=== ffs_sequential Results ===\n");
    printf("Total:   %d\n", pass + fail);
    printf("Pass:    %d\n", pass);
    printf("Fail:    %d\n", fail);
    printf("Latency: min=%d  max=%d  avg=%.2f cycles\n", lat_min, lat_max, avg_lat);
    printf("CSV:     reports/verilator_seq.csv\n");

    delete dut;
    return fail > 0 ? 1 : 0;
}
