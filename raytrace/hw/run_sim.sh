#!/usr/bin/env bash
# Simulate the ray-sphere accelerator against the original Python benchmark:
#   1. ray_sphere_accel, one query per MMIO call  -> sim_result.txt
#   2. ray_batch_accel, all rays as one streamed batch, without and with
#      random stalls on both streams               -> sim_result_batch.txt
# Usage: ./run_sim.sh [grid]   (default 20: a 20x20 pixel sub-sample + shadow rays)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
GRID="${1:-20}"
LIB=../../common/rtl
FP="$LIB/fp_add.v $LIB/fp_mul.v $LIB/fp_rsqrt.v $LIB/fp_lt.v"

python3 tb/gen_vectors.py "$GRID"
NTESTS=$(cat tb/ray_tests.count)

iverilog -g2012 -Ptb_ray_sphere_accel.NTESTS="$NTESTS" -o sim.vvp \
    $FP rtl/ray_sphere_accel.v tb/tb_ray_sphere_accel.v
(cd tb && vvp -n ../sim.vvp) | tee sim_result.txt

: > sim_result_batch.txt
for stall in 0 1; do
    iverilog -g2012 -Ptb_ray_batch_accel.NTESTS="$NTESTS" -Ptb_ray_batch_accel.STALL="$stall" \
        -o sim_batch.vvp $FP rtl/ray_sphere_accel.v rtl/ray_batch_accel.v tb/tb_ray_batch_accel.v
    (cd tb && vvp -n ../sim_batch.vvp) | tee -a sim_result_batch.txt
done
