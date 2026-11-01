"""Generate golden vectors for tb_ray_sphere_accel.v from the original benchmark.

Builds the benchmark scene with the original classes and produces
  * primary rays: the render() ray of every pixel of a GRID x GRID sub-sample
    (nearest-hit mode, t > -EPSILON), and
  * shadow rays: from each primary hit point towards each light
    (any-hit mode, t > EPSILON),
with the expected answer computed by the original Sphere.intersectionTime and
the original hit-selection rules, restricted to the spheres (the ground plane
stays in software).

Output files (64-bit hex words, one per line):
  ray_spheres.hex : 7 spheres x (cx, cy, cz, r^2)
  ray_tests.hex   : per test: mode, px, py, pz, dx, dy, dz, hit, index, t
"""
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "src", "original.py")
GRID = int(sys.argv[1]) if len(sys.argv) > 1 else 20


def bits(x):
    return struct.unpack("<Q", struct.pack("<d", float(x)))[0]


def load_original():
    spec = importlib.util.spec_from_file_location("original", SRC)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_scene(m):
    # Same scene as bench_raytrace()
    s = m.Scene()
    s.addLight(m.Point(30, 30, 10))
    s.addLight(m.Point(-10, 100, 30))
    s.lookAt(m.Point(0, 3, 0))
    s.addObject(m.Sphere(m.Point(1, 3, -10), 2), m.SimpleSurface(baseColour=(1, 1, 0)))
    for y in range(6):
        s.addObject(m.Sphere(m.Point(-3 - y * 0.4, 2.3, -5), 0.4),
                    m.SimpleSurface(baseColour=(y / 6.0, 1 - y / 6.0, 0.5)))
    s.addObject(m.Halfspace(m.Point(0, 0, 0), m.Vector.UP), m.CheckerboardSurface())
    return s


def nearest(spheres, ray, eps):
    best = None
    for k, sp in enumerate(spheres):
        t = sp.intersectionTime(ray)
        if t is not None and t > -eps and (best is None or t < best[1]):
            best = (k, t)
    return best


def any_hit(spheres, ray, eps):
    for k, sp in enumerate(spheres):
        t = sp.intersectionTime(ray)
        if t is not None and t > eps:
            return (k, t)
    return None


def main():
    m = load_original()
    scene = build_scene(m)
    spheres = [o for o, _ in scene.objects if isinstance(o, m.Sphere)]
    eps = m.EPSILON

    # Camera setup copied from Scene.render() for a 100x100 canvas
    W = H = 100
    import math
    fov = math.pi * (scene.fieldOfView / 2.0) / 180.0
    half_w = math.tan(fov)
    half_h = 0.75 * half_w
    pix_w = (half_w * 2) / (W - 1)
    pix_h = (half_h * 2) / (H - 1)
    eye = m.Ray(scene.position, scene.lookingAt - scene.position)
    right = eye.vector.cross(m.Vector.UP).normalized()
    up = right.cross(eye.vector).normalized()

    tests = []
    step = max(1, W // GRID)
    for y in range(0, H, step):
        for x in range(0, W, step):
            ray = m.Ray(eye.point, eye.vector + right.scale(x * pix_w - half_w)
                        + up.scale(y * pix_h - half_h))
            res = nearest(spheres, ray, eps)
            tests.append((0, ray, res))
            if res is not None:
                p = ray.pointAtTime(res[1])
                for light in scene.lightPoints:
                    shadow = m.Ray(p, light - p)
                    tests.append((1, shadow, any_hit(spheres, shadow, eps)))

    with open(os.path.join(HERE, "ray_spheres.hex"), "w") as f:
        for sp in spheres:
            c = sp.centre
            for v in (c.x, c.y, c.z, sp.radius * sp.radius):
                f.write("%016x\n" % bits(v))
    with open(os.path.join(HERE, "ray_tests.hex"), "w") as f:
        for mode, ray, res in tests:
            words = [mode, bits(ray.point.x), bits(ray.point.y), bits(ray.point.z),
                     bits(ray.vector.x), bits(ray.vector.y), bits(ray.vector.z),
                     0 if res is None else 1,
                     0 if res is None else res[0],
                     0 if res is None else bits(res[1])]
            for w in words:
                f.write("%016x\n" % w)
    hits = sum(1 for _, _, r in tests if r is not None)
    print("wrote %d spheres, %d tests (%d hits)" % (len(spheres), len(tests), hits))
    with open(os.path.join(HERE, "ray_tests.count"), "w") as f:
        f.write("%d\n" % len(tests))


if __name__ == "__main__":
    main()
