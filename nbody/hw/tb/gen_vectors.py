"""Generate golden vectors for tb_nbody_accel.v from the original benchmark.

Writes nbody_vectors.hex: one 64-bit hex word per line,
  5 bodies x 7 fields (x, y, z, vx, vy, vz, m) of the initial state
  (after offset_momentum, as in bench_nbody), followed by
  5 bodies x 7 fields of the state after STEPS calls of advance(DT, 1).
"""
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "src", "original.py")
STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
DT = 0.01


def load_original():
    spec = importlib.util.spec_from_file_location("original", SRC)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def words(system):
    out = []
    for r, v, m in system:
        out += [*r, *v, m]
    return out


def main():
    nb = load_original()
    nb.offset_momentum(nb.BODIES["sun"])
    initial = words(nb.SYSTEM)
    nb.advance(DT, STEPS)
    final = words(nb.SYSTEM)
    with open(os.path.join(HERE, "nbody_vectors.hex"), "w") as f:
        for value in initial + final:
            f.write("%016x\n" % struct.unpack("<Q", struct.pack("<d", value))[0])
    print("wrote %d words (%d bodies, %d steps)" % (len(initial) * 2, len(nb.SYSTEM), STEPS))


if __name__ == "__main__":
    main()
