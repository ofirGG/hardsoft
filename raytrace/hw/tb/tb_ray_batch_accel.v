`timescale 1ns/1ps
// Self-checking testbench for ray_batch_accel.
// Plays the role of the DMA engines: loads the scene's spheres once through
// the configuration port, streams every golden ray in as one batch and checks
// the result stream against the original Python benchmark (vectors from
// gen_vectors.py). With STALL=1 both streams are throttled pseudo-randomly
// to exercise the valid/ready handshakes; with STALL=0 the measured cycles
// per ray are the batch throughput of one accelerator lane.
module tb_ray_batch_accel;
    parameter NTESTS = 1;              // overridden by run_sim.sh
    parameter STALL  = 0;
    localparam NS = 7, TW = 10;
    localparam real TOL = 1e-12;

    reg         clk = 0, rst = 1;
    reg         cfg_wr = 0;
    reg  [11:0] cfg_addr = 0;
    reg  [63:0] cfg_wdata = 0;
    reg         in_valid = 0;
    reg  [63:0] in_data = 0;
    wire        in_ready;
    wire        out_valid;
    reg         out_ready = 0;
    wire [63:0] out_data;

    ray_batch_accel dut (.clk(clk), .rst(rst),
        .cfg_wr(cfg_wr), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data));
    always #5 clk = ~clk;              // 100 MHz

    reg [63:0] spheres [0:NS*4-1];
    reg [63:0] tests   [0:NTESTS*TW-1];

    // Pseudo-random stall pattern (LFSR)
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    integer n, w, r, errors = 0, hits = 0, received = 0;
    integer t_first = -1, t_last = 0, cyc = 0;
    real rel, max_rel = 0.0;
    reg [63:0] word0;
    reg        streaming = 0;

    always @(posedge clk) cyc <= cyc + 1;

    // ----------------------------------------------------- input stream
    initial begin
        $readmemh("ray_spheres.hex", spheres);
        $readmemh("ray_tests.hex", tests);
        repeat (3) @(negedge clk);
        rst = 0;
        for (n = 0; n < NS * 4; n = n + 1) begin
            @(negedge clk) begin cfg_wr = 1; cfg_addr = 12'h100 + n; cfg_wdata = spheres[n]; end
        end
        @(negedge clk) begin cfg_addr = 12'h002; cfg_wdata = NS; end
        @(negedge clk) cfg_wr = 0;
        streaming = 1;

        for (n = 0; n < NTESTS; n = n + 1)
            for (w = 0; w < 7; w = w + 1) begin
                @(negedge clk);
                while (STALL && lfsr[0]) begin in_valid = 0; @(negedge clk); end
                in_valid = 1;
                in_data  = tests[n * TW + w];  // word 0 = mode, then px..dz
                // in_ready is stable at the falling edge; the word is taken
                // at the next rising edge
                while (!in_ready) @(negedge clk);
                if (t_first < 0) t_first = cyc;
            end
        @(negedge clk) in_valid = 0;
    end

    // ---------------------------------------------------- output stream
    always @(negedge clk)
        out_ready <= streaming && !(STALL && lfsr[3]);

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            if (received % 2 == 0)
                word0 = out_data;
            else begin
                r = received / 2;
                if (word0[0] !== tests[r * TW + 7][0]) begin
                    errors = errors + 1;
                    $display("ray %0d: hit got %0d expected %0d", r, word0[0], tests[r * TW + 7][0]);
                end else if (word0[0]) begin
                    hits = hits + 1;
                    rel = ($bitstoreal(out_data) - $bitstoreal(tests[r * TW + 9]))
                          / $bitstoreal(tests[r * TW + 9]);
                    if (rel < 0) rel = -rel;
                    if (rel > max_rel) max_rel = rel;
                    if (word0[15:8] !== tests[r * TW + 8][7:0] || rel > TOL) begin
                        errors = errors + 1;
                        $display("ray %0d: sphere %0d t=%.17g, expected sphere %0d t=%.17g", r,
                                 word0[15:8], $bitstoreal(out_data), tests[r * TW + 8][7:0],
                                 $bitstoreal(tests[r * TW + 9]));
                    end
                end
                if (r == NTESTS - 1) begin
                    t_last = cyc;
                    $display("batch of %0d rays (STALL=%0d), %0d hits", NTESTS, STALL, hits);
                    $display("first ray word in -> last result out: %0d cycles, %0d.%02d cycles/ray",
                             t_last - t_first, (t_last - t_first) / NTESTS,
                             ((t_last - t_first) * 100 / NTESTS) % 100);
                    $display("max relative error of t vs Python original = %e", max_rel);
                    if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
                    $finish;
                end
            end
            received = received + 1;
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL (timeout after %0d results)", received / 2);
        $finish;
    end
endmodule
