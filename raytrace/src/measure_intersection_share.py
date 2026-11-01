"""Measure how much of the optimized render time the ray-sphere search takes.

This is the fraction the ray_sphere_accel hardware would replace (Amdahl's f).
1. Render one frame with optimized.py while recording every scene query
   (nearest-hit queries from rayColour, any-hit queries from _lightIsVisible).
2. Time a normal render.
3. Replay only the recorded queries through the same Python search loops,
   once over spheres only (offloadable) and once over the ground plane only
   (stays in software).
"""
import importlib.util
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("opt", os.path.join(HERE, "optimized.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
EPS = m.EPSILON


def build_scene():
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


def render_time(repeat=5):
    best = None
    for _ in range(repeat):
        scene, canvas = build_scene(), m.Canvas(100, 100)
        t = time.perf_counter()
        scene.render(canvas)
        t = time.perf_counter() - t
        best = t if best is None else min(best, t)
    return best


def record_queries():
    queries = []
    orig_colour, orig_visible = m.Scene.rayColour, m.Scene._lightIsVisible

    def rayColour(self, ray):
        if self.recursionDepth <= 3:
            queries.append((0, ray))
        return orig_colour(self, ray)

    def _lightIsVisible(self, l, p):
        queries.append((1, m.Ray(p, m.Vector(l.x - p.x, l.y - p.y, l.z - p.z))))
        return orig_visible(self, l, p)

    m.Scene.rayColour, m.Scene._lightIsVisible = rayColour, _lightIsVisible
    scene = build_scene()
    scene.render(m.Canvas(100, 100))
    m.Scene.rayColour, m.Scene._lightIsVisible = orig_colour, orig_visible
    return scene, queries


def replay(objects, queries, repeat=5):
    best = None
    for _ in range(repeat):
        t = time.perf_counter()
        for kind, ray in queries:
            if kind == 0:                       # nearest hit (rayColour loop)
                hit, hitT = None, None
                for (o, s) in objects:
                    tt = o.intersectionTime(ray)
                    if tt is not None and tt > -EPS:
                        if hit is None or tt < hitT:
                            hit, hitT = (o, s), tt
            else:                               # any hit (_lightIsVisible loop)
                for (o, s) in objects:
                    tt = o.intersectionTime(ray)
                    if tt is not None and tt > EPS:
                        break
        t = time.perf_counter() - t
        best = t if best is None else min(best, t)
    return best


def main():
    scene, queries = record_queries()
    spheres = [(o, s) for o, s in scene.objects if isinstance(o, m.Sphere)]
    planes = [(o, s) for o, s in scene.objects if not isinstance(o, m.Sphere)]
    total = render_time()
    t_spheres = replay(spheres, queries)
    t_planes = replay(planes, queries)
    n_near = sum(1 for k, _ in queries if k == 0)
    print("queries per frame        : %d (%d nearest-hit, %d any-hit)"
          % (len(queries), n_near, len(queries) - n_near))
    print("render time (best of 5)  : %.1f ms" % (total * 1e3))
    print("sphere search (offload)  : %.1f ms = %.1f %% of render, %.2f us/query"
          % (t_spheres * 1e3, 100 * t_spheres / total, 1e6 * t_spheres / len(queries)))
    print("plane test (stays in SW) : %.1f ms = %.1f %% of render"
          % (t_planes * 1e3, 100 * t_planes / total))


if __name__ == "__main__":
    main()
