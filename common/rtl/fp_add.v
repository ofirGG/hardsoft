`timescale 1ns/1ps
// IEEE-754 floating-point adder/subtractor (combinational).
// y = a + b when sub = 0, y = a - b when sub = 1.
// Default parameters give binary64 (double precision).
//
// Supported: normal numbers and zero, round-to-nearest-even, exact
// cancellation gives +0. Same simplifications as fp_mul: subnormals flush to
// zero, overflow saturates to infinity, NaN/Inf inputs are not special-cased.
module fp_add #(
    parameter EW = 11,
    parameter MW = 52
) (
    input  wire [EW+MW:0] a,
    input  wire [EW+MW:0] b,
    input  wire           sub,
    output reg  [EW+MW:0] y
);
    localparam W    = EW + MW + 1;
    localparam EMAX = (1 << EW) - 1;
    localparam XW   = MW + 4;         // hidden bit + fraction + guard/round/sticky

    wire [W-1:0] bb = {b[W-1] ^ sub, b[W-2:0]};

    // Order operands by magnitude: opbig >= opsml
    wire         swap  = (bb[W-2:0] > a[W-2:0]);
    wire [W-1:0] opbig = swap ? bb : a;
    wire [W-1:0] opsml = swap ? a  : bb;

    wire [EW-1:0] eb = opbig[W-2:MW];
    wire [EW-1:0] es = opsml[W-2:MW];
    wire [EW-1:0] ediff = eb - es;

    reg  [XW-1:0] mbig, msmall, shifted;
    reg  [XW:0]   sum;                // one extra bit for carry-out
    reg  [XW-1:0] norm;
    reg  signed [EW+1:0] exp;
    reg           sticky;
    reg  [MW+1:0] rounded;
    integer       lz, i;

    always @* begin
        mbig   = {1'b1, opbig[MW-1:0], 3'b000};
        msmall = {1'b1, opsml[MW-1:0], 3'b000};
        sticky = 1'b0;

        // Align the smaller operand, folding shifted-out bits into sticky
        if (ediff >= XW) begin
            shifted = {{(XW-1){1'b0}}, 1'b1};          // only sticky survives
        end else begin
            shifted = msmall >> ediff;
            for (i = 0; i < XW; i = i + 1)
                if (i < ediff && msmall[i]) sticky = 1'b1;
            shifted[0] = shifted[0] | sticky;
        end

        exp = $signed({2'b00, eb});
        if (opbig[W-1] == opsml[W-1])
            sum = {1'b0, mbig} + {1'b0, shifted};
        else
            sum = {1'b0, mbig} - {1'b0, shifted};

        // Normalize
        if (sum[XW]) begin                             // carry: shift right one
            norm = sum[XW:1];
            norm[0] = norm[0] | sum[0];
            exp = exp + 1;
        end else begin
            lz = XW;
            for (i = 0; i < XW; i = i + 1)
                if (sum[i]) lz = XW - 1 - i;           // last hit = highest set bit
            norm = sum[XW-1:0] << lz;
            exp  = exp - lz;
        end

        // Round to nearest even: L = norm[3], G = norm[2], R|S = norm[1:0]
        rounded = {1'b0, norm[XW-1:3]} + (norm[2] & (norm[3] | norm[1] | norm[0]));
        if (rounded[MW+1]) begin
            rounded = rounded >> 1;
            exp     = exp + 1;
        end

        if (a[W-2:MW] == 0)
            y = bb;                                    // 0 + b
        else if (b[W-2:MW] == 0)
            y = a;                                     // a + 0
        else if (sum == 0 || exp <= 0)
            y = {W{1'b0}};                             // exact cancellation / underflow
        else if (exp >= EMAX)
            y = {opbig[W-1], {EW{1'b1}}, {MW{1'b0}}};
        else
            y = {opbig[W-1], exp[EW-1:0], rounded[MW-1:0]};
    end
endmodule
