#!/usr/bin/env bash
# Logic synthesis of the FP library and both accelerators with Yosys.
#
# For every top module two flows are run:
#   xc7  : synth_xilinx for a Xilinx 7-series FPGA -> LUT / FF / carry-chain /
#          RAM cell counts. Yosys 0.9 (Ubuntu 22.04) does not infer DSP48
#          blocks, so every multiplier is built from LUTs and carry chains:
#          the LUT counts are an upper bound (a vendor tool would move each
#          53x53 product into DSP48 slices).
#   gates: generic synthesis mapped to simple 2-input gates, MUX2 and flip-flops
#          -> a technology-neutral gate count, converted to NAND2 equivalents.
# Both netlists are checked with `check -assert` (no combinational loops, no
# undriven or multiply driven nets). The gate flow uses -noshare: Yosys 0.9's
# SAT-based resource sharing merges the mutually exclusive reads bm[i] / bm[j]
# of nbody_accel and its activation logic forms a structural (never
# sensitized) loop through the multiplier, which `check` rejects.
# Yosys does no timing analysis, so clock frequencies remain estimates.
# Results: results/<top>_xc7.txt, results/<top>_gates.txt and summary.txt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT=../..
FP="$ROOT/common/rtl/fp_add.v $ROOT/common/rtl/fp_mul.v $ROOT/common/rtl/fp_rsqrt.v $ROOT/common/rtl/fp_lt.v"
NB="$ROOT/nbody/hw/rtl/nbody_accel.v"
RS="$ROOT/raytrace/hw/rtl/ray_sphere_accel.v"
RB="$ROOT/raytrace/hw/rtl/ray_batch_accel.v"
OUT=results
mkdir -p "$OUT"

TOPS="fp_add fp_mul fp_lt fp_rsqrt nbody_accel ray_sphere_accel ray_batch_accel"

for top in $TOPS; do
    echo "== $top"
    yosys -q -l "$OUT/${top}_xc7.log" -p "
        read_verilog $FP $NB $RS $RB
        synth_xilinx -family xc7 -flatten -top $top
        check -assert
        tee -o $OUT/${top}_xc7.txt stat"
    yosys -q -l "$OUT/${top}_gates.log" -p "
        read_verilog $FP $NB $RS $RB
        synth -flatten -noshare -top $top
        abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX
        opt_clean
        check -assert
        tee -o $OUT/${top}_gates.txt stat"
done

python3 summarize.py $TOPS | tee summary.txt
