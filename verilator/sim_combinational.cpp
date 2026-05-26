// =============================================================================
// sim_combinational.cpp  —  Verilator harness for ffs_combinational
// =============================================================================
// Drives 65536 exhaustive + 1000 random 64-bit vectors
// Combinational design: valid_out always 1 cycle after valid_in
// Logs: input_hex, result, expected, pass to reports/verilator_comb.csv
// =============================================================================
#include "Vffs_combinational.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <fstream>
#include <iomanip>

static int golden_ffs(uint64_t data) {
    if (data == 0) return 64;
    for (int b = 0; b < 64; b++)
        if ((data >> b) & 1ULL) return b;
    return 64;
}

static void tick(Vffs_combinational* dut, int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }
}

static void reset(Vffs_combinational* dut) {
    dut->rst_n    = 0;
    dut->valid_in = 0;
    dut->data     = 0;
    tick(dut, 4);
    dut->rst_n = 1;
    tick(dut, 2);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* dut = new Vffs_combinational;
    reset(dut);

    std::ofstream csv("reports/verilator_comb.csv");
    if (!csv.is_open()) csv.open("verilator_comb.csv");
    csv << "input_hex,expected,result,no_set,pass\n";

    int pass = 0, fail = 0;

    auto test_vector = [&](uint64_t vec) {
        // Apply for one cycle
        dut->valid_in = 1;
        dut->data     = vec;
        tick(dut);
        dut->valid_in = 0;

        // Output is registered — valid_out should be high this cycle
        if (!dut->valid_out) {
            fprintf(stderr, "WARNING: valid_out not asserted for input 0x%016llx\n",
                    (unsigned long long)vec);
        }

        uint32_t got_res = dut->result;
        bool     got_nst = dut->no_set;
        int      exp     = golden_ffs(vec);
        bool     is_nst  = (exp == 64);
        bool     ok;

        if (is_nst) {
            ok = got_nst;
        } else {
            ok = (!got_nst && (int)got_res == exp);
        }

        if (ok) { pass++; } else {
            fail++;
            fprintf(stderr, "FAIL: input=0x%016llx expected=%d got=%d no_set=%d\n",
                    (unsigned long long)vec, exp, got_res, got_nst);
        }

        csv << std::hex << std::setw(16) << std::setfill('0') << vec << ","
            << std::dec << (is_nst ? 64 : exp) << "," << got_res << ","
            << (int)got_nst << "," << ok << "\n";
    };

    printf("Running exhaustive 16-bit sweep (65536 vectors)...\n");
    for (uint32_t i = 0; i < 65536; i++)
        test_vector((uint64_t)i);

    printf("Running 1000 random 64-bit vectors...\n");
    std::mt19937_64 rng(0xCAFEBABE42ULL);
    for (int r = 0; r < 1000; r++)
        test_vector(rng());

    csv.close();

    printf("\n=== ffs_combinational Results ===\n");
    printf("Total: %d\n", pass + fail);
    printf("Pass:  %d\n", pass);
    printf("Fail:  %d\n", fail);
    printf("Latency: always 1 cycle (registered combinational output)\n");
    printf("CSV:   reports/verilator_comb.csv\n");

    delete dut;
    return fail > 0 ? 1 : 0;
}
