"""
N-body benchmark from the Computer Language Benchmarks Game - optimized version.

Same physics, same floating-point operation order and same pyperf interface as
original.py, so the simulation results are bit-identical.

Optimizations (see report_nbody.txt for the profiling data behind them):
1. Scalar replacement ("register promotion"): during advance() every
   coordinate, velocity and mass lives in a local variable instead of a
   list slot. LOAD_FAST/STORE_FAST replace BINARY_SUBSCR/STORE_SUBSCR and the
   per-pair tuple/list unpacking disappears.
2. Full unrolling of the pair loop: the 10 body pairs are known when the
   module loads, so advance() is generated once with straight-line code for
   every pair. This removes the inner for-loop and its iterator overhead.
3. State is read from the shared body lists once on entry and written back
   once on exit, so the observable behaviour of advance() is unchanged.
"""

import pyperf

__contact__ = "collinwinter@google.com (Collin Winter)"
DEFAULT_ITERATIONS = 20000
DEFAULT_REFERENCE = 'sun'


def combinations(l):
    """Pure-Python implementation of itertools.combinations(l, 2)."""
    result = []
    for x in range(len(l) - 1):
        ls = l[x + 1:]
        for y in ls:
            result.append((l[x], y))
    return result


PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

BODIES = {
    'sun': ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS),

    'jupiter': ([4.84143144246472090e+00,
                 -1.16032004402742839e+00,
                 -1.03622044471123109e-01],
                [1.66007664274403694e-03 * DAYS_PER_YEAR,
                 7.69901118419740425e-03 * DAYS_PER_YEAR,
                 -6.90460016972063023e-05 * DAYS_PER_YEAR],
                9.54791938424326609e-04 * SOLAR_MASS),

    'saturn': ([8.34336671824457987e+00,
                4.12479856412430479e+00,
                -4.03523417114321381e-01],
               [-2.76742510726862411e-03 * DAYS_PER_YEAR,
                4.99852801234917238e-03 * DAYS_PER_YEAR,
                2.30417297573763929e-05 * DAYS_PER_YEAR],
               2.85885980666130812e-04 * SOLAR_MASS),

    'uranus': ([1.28943695621391310e+01,
                -1.51111514016986312e+01,
                -2.23307578892655734e-01],
               [2.96460137564761618e-03 * DAYS_PER_YEAR,
                2.37847173959480950e-03 * DAYS_PER_YEAR,
                -2.96589568540237556e-05 * DAYS_PER_YEAR],
               4.36624404335156298e-05 * SOLAR_MASS),

    'neptune': ([1.53796971148509165e+01,
                 -2.59193146099879641e+01,
                 1.79258772950371181e-01],
                [2.68067772490389322e-03 * DAYS_PER_YEAR,
                 1.62824170038242295e-03 * DAYS_PER_YEAR,
                 -9.51592254519715870e-05 * DAYS_PER_YEAR],
                5.15138902046611451e-05 * SOLAR_MASS)}


SYSTEM = list(BODIES.values())
PAIRS = combinations(SYSTEM)


def _generate_advance(nbodies):
    """Build the source of a fully unrolled advance() for `nbodies` bodies.

    The arithmetic of each pair is written exactly as in the original loop
    body and the pairs appear in the same order as combinations(), so the
    float results match the original bit for bit.
    """
    idx = range(nbodies)
    pairs = [(i, j) for i in idx for j in idx if i < j]
    src = ["def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):"]
    for i in idx:
        src.append(f"    r{i}, v{i}, m{i} = bodies[{i}]")
        src.append(f"    x{i}, y{i}, z{i} = r{i}")
        src.append(f"    vx{i}, vy{i}, vz{i} = v{i}")
    src.append("    for _ in range(n):")
    for i, j in pairs:
        src += [
            f"        dx = x{i} - x{j}",
            f"        dy = y{i} - y{j}",
            f"        dz = z{i} - z{j}",
            "        mag = dt * ((dx * dx + dy * dy + dz * dz) ** (-1.5))",
            f"        b1m = m{i} * mag",
            f"        b2m = m{j} * mag",
            f"        vx{i} -= dx * b2m",
            f"        vy{i} -= dy * b2m",
            f"        vz{i} -= dz * b2m",
            f"        vx{j} += dx * b1m",
            f"        vy{j} += dy * b1m",
            f"        vz{j} += dz * b1m",
        ]
    for i in idx:
        src += [
            f"        x{i} += dt * vx{i}",
            f"        y{i} += dt * vy{i}",
            f"        z{i} += dt * vz{i}",
        ]
    for i in idx:
        src.append(f"    r{i}[:] = (x{i}, y{i}, z{i})")
        src.append(f"    v{i}[:] = (vx{i}, vy{i}, vz{i})")
    return "\n".join(src) + "\n"


_namespace = {"SYSTEM": SYSTEM, "PAIRS": PAIRS}
exec(compile(_generate_advance(len(SYSTEM)), "<nbody-advance>", "exec"), _namespace)
advance = _namespace["advance"]


def report_energy(bodies=SYSTEM, pairs=PAIRS, e=0.0):
    for (((x1, y1, z1), v1, m1),
         ((x2, y2, z2), v2, m2)) in pairs:
        dx = x1 - x2
        dy = y1 - y2
        dz = z1 - z2
        e -= (m1 * m2) / ((dx * dx + dy * dy + dz * dz) ** 0.5)
    for (r, [vx, vy, vz], m) in bodies:
        e += m * (vx * vx + vy * vy + vz * vz) / 2.
    return e


def offset_momentum(ref, bodies=SYSTEM, px=0.0, py=0.0, pz=0.0):
    for (r, [vx, vy, vz], m) in bodies:
        px -= vx * m
        py -= vy * m
        pz -= vz * m
    (r, v, m) = ref
    v[0] = px / m
    v[1] = py / m
    v[2] = pz / m


def bench_nbody(loops, reference, iterations):
    # Set up global state
    offset_momentum(BODIES[reference])

    range_it = range(loops)
    t0 = pyperf.perf_counter()

    for _ in range_it:
        report_energy()
        advance(0.01, iterations)
        report_energy()

    return pyperf.perf_counter() - t0


def add_cmdline_args(cmd, args):
    cmd.extend(("--iterations", str(args.iterations)))


if __name__ == '__main__':
    runner = pyperf.Runner(add_cmdline_args=add_cmdline_args)
    runner.metadata['description'] = "n-body benchmark"
    runner.argparser.add_argument("--iterations",
                                  type=int, default=DEFAULT_ITERATIONS,
                                  help="Number of nbody advance() iterations "
                                       "(default: %s)" % DEFAULT_ITERATIONS)
    runner.argparser.add_argument("--reference",
                                  type=str, default=DEFAULT_REFERENCE,
                                  help="nbody reference (default: %s)"
                                       % DEFAULT_REFERENCE)

    args = runner.parse_args()
    runner.bench_time_func('nbody', bench_nbody,
                           args.reference, args.iterations)
