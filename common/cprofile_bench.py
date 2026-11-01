"""Run one benchmark iteration in-process under cProfile.

pyperf always runs the timed code in worker processes, which cProfile cannot
follow, so this loads the benchmark module and calls its bench function
directly with the benchmark's default arguments.

Usage: python3 cprofile_bench.py <benchmark> <path/to/module.py> [top_n]
"""
import cProfile
import importlib.util
import pstats
import sys

BENCH_CALLS = {
    "nbody": ("bench_nbody", (1, "sun", 20000)),
    "raytrace": ("bench_raytrace", (1, 100, 100, None)),
}


def main():
    bench, path = sys.argv[1], sys.argv[2]
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 25
    spec = importlib.util.spec_from_file_location("bench_module", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    func_name, args = BENCH_CALLS[bench]
    func = getattr(module, func_name)
    profiler = cProfile.Profile()
    profiler.runcall(func, *args)
    stats = pstats.Stats(profiler, stream=sys.stdout)
    stats.strip_dirs().sort_stats("tottime").print_stats(top)


if __name__ == "__main__":
    main()
