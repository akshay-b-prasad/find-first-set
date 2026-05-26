#!/usr/bin/env bash
# =============================================================================
# run_synth.sh  —  Run Yosys synthesis for all three FFS designs
# Usage: bash synth/run_synth.sh  (from project root)
# Outputs: reports/area_*.txt, reports/netlist_*.json
#          reports/synth_summary.txt
# =============================================================================
set -euo pipefail

mkdir -p reports

echo "============================================================"
echo "FFS Synthesis Run — ASAP7 Approximate 7nm Library"
echo "$(date)"
echo "============================================================"

for design in sequential combinational pipeline; do
    echo ""
    echo "── Synthesizing ffs_${design} ──────────────────────────────"
    if yosys -q synth/synth_${design}.ys 2>&1 | tee /tmp/yosys_${design}.log; then
        echo "  Done: reports/area_${design}.txt"
    else
        echo "  WARNING: yosys returned non-zero for ${design}"
        cat /tmp/yosys_${design}.log
    fi
done

echo ""
echo "============================================================"
echo "Generating synth_summary.txt"
echo "============================================================"

# ── Parse cell/FF counts and logic levels from area reports ──────────────────
parse_report() {
    local file="$1"
    local cells="N/A"
    local ffs="N/A"
    local levels="N/A"

    if [[ -f "$file" ]]; then
        # Total cell count from "Number of cells:"
        cells=$(grep -oP 'Number of cells:\s+\K\d+' "$file" 2>/dev/null | tail -1 || true)
        [[ -z "$cells" ]] && cells="N/A"

        # Count flip-flops: generic Yosys primitives $_DFF_*, $_SDFF_*, $_SDFFE_*
        ffs=$(grep -oP '\$_(S?D?FFE?[A-Z0-9_]*)\s+\K\d+' "$file" 2>/dev/null | \
              awk '{s+=$1} END {if(s>0) print s; else print "N/A"}')

        # Logic levels from ltp output: "Longest topological path ... (length=N):"
        levels=$(grep -oP 'Longest topological path.*?\(length=\K[0-9]+' "$file" 2>/dev/null | \
                 tail -1 || true)
        [[ -z "$levels" ]] && levels="N/A"
    fi

    echo "$cells $ffs $levels"
}

read seq_cells  seq_ffs  seq_levels  <<< "$(parse_report reports/area_sequential.txt)"
read comb_cells comb_ffs comb_levels <<< "$(parse_report reports/area_combinational.txt)"
read pipe_cells pipe_ffs pipe_levels <<< "$(parse_report reports/area_pipeline.txt)"

# Estimate Fmax: Fmax_est = 1 / (levels x 20ps) — conservative for ASAP7 7nm
fmax_est() {
    local levels=$1
    if [[ "$levels" =~ ^[0-9]+$ ]] && (( levels > 0 )); then
        echo "$(echo "scale=0; 1000000 / ($levels * 20)" | bc) MHz"
    else
        echo "N/A"
    fi
}

seq_fmax=$(fmax_est  "$seq_levels")
comb_fmax=$(fmax_est "$comb_levels")
pipe_fmax=$(fmax_est "$pipe_levels")

{
echo "============================================================"
echo "FFS Synthesis Summary — ASAP7 Approximate 7nm"
echo "Library: synth/asap7_approx.lib"
echo "W = 64"
echo "Generated: $(date)"
echo "============================================================"
echo ""
printf "%-22s | %-8s | %-6s | %-14s | %-14s\n" \
       "Design" "Cells" "FFs" "Logic Levels" "Est. Fmax"
printf "%-22s-+-%-8s-+-%-6s-+-%-14s-+-%-14s\n" \
       "----------------------" "--------" "------" "--------------" "--------------"
printf "%-22s | %-8s | %-6s | %-14s | %-14s\n" \
       "ffs_sequential"    "$seq_cells"  "$seq_ffs"  "$seq_levels"  "$seq_fmax"
printf "%-22s | %-8s | %-6s | %-14s | %-14s\n" \
       "ffs_combinational" "$comb_cells" "$comb_ffs" "$comb_levels" "$comb_fmax"
printf "%-22s | %-8s | %-6s | %-14s | %-14s\n" \
       "ffs_pipeline"      "$pipe_cells" "$pipe_ffs" "$pipe_levels" "$pipe_fmax"
echo ""
echo "Note: Cells are generic Yosys primitives (mapped by synth internal ABC)."
echo "      Est. Fmax = 1 / (logic_levels x 20 ps/level) — ASAP7 approx gate delay."
echo "      Wire delay and setup time not included — actual Fmax will be lower."
echo "      For accurate numbers, run with real ASAP7 PDK and OpenSTA."
} | tee reports/synth_summary.txt

echo ""
echo "Done. See reports/synth_summary.txt"
