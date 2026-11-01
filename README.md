# HWSW Project: Benchmark Optimization and Hardware Acceleration

This project analyzes, optimizes and proposes hardware acceleration for two
[pyperformance](https://pyperformance.readthedocs.io/) benchmarks: **nbody** and **raytrace**.

## Results at a glance

| Benchmark | Original | Optimized | Speedup | Output check | Accelerator | HW verification |
|-----------|----------|-----------|---------|--------------|-------------|-----------------|
| nbody     | 232 ms ± 5 ms | 144 ms ± 3 ms | **1.61×** (−38%) | bit-identical | `nbody_accel`: full time-step loop, 390 cycles/step | PASS, ≤ 3.7e-15 rel. error over 1000 steps |
| raytrace  | 800 ms ± 5 ms | 257 ms ± 1 ms | **3.11×** (−68%) | byte-identical image | `ray_sphere_accel`: ray vs. sphere table, 78 cycles/query | PASS, 458/458 queries, t within 2.4e-16 |

Measured with pyperf in the course QEMU/KVM VM (Ubuntu 22.04, CPython 3.10.12,
Xeon E5-2630 v3 host). The full analysis is in `nbody/report_nbody.txt` and
`raytrace/report_raytrace.txt`.

## Repository structure

```
.
├── common/
│   ├── start_vm.sh          # boots the course QEMU image under KVM on the CSL server (tmux, SSH forward)
│   ├── setup_env.sh         # one-time VM setup: perf, python3-dbg, pyperformance, FlameGraph, iverilog
│   ├── pipeline.sh          # shared pipeline stages used by both benchmark scripts
│   ├── cprofile_bench.py    # in-process cProfile of one benchmark iteration
│   ├── rtl/                 # binary64 FP library: fp_add, fp_mul, fp_rsqrt, fp_lt
│   └── tb/tb_fp.v           # FP library testbench (bit-exact vs IEEE double)
├── nbody/
│   ├── script_nbody.sh      # runs the full pipeline for nbody
│   ├── report_nbody.txt     # analysis, optimizations, results, HW proposal
│   ├── src/
│   │   ├── original.py            # unmodified benchmark (pyperformance 1.14.0)
│   │   ├── optimized.py           # optimized benchmark
│   │   └── check_correctness.py   # optimized vs original, bit-exact
│   ├── results/             # pyperformance baseline, perf reports, flame graphs,
│   │                        # cProfile, before/after pyperf JSON, comparison.txt
│   └── hw/
│       ├── rtl/nbody_accel.v      # accelerator RTL
│       ├── tb/                    # testbench + golden-vector generator (from original.py)
│       ├── docs/                  # block diagram (SVG)
│       ├── run_sim.sh             # generate vectors, compile, simulate
│       └── sim_result.txt         # last simulation output
└── raytrace/                # same layout as nbody/, plus
    └── src/measure_intersection_share.py   # Amdahl fraction for the accelerator
```

## How to run

### 0. Start the VM (on the CSL server, once per boot)

`common/start_vm.sh` runs on naranja7. That's the server where the course account has
`/dev/kvm` access. It boots the image in a tmux session with SSH forwarded to port 22041,
then asks once for the VM root password.

### 1. One-time setup inside the VM

```bash
./common/setup_env.sh
```

### 2. Benchmarks

```bash
./nbody/script_nbody.sh
./raytrace/script_raytrace.sh
```

You can also run a single stage: `./nbody/script_nbody.sh <stage>`

| Stage      | What it does |
|------------|--------------|
| `baseline` | Official `pyperformance run --bench <name>` → `results/pyperformance_baseline.{json,txt}` |
| `fetch`    | Copies the original benchmark to `src/original.py`, and seeds `src/optimized.py` the first time |
| `check`    | Runs `src/check_correctness.py` |
| `profile`  | `perf record -e cpu-clock -F 999 -g` with `python3-dbg` for the original and the optimized code → `perf_report_*.txt`, `flamegraph_*.svg` |
| `cprofile` | Python-level cProfile for the original and the optimized code → `cprofile_*.txt` |
| `compare`  | Times both versions with pyperf (release `python3`) → `before.json`, `after.json`, `comparison.txt` |
| `all`      | All of the stages above, in order (this is the default) |

### 3. Hardware simulation (Icarus Verilog)

```bash
iverilog -g2012 -o /tmp/tb_fp.vvp common/rtl/*.v common/tb/tb_fp.v && vvp -n /tmp/tb_fp.vvp
./nbody/hw/run_sim.sh          # 1000 time steps vs the Python original
./raytrace/hw/run_sim.sh       # 20x20 primary rays + their shadow rays vs the Python original
```

Each `run_sim.sh` first runs a Python generator. The generator executes the **original**
benchmark code and writes golden vectors. The testbench then plays the role of the host
driver over the MMIO register interface and checks the results.

## Methodology notes

- Timing uses the release build `python3`. Profiling uses `python3-dbg`, so that CPython's
  internal symbols show up in the perf output.
- perf samples with `cpu-clock`. The hardware `cycles` event takes no sampling interrupts
  inside this QEMU guest, so perf recorded 0 samples with it.
- The original and the optimized code are timed with the same pyperf runner, so the
  comparison is fair.
- Both optimizations keep the floating-point operation order. The outputs are therefore
  identical, not just approximately equal; `check_correctness.py` verifies this.
- Measurements come from a VM, so they are noisy. Look at the `±` std before concluding
  anything.
