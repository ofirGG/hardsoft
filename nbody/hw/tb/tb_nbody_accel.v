`timescale 1ns/1ps
// Self-checking testbench for nbody_accel.
// Acts as the host driver: loads the 5-body system through the MMIO
// registers, starts STEPS time steps, waits for the done interrupt, reads the
// bodies back and compares them with the original Python benchmark
// (nbody_vectors.hex from gen_vectors.py).
module tb_nbody_accel;
    parameter STEPS = 200;
    localparam NB = 5, NF = 7;
    localparam real TOL = 1e-12;       // max relative error accepted

    reg         clk = 0, rst = 1;
    reg         wr_en = 0, rd_en = 0;
    reg  [11:0] addr = 0;
    reg  [63:0] wdata = 0;
    wire [63:0] rdata;
    wire        irq;

    nbody_accel dut (.clk(clk), .rst(rst), .wr_en(wr_en), .rd_en(rd_en),
                     .addr(addr), .wdata(wdata), .rdata(rdata), .irq(irq));
    always #5 clk = ~clk;              // 100 MHz

    reg [63:0] vec [0:2*NB*NF-1];

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

    integer b, f, errors = 0;
    reg  [63:0] got, cyc;
    real g, e, rel, max_rel = 0.0;

    initial begin
        $readmemh("nbody_vectors.hex", vec);
        repeat (3) @(negedge clk);
        rst = 0;

        for (b = 0; b < NB; b = b + 1)
            for (f = 0; f < NF; f = f + 1)
                mmio_write(12'h100 + 8*b + f, vec[b*NF + f]);
        mmio_write(12'h002, NB);
        mmio_write(12'h003, STEPS);
        mmio_write(12'h004, $realtobits(0.01));
        mmio_write(12'h000, 64'd1);                    // start

        wait (irq);
        mmio_read(12'h005, cyc);

        for (b = 0; b < NB; b = b + 1)
            for (f = 0; f < NF; f = f + 1) begin
                mmio_read(12'h100 + 8*b + f, got);
                g = $bitstoreal(got);
                e = $bitstoreal(vec[NB*NF + b*NF + f]);
                rel = (e == 0.0) ? g : (g - e) / e;
                if (rel < 0) rel = -rel;
                if (rel > max_rel) max_rel = rel;
                if (rel > TOL) begin
                    errors = errors + 1;
                    $display("body %0d field %0d: got %.17g expected %.17g", b, f, g, e);
                end
            end

        $display("steps = %0d, cycles = %0d, cycles/step = %0d", STEPS, cyc, cyc / STEPS);
        $display("max relative error vs Python original = %e", max_rel);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
