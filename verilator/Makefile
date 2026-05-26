# =============================================================================
# verilator/Makefile  —  Verilator build + run for all three FFS designs
# Usage: make verilator_all  (from verilator/ directory)
#        OR: make verilator  (from project root, which calls this)
# =============================================================================

RTL      := ../rtl
REPORTS  := ../reports
VFLAGS   := --cc --exe --build -sv -Wall --Wno-fatal

.PHONY: all verilator_seq verilator_comb verilator_pipe clean

all: verilator_seq verilator_comb verilator_pipe

# ── Sequential ──────────────────────────────────────────────────────────────
verilator_seq: obj_dir_seq/Vffs_sequential
	@echo "Running sequential simulation..."
	@mkdir -p $(REPORTS)
	cd .. && verilator/obj_dir_seq/Vffs_sequential

obj_dir_seq/Vffs_sequential: $(RTL)/ffs_sequential.sv sim_sequential.cpp
	verilator $(VFLAGS) \
		--top-module ffs_sequential \
		-I$(RTL) \
		--Mdir obj_dir_seq \
		$(RTL)/ffs_sequential.sv \
		sim_sequential.cpp

# ── Combinational ────────────────────────────────────────────────────────────
verilator_comb: obj_dir_comb/Vffs_combinational
	@echo "Running combinational simulation..."
	@mkdir -p $(REPORTS)
	cd .. && verilator/obj_dir_comb/Vffs_combinational

obj_dir_comb/Vffs_combinational: $(RTL)/ffs_combinational.sv sim_combinational.cpp
	verilator $(VFLAGS) \
		--top-module ffs_combinational \
		-I$(RTL) \
		--Mdir obj_dir_comb \
		$(RTL)/ffs_combinational.sv \
		sim_combinational.cpp

# ── Pipeline ─────────────────────────────────────────────────────────────────
verilator_pipe: obj_dir_pipe/Vffs_pipeline
	@echo "Running pipeline simulation..."
	@mkdir -p $(REPORTS)
	cd .. && verilator/obj_dir_pipe/Vffs_pipeline

obj_dir_pipe/Vffs_pipeline: $(RTL)/ffs_pipeline.sv sim_pipeline.cpp
	verilator $(VFLAGS) \
		--top-module ffs_pipeline \
		-I$(RTL) \
		--Mdir obj_dir_pipe \
		$(RTL)/ffs_pipeline.sv \
		sim_pipeline.cpp

clean:
	rm -rf obj_dir_seq obj_dir_comb obj_dir_pipe
