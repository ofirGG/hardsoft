# HWSW Project: Benchmark Optimization and Hardware Acceleration

This project analyzes, optimizes and proposes hardware acceleration for two
[pyperformance](https://pyperformance.readthedocs.io/) benchmarks: **nbody** and **raytrace**.

## Repository structure

```
.
├── common/
│   ├── setup_env.sh        # one-time VM setup: perf, python3-dbg, pyperformance, FlameGraph, iverilog
│   └── pipeline.sh         # shared pipeline stages used by both benchmark scripts
├── nbody/
│   ├── script_nbody.sh     # runs the full pipeline for nbody
│   ├── report_nbody.txt    # analysis, optimizations, results, HW proposal
│   ├── src/
│   │   ├── original.py           # unmodified benchmark (copied from pyperformance)
│   │   ├── optimized.py          # optimized benchmark
│   │   └── check_correctness.py  # checks that optimized == original output
│   ├── results/            # perf reports, flame graphs (.svg), pyperf JSON, comparison
│   └── hw/
│       ├── rtl/            # Verilog/SystemVerilog accelerator
│       ├── tb/             # testbench
│       └── docs/           # block diagram
└── raytrace/               # same layout as nbody/
```

## How to run

All commands run inside the Ubuntu 22.04 QEMU VM.

1. One-time setup:
   ```bash
   ./common/setup_env.sh
   ```
2. Run the full pipeline for a benchmark:
   ```bash
   ./nbody/script_nbody.sh
   ./raytrace/script_raytrace.sh
   ```
   You can also run a single stage: `./nbody/script_nbody.sh <stage>`

| Stage      | What it does |
|------------|--------------|
| `baseline` | Official `pyperformance run --bench <name>` → `results/pyperformance_baseline.{json,txt}` |
| `fetch`    | Copies the original benchmark to `src/original.py`, and seeds `src/optimized.py` the first time |
| `check`    | Runs `src/check_correctness.py` (if it exists) |
| `profile`  | `perf record -F 999 -g` with `python3-dbg` for the original and optimized code → `perf_report_*.txt`, `flamegraph_*.svg` |
| `compare`  | Times both versions with pyperf (release `python3`) → `before.json`, `after.json`, `comparison.txt` |
| `all`      | All of the stages above, in order (this is the default) |

### Methodology notes
- Timing uses the release build `python3`. Profiling uses `python3-dbg` so that CPython-internal symbols appear in perf output.
- The original and the optimized code are timed with the same pyperf runner, so the comparison is fair.
- Measurements come from a VM, so they are noisy. Look at the `±` std in `comparison.txt` before concluding anything.

## Hardware simulation

```bash
cd nbody/hw && iverilog -g2012 -o sim.vvp rtl/*.v tb/*.v && vvp sim.vvp
```
