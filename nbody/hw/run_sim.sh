#!/usr/bin/env bash
# Simulate the nbody accelerator against the original Python benchmark.
# Usage: ./run_sim.sh [steps]   (default 1000)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
STEPS="${1:-1000}"
LIB=../../common/rtl

python3 tb/gen_vectors.py "$STEPS"
iverilog -g2012 -Ptb_nbody_accel.STEPS="$STEPS" -o sim.vvp \
    $LIB/fp_add.v $LIB/fp_mul.v $LIB/fp_rsqrt.v rtl/nbody_accel.v tb/tb_nbody_accel.v
cd tb && vvp -n ../sim.vvp | tee ../sim_result.txt
