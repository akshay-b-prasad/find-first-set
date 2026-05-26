#!/usr/bin/env python3
"""
plot_results.py  —  Generate all FFS comparison charts from simulation/synthesis data
Outputs high-res PNGs to assets/ (300 DPI)

Usage:
    python3 scripts/plot_results.py

Reads:
    reports/verilator_seq.csv       (latency data for sequential design)
    reports/area_sequential.txt     (Yosys area report)
    reports/area_combinational.txt
    reports/area_pipeline.txt

Outputs:
    assets/latency_distribution.png
    assets/area_comparison.png
    assets/logic_levels.png
    assets/throughput_vs_latency.png
    assets/tradeoff_radar.png
"""

import os
import re
import sys
import warnings
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
import matplotlib.gridspec as gridspec

# ── Style ─────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    "figure.facecolor":  "#0d1117",
    "axes.facecolor":    "#161b22",
    "axes.edgecolor":    "#30363d",
    "axes.labelcolor":   "#e6edf3",
    "text.color":        "#e6edf3",
    "xtick.color":       "#8b949e",
    "ytick.color":       "#8b949e",
    "grid.color":        "#21262d",
    "grid.linestyle":    "--",
    "grid.alpha":        0.6,
    "legend.facecolor":  "#161b22",
    "legend.edgecolor":  "#30363d",
    "font.family":       "monospace",
    "font.size":         11,
})

# Consistent color palette across all plots
COLOR_SEQ  = "#58a6ff"   # blue
COLOR_COMB = "#f78166"   # red-orange
COLOR_PIPE = "#3fb950"   # green

DPI        = 300
ASSETS_DIR = "assets"
os.makedirs(ASSETS_DIR, exist_ok=True)


# =============================================================================
# Helpers
# =============================================================================

def warn_missing(path: str) -> bool:
    if not os.path.exists(path):
        print(f"  WARNING: missing {path} — using placeholder data")
        return True
    return False


def parse_area_report(path: str) -> dict:
    """Extract cell count, FF count, and logic levels from Yosys stat output."""
    result = {"cells": None, "ffs": None, "logic_levels": None}
    if not os.path.exists(path):
        return result

    text = open(path).read()

    # Cell count
    m = re.search(r"Number of cells:\s+(\d+)", text)
    if m:
        result["cells"] = int(m.group(1))

    # FF count (sum of all DFF* cell types)
    ff_total = 0
    for m in re.finditer(r"(DFFR?H?Q\w*)\s+(\d+)", text):
        ff_total += int(m.group(2))
    if ff_total:
        result["ffs"] = ff_total

    # Logic levels from ltp output
    # Format: "Longest topological path in module ... (length X cells)"
    m = re.search(r"length\s+(\d+)\s+cells", text)
    if m:
        result["logic_levels"] = int(m.group(1))
    else:
        # Alternative format
        m = re.search(r"logic depth[:\s]+(\d+)", text, re.IGNORECASE)
        if m:
            result["logic_levels"] = int(m.group(1))

    return result


def load_seq_latencies(path: str) -> list:
    """Load per-vector cycle counts from verilator_seq.csv."""
    latencies = []
    if not os.path.exists(path):
        print(f"  WARNING: missing {path} — generating synthetic latency distribution")
        rng = np.random.default_rng(42)
        # Synthetic: geometric distribution (bits uniformly set)
        for _ in range(10000):
            data = rng.integers(0, 2**64, dtype=np.uint64)
            if data == 0:
                latencies.append(64)
            else:
                pos = int(np.log2(data & -data))
                latencies.append(pos + 1)
        return latencies

    import csv
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                latencies.append(int(row["cycles"]))
            except (KeyError, ValueError):
                pass
    return latencies


