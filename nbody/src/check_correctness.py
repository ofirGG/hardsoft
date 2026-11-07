"""Check that optimized.py (or any variant given as an argument) simulates
exactly the same system as original.py.

Each module keeps its state in module-level lists, so both are loaded fresh,
run through the same sequence as bench_nbody(), and every coordinate,
velocity and energy value is compared bit for bit.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STEPS = 5000


def load(name):
    spec = importlib.util.spec_from_file_location(
        os.path.basename(name), os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def simulate(module):
    module.offset_momentum(module.BODIES["sun"])
    e0 = module.report_energy()
    module.advance(0.01, STEPS)
    e1 = module.report_energy()
    state = [(tuple(r), tuple(v)) for r, v, _ in module.SYSTEM]
    return e0, e1, state


def main():
    # Default: optimized.py. Any other src/-relative module can be passed,
    # e.g. ablation/step1_unroll.
    candidates = sys.argv[1:] or ["optimized"]
    ref = simulate(load("original"))
    print("original : e0=%.17g e1=%.17g" % ref[:2])
    for name in candidates:
        out = simulate(load(name))
        print("%s: e0=%.17g e1=%.17g" % (name, out[0], out[1]))
        if ref != out:
            print("MISMATCH: %s results differ from the original" % name)
            sys.exit(1)
        print("OK (%s): energies and all body positions/velocities are "
              "bit-identical after %d steps" % (name, STEPS))


if __name__ == "__main__":
    main()
