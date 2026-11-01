`timescale 1ns/1ps
// IEEE-754 "less than" comparator (combinational): lt = (a < b).
// Zeros of either sign compare equal; NaNs are not handled.
module fp_lt #(
    parameter W = 64
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    output reg          lt
);
    wire sa = a[W-1];
    wire sb = b[W-1];
    wire both_zero = (a[W-2:0] == 0) && (b[W-2:0] == 0);

    always @* begin
        if (both_zero)
            lt = 1'b0;
        else if (sa != sb)
            lt = sa;                              // negative < positive
        else if (!sa)
            lt = a[W-2:0] < b[W-2:0];             // both positive
        else
            lt = a[W-2:0] > b[W-2:0];             // both negative
    end
endmodule
