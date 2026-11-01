#!/usr/bin/env bash
# Simulate the ray-sphere accelerator against the original Python benchmark.
# Usage: ./run_sim.sh [grid]   (default 20: a 20x20 pixel sub-sample + shadow rays)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
GRID="${1:-20}"
LIB=../../common/rtl

python3 tb/gen_vectors.py "$GRID"
NTESTS=$(cat tb/ray_tests.count)
iverilog -g2012 -Ptb_ray_sphere_accel.NTESTS="$NTESTS" -o sim.vvp \
    $LIB/fp_add.v $LIB/fp_mul.v $LIB/fp_rsqrt.v $LIB/fp_lt.v \
    rtl/ray_sphere_accel.v tb/tb_ray_sphere_accel.v
cd tb && vvp -n ../sim.vvp | tee ../sim_result.txt
