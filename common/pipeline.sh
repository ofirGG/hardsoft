#!/usr/bin/env bash
# Shared benchmark pipeline, sourced by <bench>/script_<bench>.sh.
# The caller sets BENCH (pyperformance benchmark name) and BENCH_DIR.
#
# Stages:
#   baseline  - official pyperformance run of the unmodified benchmark
#   fetch     - copy the original benchmark source into src/ (and seed optimized.py)
#   check     - verify optimized.py produces the same results as original.py
#   profile   - perf record + report + flame graph, for original and optimized
#   cprofile  - Python-level cProfile breakdown, for original and optimized
#   compare   - time original vs optimized with pyperf and print the comparison
#   ablation  - time each cumulative optimization step (src/ablation/step*.py)
#   all       - every stage above, in order
set -euo pipefail

: "${BENCH:?BENCH must be set}"
: "${BENCH_DIR:?BENCH_DIR must be set}"

REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"
SRC="$BENCH_DIR/src"
RES="$BENCH_DIR/results"
FLAMEGRAPH="$REPO_ROOT/tools/FlameGraph"
PY=python3          # release build: used for all timing
PY_DBG=python3-dbg  # debug build: used for profiling (gives CPython symbols)
# The QEMU guest counts hardware cycles but gets no sampling interrupts from
# them, so `perf record -e cycles` collects nothing. The cpu-clock software
# timer samples correctly at the same frequency.
PERF_EVENT="${PERF_EVENT:-cpu-clock}"

mkdir -p "$RES" "$SRC"

log() { echo -e "\n[$BENCH] $*"; }

stage_baseline() {
    log "Official pyperformance baseline run"
    rm -f "$RES/pyperformance_baseline.json"
    "$PY" -m pyperformance run --bench "$BENCH" -o "$RES/pyperformance_baseline.json"
    "$PY" -m pyperf show "$RES/pyperformance_baseline.json" | tee "$RES/pyperformance_baseline.txt"
}

stage_fetch() {
    log "Copying original benchmark source"
    local pkg_dir
    pkg_dir="$("$PY" -c 'import os, pyperformance; print(os.path.dirname(pyperformance.__file__))')"
    cp "$pkg_dir/data-files/benchmarks/bm_$BENCH/run_benchmark.py" "$SRC/original.py"
    if [ ! -f "$SRC/optimized.py" ]; then
        cp "$SRC/original.py" "$SRC/optimized.py"
        log "Seeded src/optimized.py from the original - apply your optimizations there"
    fi
}

stage_check() {
    if [ -f "$SRC/check_correctness.py" ]; then
        log "Checking that optimized.py matches original.py"
        "$PY" "$SRC/check_correctness.py"
    else
        log "No src/check_correctness.py yet - skipping correctness check"
    fi
}

# profile_one <name> : perf record/report + flame graph for src/<name>.py
profile_one() {
    local name="$1"
    local data="$RES/perf_$name.data"
    log "Profiling $name.py with perf ($PY_DBG)"
    perf record -e "$PERF_EVENT" -F 999 -g -o "$data" -- \
        "$PY_DBG" "$SRC/$name.py" --fast -o "$RES/.profile_tmp.json"
    rm -f "$RES/.profile_tmp.json"
    perf report -i "$data" --stdio > "$RES/perf_report_$name.txt" 2>/dev/null
    perf script -i "$data" \
        | "$FLAMEGRAPH/stackcollapse-perf.pl" > "$RES/$name.folded"
    "$FLAMEGRAPH/flamegraph.pl" --title "$BENCH ($name)" \
        "$RES/$name.folded" > "$RES/flamegraph_$name.svg"
    log "Wrote results/perf_report_$name.txt and results/flamegraph_$name.svg"
}

stage_profile() {
    [ -x "$FLAMEGRAPH/flamegraph.pl" ] || { echo "Run common/setup_env.sh first"; exit 1; }
    profile_one original
    profile_one optimized
}

# perf sees CPython's C functions; cProfile attributes time to Python functions.
stage_cprofile() {
    local name
    for name in original optimized; do
        log "cProfile of $name.py (one in-process benchmark iteration)"
        "$PY" "$REPO_ROOT/common/cprofile_bench.py" "$BENCH" "$SRC/$name.py" \
            > "$RES/cprofile_$name.txt"
    done
}

stage_compare() {
    log "Timing original vs optimized with pyperf (release build)"
    rm -f "$RES/before.json" "$RES/after.json"
    "$PY" "$SRC/original.py"  -o "$RES/before.json"
    "$PY" "$SRC/optimized.py" -o "$RES/after.json"
    "$PY" -m pyperf compare_to "$RES/before.json" "$RES/after.json" --table \
        | tee "$RES/comparison.txt"
}

# Every src/ablation/stepN_<name>.py adds one optimization on top of the
# previous step; the last step is optimized.py itself. All variants are checked
# for identical output, then timed in one session so the numbers are comparable.
stage_ablation() {
    local out="$RES/ablation" steps=() files=() f name
    mkdir -p "$out"
    for f in "$SRC"/ablation/step*.py; do
        steps+=("ablation/$(basename "$f" .py)")
    done
    log "Checking ablation variants: ${steps[*]}"
    "$PY" "$SRC/check_correctness.py" "${steps[@]}" optimized
    for name in original "${steps[@]}" optimized; do
        log "Timing $name.py"
        rm -f "$out/$(basename "$name").json"
        "$PY" "$SRC/$name.py" -o "$out/$(basename "$name").json"
        files+=("$out/$(basename "$name").json")
    done
    "$PY" -m pyperf compare_to "${files[@]}" --table | tee "$out/ablation.txt"
}

run_stages() {
    local stage="${1:-all}"
    case "$stage" in
        baseline) stage_baseline ;;
        fetch)    stage_fetch ;;
        check)    stage_check ;;
        profile)  stage_profile ;;
        cprofile) stage_cprofile ;;
        compare)  stage_compare ;;
        ablation) stage_ablation ;;
        all)      stage_baseline; stage_fetch; stage_check; stage_profile; stage_cprofile; stage_compare; stage_ablation ;;
        *) echo "Usage: $0 [baseline|fetch|check|profile|cprofile|compare|ablation|all]"; exit 1 ;;
    esac
}
