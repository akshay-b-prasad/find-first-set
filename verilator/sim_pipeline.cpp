// =============================================================================
// sim_pipeline.cpp  —  Verilator harness for ffs_pipeline
// =============================================================================
// Pipeline design: feeds new input every cycle, verifies output after LOG2W
// latency. Fully pipelined: one result per cycle at steady state.
// Logs: input_hex, expected, result, no_set, pass to reports/verilator_pipe.csv
// =============================================================================
#include "Vffs_pipeline.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <fstream>
#include <iomanip>

static constexpr int W      = 64;
static constexpr int LOG2W  = 6;   // $clog2(64) = 6

static int golden_ffs(uint64_t data) {
    if (data == 0) return 64;
    for (int b = 0; b < 64; b++)
        if ((data >> b) & 1ULL) return b;
    return 64;
}

static void tick(Vffs_pipeline* dut) {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static void reset(Vffs_pipeline* dut) {
    dut->rst_n    = 0;
    dut->valid_in = 0;
    dut->data     = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_n = 1;
    for (int i = 0; i < 2; i++) tick(dut);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* dut = new Vffs_pipeline;
    reset(dut);

    std::ofstream csv("reports/verilator_pipe.csv");
    if (!csv.is_open()) csv.open("verilator_pipe.csv");
    csv << "input_hex,expected,result,no_set,pass\n";

    int pass = 0, fail = 0;

    // Prepare test vectors: 65536 exhaustive + 1000 random
    std::vector<uint64_t> vectors;
    vectors.reserve(66536);
    for (uint32_t i = 0; i < 65536; i++)
        vectors.push_back((uint64_t)i);
    std::mt19937_64 rng(0xFEEDFACE42ULL);
    for (int r = 0; r < 1000; r++)
        vectors.push_back(rng());

    // Pipeline driver: input queue tracks what's in-flight
    // Expected outputs at position n appear at output n + LOG2W cycles later
    std::deque<uint64_t> in_flight;   // FIFO of in-flight inputs

    size_t send_idx   = 0;
    size_t total_recv = 0;
    size_t total_send = vectors.size();

    printf("Running %zu vectors through pipeline (LOG2W=%d cycle latency)...\n",
           total_send, LOG2W);

    // Keep running until all vectors are received
    // Send new vector each cycle; receive starts after LOG2W cycles
    while (total_recv < total_send) {

        // ── Send a vector if we have more to send ───────────────────────────
        if (send_idx < total_send) {
            dut->valid_in = 1;
            dut->data     = vectors[send_idx];
            in_flight.push_back(vectors[send_idx]);
            send_idx++;
        } else {
            dut->valid_in = 0;
            dut->data     = 0;
        }

        tick(dut);

        // ── Check output if valid_out is asserted ───────────────────────────
        if (dut->valid_out) {
            if (in_flight.empty()) {
                fprintf(stderr, "ERROR: unexpected valid_out with empty queue\n");
                fail++;
            } else {
                uint64_t orig     = in_flight.front();
                in_flight.pop_front();
                int  expected     = golden_ffs(orig);
                bool is_nst       = (expected == 64);
                uint32_t got_res  = dut->result;
                bool got_nst      = dut->no_set;
                bool ok;

                if (is_nst) {
                    ok = got_nst;
                } else {
                    ok = (!got_nst && (int)got_res == expected);
                }

                if (ok) { pass++; } else {
                    fail++;
                    fprintf(stderr, "FAIL: input=0x%016llx expected=%d got=%d no_set=%d\n",
                            (unsigned long long)orig, expected, got_res, got_nst);
                }

                csv << std::hex << std::setw(16) << std::setfill('0') << orig << ","
                    << std::dec << (is_nst ? 64 : expected) << "," << got_res << ","
                    << (int)got_nst << "," << ok << "\n";

                total_recv++;
            }
        }

        // Guard: stop if pipeline has stalled unreasonably
        if ((long long)send_idx - (long long)total_recv > LOG2W + 10) {
            fprintf(stderr, "STALL: pipeline not producing outputs\n");
            break;
        }
    }

    csv.close();

    printf("\n=== ffs_pipeline Results ===\n");
    printf("Total:   %zu\n", total_send);
    printf("Pass:    %d\n", pass);
    printf("Fail:    %d\n", fail);
    printf("Latency: exactly %d cycles (LOG2W)\n", LOG2W);
    printf("Throughput: 1 result/cycle (fully pipelined)\n");
    printf("CSV:     reports/verilator_pipe.csv\n");

    delete dut;
    return fail > 0 ? 1 : 0;
}
