"""Check that optimized.py (or any variant given as an argument) renders
exactly the same image as original.py.

Builds the benchmark scene with each module, renders it, and compares the
raw RGB canvas bytes.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WIDTH = HEIGHT = 100


def load(name):
    spec = importlib.util.spec_from_file_location(
        os.path.basename(name), os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render(m):
    # Same scene as bench_raytrace()
    canvas = m.Canvas(WIDTH, HEIGHT)
    s = m.Scene()
    s.addLight(m.Point(30, 30, 10))
    s.addLight(m.Point(-10, 100, 30))
    s.lookAt(m.Point(0, 3, 0))
    s.addObject(m.Sphere(m.Point(1, 3, -10), 2),
                m.SimpleSurface(baseColour=(1, 1, 0)))
    for y in range(6):
        s.addObject(m.Sphere(m.Point(-3 - y * 0.4, 2.3, -5), 0.4),
                    m.SimpleSurface(baseColour=(y / 6.0, 1 - y / 6.0, 0.5)))
    s.addObject(m.Halfspace(m.Point(0, 0, 0), m.Vector.UP),
                m.CheckerboardSurface())
    s.render(canvas)
    return canvas.bytes.tobytes()


def main():
    # Default: optimized.py. Any other src/-relative module can be passed,
    # e.g. ablation/step1_slots.
    candidates = sys.argv[1:] or ["optimized"]
    ref = render(load("original"))
    for name in candidates:
        out = render(load(name))
        if ref != out:
            diff = sum(a != b for a, b in zip(ref, out))
            print("MISMATCH (%s): %d of %d bytes differ" % (name, diff, len(ref)))
            sys.exit(1)
        print("OK (%s): %dx%d image is byte-identical (%d bytes)"
              % (name, WIDTH, HEIGHT, len(ref)))


if __name__ == "__main__":
    main()