# =============================================================================
# Fallback / placeholder synthesis data
# =============================================================================
PLACEHOLDER = {
    "sequential":    {"cells": 95,  "ffs": 81,  "logic_levels": 6},
    "combinational": {"cells": 312, "ffs": 8,   "logic_levels": 13},
    "pipeline":      {"cells": 280, "ffs": 216, "logic_levels": 4},
}

def get_synth_data():
    """Load real synthesis data or fall back to placeholders."""
    data = {}
    for name in ("sequential", "combinational", "pipeline"):
        path = f"reports/area_{name}.txt"
        raw  = parse_area_report(path)
        ph   = PLACEHOLDER[name]
        data[name] = {
            "cells":        raw["cells"]        if raw["cells"]        is not None else ph["cells"],
            "ffs":          raw["ffs"]          if raw["ffs"]          is not None else ph["ffs"],
            "logic_levels": raw["logic_levels"] if raw["logic_levels"] is not None else ph["logic_levels"],
        }
        if raw["cells"] is None:
            print(f"  INFO: Using placeholder data for {name} (run 'make synth' for real numbers)")
    return data


# =============================================================================
# Plot 1: Latency Distribution (Sequential)
# =============================================================================
def plot_latency_distribution():
    print("Generating assets/latency_distribution.png ...")
    latencies = load_seq_latencies("reports/verilator_seq.csv")

    if not latencies:
        print("  No latency data — skipping")
        return

    lat = np.array(latencies)
    mean_v   = np.mean(lat)
    median_v = np.median(lat)
    min_v    = np.min(lat)
    max_v    = np.max(lat)

    fig, ax = plt.subplots(figsize=(10, 6))
    fig.patch.set_facecolor("#0d1117")

    bins = np.arange(0.5, 66.5, 1)
    n, _, patches = ax.hist(lat, bins=bins, color=COLOR_SEQ, alpha=0.85,
                            edgecolor="#0d1117", linewidth=0.3, zorder=2)

    ax.axvline(mean_v,   color="#f0883e", linewidth=1.8, linestyle="--",
               label=f"Mean: {mean_v:.1f} cyc", zorder=3)
    ax.axvline(median_v, color="#a5d6ff", linewidth=1.8, linestyle=":",
               label=f"Median: {median_v:.0f} cyc", zorder=3)

    ymax = ax.get_ylim()[1]
    ax.annotate(f"Best: {min_v} cyc",
                xy=(min_v, ymax*0.85), xytext=(min_v+3, ymax*0.85),
                color="#3fb950", fontsize=9,
                arrowprops=dict(arrowstyle="->", color="#3fb950", lw=1.2))
    ax.annotate(f"Worst: {max_v} cyc",
                xy=(max_v, ymax*0.7), xytext=(max_v-18, ymax*0.7),
                color=COLOR_COMB, fontsize=9,
                arrowprops=dict(arrowstyle="->", color=COLOR_COMB, lw=1.2))

    ax.set_xlabel("Cycle count to result", fontsize=12)
    ax.set_ylabel("Number of inputs", fontsize=12)
    ax.set_title("Sequential Design — Latency Distribution (W=64)", fontsize=13,
                 fontweight="bold", pad=12)
    ax.legend(loc="upper right", fontsize=10)
    ax.grid(True, zorder=0)
    ax.set_xlim(0, 66)

    plt.tight_layout()
    plt.savefig(f"{ASSETS_DIR}/latency_distribution.png", dpi=DPI,
                bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close()
    print("  Saved.")


# =============================================================================
# Plot 2: Area Comparison (Cells + FFs)
# =============================================================================
def plot_area_comparison():
    print("Generating assets/area_comparison.png ...")
    sd = get_synth_data()

    designs = ["Sequential", "Combinational", "Pipeline"]
    cells   = [sd["sequential"]["cells"],    sd["combinational"]["cells"],    sd["pipeline"]["cells"]]
    ffs     = [sd["sequential"]["ffs"],      sd["combinational"]["ffs"],      sd["pipeline"]["ffs"]]
    colors  = [COLOR_SEQ, COLOR_COMB, COLOR_PIPE]

    x     = np.arange(len(designs))
    width = 0.35

    fig, ax = plt.subplots(figsize=(10, 6))
    fig.patch.set_facecolor("#0d1117")

    bars1 = ax.bar(x - width/2, cells, width, label="Total cells",
                   color=colors, alpha=0.9, edgecolor="#0d1117", linewidth=0.5)
    bars2 = ax.bar(x + width/2, ffs,   width, label="Flip-flops",
                   color=colors, alpha=0.5, edgecolor="#0d1117", linewidth=0.5,
                   hatch="//")

    for bar, val in zip(bars1, cells):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 3,
                f"{val}", ha="center", va="bottom", fontsize=9, color="#e6edf3")
    for bar, val in zip(bars2, ffs):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 3,
                f"{val}", ha="center", va="bottom", fontsize=9, color="#e6edf3")

    ax.set_xticks(x)
    ax.set_xticklabels(designs, fontsize=11)
    ax.set_ylabel("Count", fontsize=12)
    ax.set_title("Area Comparison — Cell Count and Flip-Flop Count (W=64, ASAP7 7nm)",
                 fontsize=12, fontweight="bold", pad=12)

    cell_patch = mpatches.Patch(color="#888888", alpha=0.9, label="Total cells (solid)")
    ff_patch   = mpatches.Patch(color="#888888", alpha=0.5, hatch="//", label="Flip-flops (hatched)")
    ax.legend(handles=[cell_patch, ff_patch], fontsize=10)
    ax.grid(True, axis="y", zorder=0)

    plt.tight_layout()
    plt.savefig(f"{ASSETS_DIR}/area_comparison.png", dpi=DPI,
                bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close()
    print("  Saved.")


# =============================================================================
# Plot 3: Logic Levels / Combinational Depth
# =============================================================================
def plot_logic_levels():
    print("Generating assets/logic_levels.png ...")
    sd = get_synth_data()

    designs = ["Sequential", "Combinational", "Pipeline"]
    levels  = [sd["sequential"]["logic_levels"],
               sd["combinational"]["logic_levels"],
               sd["pipeline"]["logic_levels"]]
    colors  = [COLOR_SEQ, COLOR_COMB, COLOR_PIPE]

    # Estimated Fmax per design: Fmax = 1 / (levels × 20 ps)
    fmax_mhz = [1_000_000 / (l * 20) if l else 0 for l in levels]

    fig, ax = plt.subplots(figsize=(10, 6))
    fig.patch.set_facecolor("#0d1117")

    bars = ax.bar(designs, levels, color=colors, alpha=0.9,
                  edgecolor="#0d1117", linewidth=0.5, width=0.5, zorder=2)

    for bar, val, fmax in zip(bars, levels, fmax_mhz):
        ax.text(bar.get_x() + bar.get_width()/2,
                bar.get_height() + 0.2,
                f"{val} levels\n≈ {fmax:.0f} MHz",
                ha="center", va="bottom", fontsize=9, color="#e6edf3", linespacing=1.4)

    # Reference line: ~12 FO4 budget at 7nm ≈ 480 ps = ~2 GHz
    # At 20 ps/level: 480/20 = 24 levels — show a practical 500 MHz target
    ref_levels = 25  # 25 × 20 ps = 500 ps → 2 GHz max realistic
    ax.axhline(ref_levels, color="#f0883e", linewidth=1.5, linestyle="--", zorder=3)
    ax.text(2.45, ref_levels + 0.3,
            "Typical 12-FO4 budget (reference ~500 ps)",
            color="#f0883e", fontsize=8.5, ha="right")

    ax.set_ylabel("Logic levels (gate stages)", fontsize=12)
    ax.set_title("Combinational Depth — Logic Levels After Synthesis (ASAP7 7nm)",
                 fontsize=12, fontweight="bold", pad=12)
    ax.grid(True, axis="y", zorder=0)
    ax.set_ylim(0, max(levels) * 1.35)

    plt.tight_layout()
    plt.savefig(f"{ASSETS_DIR}/logic_levels.png", dpi=DPI,
                bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close()
    print("  Saved.")


# =============================================================================
# Plot 4: Throughput vs Latency vs Area (Bubble Plot)
# =============================================================================
def plot_throughput_vs_latency():
    print("Generating assets/throughput_vs_latency.png ...")
    sd = get_synth_data()

    W = 64

    # Latency in cycles
    lat  = [W/2,   1,   6]   # seq (avg), comb, pipe
    # Throughput: results per cycle
    tput = [1/W,   1.0, 1.0]
    # Area proxy: total cells (normalized to max)
    cells = [sd["sequential"]["cells"],
             sd["combinational"]["cells"],
             sd["pipeline"]["cells"]]
    max_cells  = max(cells) if max(cells) > 0 else 1
    bubble_sz  = [(c / max_cells) * 3000 + 200 for c in cells]

    names  = ["Sequential", "Combinational", "Pipeline"]
    colors = [COLOR_SEQ, COLOR_COMB, COLOR_PIPE]

    fig, ax = plt.subplots(figsize=(10, 7))
    fig.patch.set_facecolor("#0d1117")

    for i in range(3):
        ax.scatter(lat[i], tput[i], s=bubble_sz[i], color=colors[i],
                   alpha=0.8, edgecolors="#0d1117", linewidths=1.5, zorder=3)
        offset_x = [3, 0.05, 0.3]
        offset_y = [0, 0.03, 0.03]
        ax.annotate(f"{names[i]}\n({cells[i]} cells)",
                    xy=(lat[i], tput[i]),
                    xytext=(lat[i] + offset_x[i], tput[i] + offset_y[i]),
                    fontsize=9.5, color=colors[i],
                    arrowprops=dict(arrowstyle="-", color=colors[i], lw=0.8))

    ax.set_xlabel("Latency (cycles, log scale)", fontsize=12)
    ax.set_ylabel("Throughput (results/cycle)", fontsize=12)
    ax.set_title("Throughput vs Latency vs Area — Design Tradeoff (W=64)",
                 fontsize=12, fontweight="bold", pad=12)
    ax.set_xscale("log")
    ax.set_xlim(0.5, 100)
    ax.set_ylim(-0.05, 1.2)
    ax.grid(True, zorder=0)

    # Bubble size legend
    for sz_cells, label in [(100, "100 cells"), (300, "300 cells")]:
        sz = (sz_cells / max_cells) * 3000 + 200
        ax.scatter([], [], s=sz, color="#8b949e", alpha=0.7, label=label)
    ax.legend(title="Area (bubble = cell count)", fontsize=9, title_fontsize=9)

    plt.tight_layout()
    plt.savefig(f"{ASSETS_DIR}/throughput_vs_latency.png", dpi=DPI,
                bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close()
    print("  Saved.")


# =============================================================================
# Plot 5: Tradeoff Radar Chart
# =============================================================================
def plot_tradeoff_radar():
    print("Generating assets/tradeoff_radar.png ...")
    sd = get_synth_data()

    W     = 64
    LOG2W = 6

    # Axes: Area Efficiency, Latency, Throughput, Timing Margin, Impl. Complexity
    axes  = ["Area\nEfficiency", "Latency\nScore", "Throughput", "Timing\nMargin",
             "Impl.\nSimplicity"]
    N     = len(axes)

    cells_seq  = sd["sequential"]["cells"]
    cells_comb = sd["combinational"]["cells"]
    cells_pipe = sd["pipeline"]["cells"]
    max_cells  = max(cells_seq, cells_comb, cells_pipe, 1)

    lvl_seq    = sd["sequential"]["logic_levels"]
    lvl_comb   = sd["combinational"]["logic_levels"]
    lvl_pipe   = sd["pipeline"]["logic_levels"]
    max_lvl    = max(lvl_seq, lvl_comb, lvl_pipe, 1)

    def norm(val, best, worst):
        """Normalize: best → 1.0, worst → 0.0"""
        if best == worst:
            return 0.5
        return (val - worst) / (best - worst)

    # Sequential: latency score = 0.5 (avg W/2), throughput = 1/W
    # Combinational: latency score = 1.0 (1 cyc), throughput = 1.0
    # Pipeline: latency score = LOG2W/W (moderate), throughput = 1.0

    designs = {
        "Sequential": [
            norm(cells_seq,  min(cells_seq, cells_comb, cells_pipe), max_cells),  # area eff (higher cells = lower score)
            1 - norm(W/2,    1, W),    # latency score (lower lat = higher score)
            norm(1/W,        1/W, 1),  # throughput
            norm(lvl_seq,    max_lvl, lvl_seq),  # timing margin (fewer levels = better)
            0.9,                        # implementation simplicity
        ],
        "Combinational": [
            norm(cells_comb, min(cells_seq, cells_comb, cells_pipe), max_cells),
            1.0,                        # 1-cycle latency → best score
            1.0,                        # 1 result/cycle
            norm(lvl_comb,   max_lvl, lvl_seq),
            0.7,                        # moderate complexity (two modes, generate trees)
        ],
        "Pipeline": [
            norm(cells_pipe, min(cells_seq, cells_comb, cells_pipe), max_cells),
            1 - norm(LOG2W,  1, W),
            1.0,
            norm(lvl_pipe,   max_lvl, lvl_seq),
            0.4,                        # most complex to implement
        ],
    }

    # Clamp all to [0, 1]
    for k in designs:
        designs[k] = [min(1.0, max(0.0, v)) for v in designs[k]]

    angles    = np.linspace(0, 2*np.pi, N, endpoint=False).tolist()
    angles   += angles[:1]   # close the loop

    fig, ax = plt.subplots(figsize=(8, 8), subplot_kw=dict(polar=True))
    fig.patch.set_facecolor("#0d1117")
    ax.set_facecolor("#161b22")

    colors = [COLOR_SEQ, COLOR_COMB, COLOR_PIPE]
    for (name, vals), color in zip(designs.items(), colors):
        vals_closed = vals + vals[:1]
        ax.plot(angles, vals_closed, color=color, linewidth=2.0, label=name)
        ax.fill(angles, vals_closed, color=color, alpha=0.15)

    ax.set_xticks(angles[:-1])
    ax.set_xticklabels(axes, fontsize=10.5, color="#e6edf3")
    ax.set_yticks([0.25, 0.5, 0.75, 1.0])
    ax.set_yticklabels(["0.25", "0.50", "0.75", "1.00"], fontsize=7,
                        color="#8b949e")
    ax.set_ylim(0, 1)
    ax.grid(color="#30363d", linewidth=0.8)
    ax.spines["polar"].set_color("#30363d")

    ax.set_title("Design Tradeoff Summary (W=64, normalized 0–1)",
                 fontsize=12, fontweight="bold", pad=18, color="#e6edf3")
    ax.legend(loc="upper right", bbox_to_anchor=(1.28, 1.12), fontsize=10)

    plt.tight_layout()
    plt.savefig(f"{ASSETS_DIR}/tradeoff_radar.png", dpi=DPI,
                bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close()
    print("  Saved.")


# =============================================================================
# Main
# =============================================================================
if __name__ == "__main__":
    print("=" * 60)
    print("FFS Plot Generator")
    print("=" * 60)

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        plot_latency_distribution()
        plot_area_comparison()
        plot_logic_levels()
        plot_throughput_vs_latency()
        plot_tradeoff_radar()

    print("\nAll plots written to assets/")
    print("Run 'make all' to populate with real synthesis/simulation data.")
