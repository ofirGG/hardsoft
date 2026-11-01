"""Check that optimized.py simulates exactly the same system as original.py.

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
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
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
    ref = simulate(load("original"))
    opt = simulate(load("optimized"))
    print("original : e0=%.17g e1=%.17g" % ref[:2])
    print("optimized: e0=%.17g e1=%.17g" % opt[:2])
    if ref != opt:
        print("MISMATCH: optimized results differ from the original")
        sys.exit(1)
    print("OK: energies and all body positions/velocities are bit-identical "
          "after %d steps" % STEPS)


if __name__ == "__main__":
    main()
