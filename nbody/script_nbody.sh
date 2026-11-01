#!/usr/bin/env bash
# Full pipeline for the pyperformance "nbody" benchmark.
# Usage: ./script_nbody.sh [baseline|fetch|check|profile|cprofile|compare|all]   (default: all)
# Run common/setup_env.sh once before the first run.
set -euo pipefail

BENCH=nbody
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_DIR/../common/pipeline.sh"

run_stages "${1:-all}"
