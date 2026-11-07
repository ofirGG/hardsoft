"""Collect the Yosys statistics written by run_synth.sh into one table."""
import os
import re
import sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")

# NAND2-equivalent weights of the generic cells (typical standard-cell ratios)
NAND2_EQ = {"NAND": 1.0, "NOR": 1.0, "NOT": 0.67, "AND": 1.33, "OR": 1.33,
            "XOR": 2.33, "XNOR": 2.33, "MUX": 2.33, "DFF": 4.5}


def cells(text):
    """{cell type: count} from a Yosys `stat` report."""
    return {name: int(n) for name, n in
            re.findall(r"^\s+(\S+)\s+(\d+)\s*$", text, re.M)
            if not name.startswith("Number")}


def main(tops):
    fmt = "%-17s %7s %6s %7s %6s %5s %9s %9s %9s"
    print(fmt % ("top", "LUT", "FF", "carry", "LUTRAM", "BRAM",
                 "gates", "FF bits", "kNAND2eq"))
    for top in tops:
        x = cells(open(os.path.join(OUT, top + "_xc7.txt")).read())
        g = cells(open(os.path.join(OUT, top + "_gates.txt")).read())
        luts = sum(n for c, n in x.items() if re.fullmatch(r"LUT\d", c))
        ffs = sum(n for c, n in x.items() if re.fullmatch(r"FD[RSCP]E(_1)?", c))
        carry = sum(n for c, n in x.items() if c in ("MUXCY", "XORCY", "CARRY4"))
        bram = sum(n for c, n in x.items() if c.startswith("RAMB"))
        lutram = sum(n for c, n in x.items() if c.startswith("RAM") and not c.startswith("RAMB"))
        nand2 = 0.0
        gates = flops = 0
        for c, n in g.items():
            kind = re.sub(r"^\$_|_.*$", "", c)       # $_NAND_ -> NAND, $_DFFE_PP_ -> DFFE
            if "DFF" in kind or "DLATCH" in kind:
                flops += n
                nand2 += n * NAND2_EQ["DFF"]
            elif kind in NAND2_EQ:
                gates += n
                nand2 += n * NAND2_EQ[kind]
        print(fmt % (top, luts, ffs, carry, lutram, bram, gates, flops,
                     "%.1f" % (nand2 / 1000)))
    print("\nxc7  : Xilinx 7-series cells, Yosys 0.9 synth_xilinx without DSP48 "
          "inference\n       (multipliers in LUTs + carry chains: LUT counts are "
          "an upper bound)")
    print("gates: 2-input gates + MUX2 (combinational) and flip-flop bits; "
          "kNAND2eq = thousands\n       of NAND2 equivalents "
          "(NAND/NOR 1, AND/OR 1.33, XOR/XNOR/MUX 2.33, FF 4.5)")


if __name__ == "__main__":
    main(sys.argv[1:])
