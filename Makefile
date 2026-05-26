# =============================================================================
# Makefile  —  Top-level build system for Find First Set Bit project
# =============================================================================
# Targets:
#   make all         — sim + verilator + synth + plot
#   make sim         — Icarus Verilog functional simulation
#   make verilator   — Verilator cycle-accurate simulation
#   make synth       — Yosys synthesis (all three designs)
#   make plot        — Generate charts from reports/
#   make syntax      — iverilog syntax check (RTL only)
#   make clean       — Remove all generated files
# =============================================================================

IVERILOG := iverilog
VVPE     := vvp
YOSYS    := yosys
PYTHON   := python3

RTL      := rtl
TB       := tb
REPORTS  := reports
ASSETS   := assets

.PHONY: all sim sim_seq sim_comb sim_pipe verilator synth plot syntax clean

# ── Default: run everything ──────────────────────────────────────────────────
all: syntax sim verilator synth plot
	@echo ""
	@echo "════════════════════════════════════════"
	@echo "  All targets complete."
	@echo "  Reports : $(REPORTS)/"
	@echo "  Charts  : $(ASSETS)/"
	@echo "════════════════════════════════════════"

# ── Syntax check (iverilog, no simulation) ───────────────────────────────────
syntax:
	@echo "── Syntax check ────────────────────────────────"
	$(IVERILOG) -g2012 -tnull $(RTL)/ffs_sequential.sv    && echo "  ffs_sequential   : OK"
	$(IVERILOG) -g2012 -tnull $(RTL)/ffs_combinational.sv && echo "  ffs_combinational: OK"
	$(IVERILOG) -g2012 -tnull $(RTL)/ffs_pipeline.sv      && echo "  ffs_pipeline     : OK"

# ── Functional simulation (Icarus Verilog) ───────────────────────────────────
sim: $(REPORTS)/sim_comparison.csv
	@echo "  Simulation CSV: $(REPORTS)/sim_comparison.csv"

$(REPORTS)/sim_comparison.csv: $(TB)/tb_ffs_top.sv \
                                $(RTL)/ffs_sequential.sv \
                                $(RTL)/ffs_combinational.sv \
                                $(RTL)/ffs_pipeline.sv
	@mkdir -p $(REPORTS)
	@echo "── Functional simulation ───────────────────────"
	$(IVERILOG) -g2012 -Wall \
		-I$(RTL) \
		$(RTL)/ffs_sequential.sv \
		$(RTL)/ffs_combinational.sv \
		$(RTL)/ffs_pipeline.sv \
		$(TB)/tb_ffs_top.sv \
		-o $(REPORTS)/sim_top
	cd $(REPORTS) && $(VVPE) sim_top

sim_seq:
	@mkdir -p $(REPORTS)
	$(IVERILOG) -g2012 -I$(RTL) \
		$(RTL)/ffs_sequential.sv \
		$(TB)/tb_ffs_top.sv \
		-o $(REPORTS)/sim_seq
	cd $(REPORTS) && $(VVPE) sim_seq

# ── Verilator cycle-accurate simulation ──────────────────────────────────────
verilator:
	@echo "── Verilator simulation ────────────────────────"
	@mkdir -p $(REPORTS)
	$(MAKE) -C verilator all

# ── Yosys synthesis ──────────────────────────────────────────────────────────
synth: $(REPORTS)/synth_summary.txt

$(REPORTS)/synth_summary.txt: synth/synth_sequential.ys \
                               synth/synth_combinational.ys \
                               synth/synth_pipeline.ys \
                               synth/asap7_approx.lib \
                               $(RTL)/ffs_sequential.sv \
                               $(RTL)/ffs_combinational.sv \
                               $(RTL)/ffs_pipeline.sv
	@echo "── Yosys synthesis ─────────────────────────────"
	@mkdir -p $(REPORTS)
	bash synth/run_synth.sh

# ── Plot generation ───────────────────────────────────────────────────────────
plot:
	@echo "── Generating charts ───────────────────────────"
	@mkdir -p $(ASSETS)
	$(PYTHON) scripts/plot_results.py

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	@echo "── Cleaning ────────────────────────────────────"
	rm -rf $(REPORTS)/*.csv $(REPORTS)/*.txt $(REPORTS)/*.json \
	       $(REPORTS)/*.v   $(REPORTS)/sim_* $(REPORTS)/netlist_*
	rm -rf $(ASSETS)/*.png
	rm -rf verilator/obj_dir_seq verilator/obj_dir_comb verilator/obj_dir_pipe
	@echo "  Done."
