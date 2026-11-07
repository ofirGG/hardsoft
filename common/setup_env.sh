#!/usr/bin/env bash
# One-time environment setup inside the Ubuntu 22.04 (jammy) QEMU VM.
# Installs perf, the Python debug build, pyperformance/pyperf, FlameGraph,
# and Icarus Verilog for simulating the hardware designs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[setup] Installing system packages..."
sudo apt-get update
sudo apt-get install -y \
    linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic \
    python3 python3-dbg python3-pip python3-venv \
    git perl iverilog gtkwave yosys

echo "[setup] Installing pyperformance and pyperf..."
python3 -m pip install --user --upgrade pyperformance pyperf

echo "[setup] Fetching FlameGraph tools..."
if [ ! -d "$REPO_ROOT/tools/FlameGraph" ]; then
    git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "$REPO_ROOT/tools/FlameGraph"
fi

# Allow perf to sample without root and see kernel symbols.
echo "[setup] Relaxing perf restrictions for this boot..."
sudo sysctl -w kernel.perf_event_paranoid=-1
sudo sysctl -w kernel.kptr_restrict=0

echo "[setup] Done."
python3 -m pyperformance --version
perf --version
