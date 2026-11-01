// Self-checking testbench for the FP library.
// fp_add / fp_mul are compared bit-for-bit against the simulator's IEEE-754
// double arithmetic (Verilog `real`), fp_rsqrt against 1.0/$sqrt(x) with a
// relative-error bound.
`timescale 1ns/1ps
module tb_fp;
    localparam N = 20000;

    reg  [63:0] a, b;
    reg         sub;
    wire [63:0] add_y, mul_y;
    wire        lt;
    fp_add u_add (.a(a), .b(b), .sub(sub), .y(add_y));
    fp_mul u_mul (.a(a), .b(b), .y(mul_y));
    fp_lt  u_lt  (.a(a), .b(b), .lt(lt));

    reg clk = 0, rst = 1, start = 0;
    wire rs_done;
    wire [63:0] rs_y;
    fp_rsqrt u_rs (.clk(clk), .rst(rst), .start(start), .x(a), .done(rs_done), .y(rs_y));
    always #5 clk = ~clk;

    integer i, add_err = 0, mul_err = 0, lt_err = 0, rs_err = 0;
    real ra, rb, refv, got, rel, max_rel = 0.0;
    reg [63:0] e;

    // Random finite double with exponent in [BIAS-40, BIAS+40]
    function [63:0] rnd;
        input integer spread;
        reg [10:0] ex;
        begin
            ex  = 11'd1023 + ($random % spread);
            rnd = {$random, $random};
            rnd[62:52] = ex;
        end
    endfunction

    initial begin
        for (i = 0; i < N; i = i + 1) begin
            a = rnd(40);
            // Mix of near and far operands, plus exact-cancellation cases
            case (i % 4)
                0: b = rnd(40);
                1: b = rnd(3);
                2: begin b = a; b[3:0] = $random; end
                3: b = a;
            endcase
            sub = $random;
            #1;
            ra = $bitstoreal(a);
            rb = $bitstoreal(b);

            e = $realtobits(sub ? ra - rb : ra + rb);
            if (e[62:0] == 0) e = 64'd0;              // RTL returns +0 on cancellation
            if (add_y !== e) begin
                add_err = add_err + 1;
                if (add_err < 5) $display("ADD mismatch %h %s %h: got %h exp %h",
                                          a, sub ? "-" : "+", b, add_y, e);
            end
            e = $realtobits(ra * rb);
            if (mul_y !== e) begin
                mul_err = mul_err + 1;
                if (mul_err < 5) $display("MUL mismatch %h * %h: got %h exp %h", a, b, mul_y, e);
            end
            if (lt !== (ra < rb)) lt_err = lt_err + 1;
        end
        $display("fp_add: %0d / %0d mismatches (bit-exact vs IEEE double)", add_err, N);
        $display("fp_mul: %0d / %0d mismatches (bit-exact vs IEEE double)", mul_err, N);
        $display("fp_lt : %0d / %0d mismatches", lt_err, N);

        // rsqrt: positive inputs over a wide range
        @(posedge clk) rst <= 0;
        for (i = 0; i < 2000; i = i + 1) begin
            a = rnd(200);
            a[63] = 1'b0;
            @(posedge clk) start <= 1;
            @(posedge clk) start <= 0;
            @(posedge rs_done); #1;
            refv = 1.0 / $sqrt($bitstoreal(a));
            got = $bitstoreal(rs_y);
            rel = (got - refv) / refv;
            if (rel < 0) rel = -rel;
            if (rel > max_rel) max_rel = rel;
            if (rel > 1e-15) rs_err = rs_err + 1;
        end
        $display("fp_rsqrt: %0d / 2000 above 1e-15 relative error, max rel err = %e",
                 rs_err, max_rel);

        if (add_err == 0 && mul_err == 0 && lt_err == 0 && rs_err == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
