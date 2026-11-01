`timescale 1ns/1ps
// IEEE-754 floating-point multiplier (combinational).
// Default parameters give binary64 (double precision).
//
// Supported: normal numbers and zero, round-to-nearest-even.
// Simplifications (documented in the reports): subnormal inputs/results are
// flushed to zero, overflow saturates to infinity, NaN/Inf inputs are not
// special-cased (the accelerated workloads never produce them).
module fp_mul #(
    parameter EW = 11,              // exponent width
    parameter MW = 52               // fraction (mantissa) width
) (
    input  wire [EW+MW:0] a,
    input  wire [EW+MW:0] b,
    output reg  [EW+MW:0] y
);
    localparam W    = EW + MW + 1;
    localparam BIAS = (1 << (EW - 1)) - 1;
    localparam EMAX = (1 << EW) - 1;

    wire          sa = a[W-1];
    wire          sb = b[W-1];
    wire [EW-1:0] ea = a[W-2:MW];
    wire [EW-1:0] eb = b[W-2:MW];
    wire [MW:0]   ma = {1'b1, a[MW-1:0]};
    wire [MW:0]   mb = {1'b1, b[MW-1:0]};

    wire [2*MW+1:0] prod = ma * mb;   // in [1, 4) with 2*MW fraction bits

    reg  [MW:0]   keep;               // 1.f result before rounding
    reg           guard, sticky;
    reg  [MW+1:0] rounded;
    reg  signed [EW+1:0] exp;         // signed, wide enough for over/underflow

    always @* begin
        exp = $signed({2'b00, ea}) + $signed({2'b00, eb}) - BIAS;
        if (prod[2*MW+1]) begin       // product in [2, 4): shift right by one
            keep   = prod[2*MW+1:MW+1];
            guard  = prod[MW];
            sticky = |prod[MW-1:0];
            exp    = exp + 1;
        end else begin
            keep   = prod[2*MW:MW];
            guard  = prod[MW-1];
            sticky = |prod[MW-2:0];
        end

        rounded = {1'b0, keep} + (guard & (sticky | keep[0]));
        if (rounded[MW+1]) begin      // rounding carried into a new MSB
            rounded = rounded >> 1;
            exp     = exp + 1;
        end

        if (ea == 0 || eb == 0 || exp <= 0)
            y = {sa ^ sb, {(W-1){1'b0}}};                 // zero / flushed underflow
        else if (exp >= EMAX)
            y = {sa ^ sb, {EW{1'b1}}, {MW{1'b0}}};        // overflow -> infinity
        else
            y = {sa ^ sb, exp[EW-1:0], rounded[MW-1:0]};
    end
endmodule
