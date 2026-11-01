`timescale 1ns/1ps
// Self-checking testbench for ray_sphere_accel.
// Acts as the host driver: loads the scene's spheres once, then for every
// golden test writes the ray, sets the mode and threshold, starts the query,
// waits for done and checks hit / sphere index / t against the original
// Python benchmark (vectors from gen_vectors.py).
module tb_ray_sphere_accel;
    parameter NTESTS = 1;              // overridden by run_sim.sh
    localparam NS = 7, TW = 10;
    localparam real EPSILON = 0.00001;
    localparam real TOL = 1e-12;

    reg         clk = 0, rst = 1;
    reg         wr_en = 0, rd_en = 0;
    reg  [11:0] addr = 0;
    reg  [63:0] wdata = 0;
    wire [63:0] rdata;
    wire        irq;

    ray_sphere_accel dut (.clk(clk), .rst(rst), .wr_en(wr_en), .rd_en(rd_en),
                          .addr(addr), .wdata(wdata), .rdata(rdata), .irq(irq));
    always #5 clk = ~clk;              // 100 MHz

    reg [63:0] spheres [0:NS*4-1];
    reg [63:0] tests   [0:NTESTS*TW-1];

    task mmio_write(input [11:0] a, input [63:0] d);
        begin
            @(negedge clk) begin wr_en = 1; addr = a; wdata = d; end
            @(negedge clk) wr_en = 0;
        end
    endtask

    task mmio_read(input [11:0] a, output [63:0] d);
        begin
            @(negedge clk) begin rd_en = 1; addr = a; end
            @(negedge clk) begin rd_en = 0; d = rdata; end
        end
    endtask

    integer n, f, errors = 0, hits = 0;
    reg  [63:0] res, t_got, cyc;
    reg  [63:0] base;
    real rel, max_rel = 0.0;
    integer total_cycles [0:1];
    integer queries [0:1];

    initial begin
        $readmemh("ray_spheres.hex", spheres);
        $readmemh("ray_tests.hex", tests);
        total_cycles[0] = 0; total_cycles[1] = 0; queries[0] = 0; queries[1] = 0;
        repeat (3) @(negedge clk);
        rst = 0;

        for (n = 0; n < NS * 4; n = n + 1)
            mmio_write(12'h100 + n, spheres[n]);
        mmio_write(12'h002, NS);

        for (n = 0; n < NTESTS; n = n + 1) begin
            base = n * TW;
            for (f = 0; f < 6; f = f + 1)
                mmio_write(12'h004 + f, tests[base + 1 + f]);
            mmio_write(12'h003, $realtobits(tests[base][0] ? EPSILON : -EPSILON));
            mmio_write(12'h000, {62'd0, tests[base][0], 1'b1});
            wait (irq);
            mmio_read(12'h00A, res);
            mmio_read(12'h00B, t_got);
            mmio_read(12'h00C, cyc);
            total_cycles[tests[base][0]] = total_cycles[tests[base][0]] + cyc;
            queries[tests[base][0]] = queries[tests[base][0]] + 1;

            if (res[0] !== tests[base + 7][0]) begin
                errors = errors + 1;
                $display("test %0d: hit got %0d expected %0d", n, res[0], tests[base + 7][0]);
            end else if (res[0]) begin
                hits = hits + 1;
                rel = ($bitstoreal(t_got) - $bitstoreal(tests[base + 9]))
                      / $bitstoreal(tests[base + 9]);
                if (rel < 0) rel = -rel;
                if (rel > max_rel) max_rel = rel;
                if (res[15:8] !== tests[base + 8][7:0] || rel > TOL) begin
                    errors = errors + 1;
                    $display("test %0d: sphere %0d t=%.17g, expected sphere %0d t=%.17g", n,
                             res[15:8], $bitstoreal(t_got), tests[base + 8][7:0],
                             $bitstoreal(tests[base + 9]));
                end
            end
        end

        $display("%0d queries (%0d nearest-hit, %0d any-hit), %0d hits", NTESTS,
                 queries[0], queries[1], hits);
        $display("avg cycles/query: nearest-hit %0d, any-hit %0d",
                 total_cycles[0] / (queries[0] ? queries[0] : 1),
                 total_cycles[1] / (queries[1] ? queries[1] : 1));
        $display("max relative error of t vs Python original = %e", max_rel);
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
