# === AES-256 ECB KAT for rtl/aes256_core.sv (NIST AESAVS / Synopsys VCS) ===
#
#   make sim                full 405-vector verification
#   make sim WAVE=1         run first MAXV vectors and dump FSDB
#   make sim WAVE=1 MAXV=20
#   make sim COV=1          collect code coverage
#   make verdi              open FSDB in Verdi
#   make cov                open coverage report in Verdi
#   make clean
#
# This is a plain SystemVerilog testbench; UVM is not required.

VEC  ?= ./kat_vectors
MAXV ?= 0
# MAXV=0 runs all 405 vectors; use a small value for short waveforms.

VCS_OPTS := -full64 -sverilog
VCS_OPTS += -timescale=1ns/1ps
VCS_OPTS += -debug_access+all -kdb -lca
VCS_OPTS += +incdir+./tb
#VCS_OPTS += -ntb_opts uvm-1.2

SIM_OPTS := +VECDIR=$(VEC)

ifeq ($(WAVE),1)
  VCS_OPTS += +define+KAT_DUMP_FSDB +define+KAT_MAX_VECTORS=$(MAXV)
endif

ifeq ($(COV),1)
  VCS_OPTS += -cm line+cond+fsm+tgl+branch
  SIM_OPTS += -cm line+cond+fsm+tgl+branch
  SIM_OPTS += -cm_dir coverage.vdb -cm_name aes256_kat
endif

VERDI_OPTS := -dbdir simv.daidir -ssf aes_core_kat.fsdb

CUR_TIME := $(shell date +%Y%m%d_%H%M%S)
LOG      := logs/aes256_kat_$(CUR_TIME).log

.PHONY: compile sim gui verdi cov clean help

compile:
	vcs $(VCS_OPTS) -f filelist.f -o simv

# Check the verdict because some simulators return zero after $$fatal.
sim: compile
	@mkdir -p logs
	./simv $(SIM_OPTS) -l $(LOG)
	@grep -q "RESULT     : PASS" $(LOG) \
	    || { echo "*** AES-256 KAT FAILED - see $(LOG)"; exit 1; }
ifeq ($(MAXV),0)
	@echo "AES-256 KAT PASS - all 405 vectors ($(LOG))"
else
	@echo "AES-256 KAT PASS - LIMITED to $(MAXV) vectors/file (NOT full verification)"
endif

# Run interactively under Verdi.
gui: compile
	@mkdir -p logs
	./simv $(SIM_OPTS) -gui=verdi

# Open an existing FSDB after simulation.
verdi:
	@test -f aes_core_kat.fsdb \
	    || { echo "No FSDB.  Run: make sim WAVE=1"; exit 1; }
	verdi $(VERDI_OPTS) &

cov:
	@test -d coverage.vdb \
	    || { echo "No coverage data.  Run: make sim COV=1"; exit 1; }
	verdi -cov -covdir coverage.vdb &

clean:
	rm -rf simv* csrc *.log *.vpd *.fsdb *.key *.h DVE* novas* *.conf *.vdb *Log
	rm -rf logs .inter.vpd.uvm ucli.key AN.DB

help:
	@echo "make sim                full 405-vector verification"
	@echo "make sim WAVE=1         $(MAXV) vectors + FSDB"
	@echo "make sim WAVE=1 MAXV=20"
	@echo "make sim COV=1          collect coverage"
	@echo "make gui                run under Verdi (interactive)"
	@echo "make verdi / make cov / make clean"
	@echo ""
	@echo "VEC  = $(VEC)"
	@echo "LOG  = $(LOG)"
