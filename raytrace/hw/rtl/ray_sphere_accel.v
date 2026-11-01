`timescale 1ns/1ps
// Ray-sphere intersection accelerator (binary64).
//
// Tests one ray against a table of up to MAXS spheres and returns either the
// nearest hit (primary / reflected rays) or whether any sphere blocks the ray
// (shadow rays), replacing the scene loop around Sphere.intersectionTime().
// Spheres are written once per scene; each query then only sends the ray.
//
// Per sphere, with c = centre, p = ray origin, d = ray direction (unit):
//   cp = c - p ; v = cp.d ; disc = r^2 - (cp.cp - v*v)
//   miss if disc < 0, else t = v - sqrt(disc)   (sqrt(x) = x * rsqrt(x))
// Hit acceptance matches the Python code:
//   nearest mode: t > TMIN, strictly smaller t wins (first sphere on ties)
//   any-hit mode: first sphere with t > TMIN ends the search
//
// Host interface: 64-bit memory-mapped registers (word addresses):
//   0x000 CTRL     W  bit0 = start, bit1 = mode (0 nearest, 1 any-hit)
//   0x001 STATUS   R  bit0 = busy, bit1 = done
//   0x002 NSPHERES RW number of valid table entries
//   0x003 TMIN     RW hit threshold (binary64): -EPSILON or +EPSILON
//   0x004..0x009   RW ray px, py, pz, dx, dy, dz (binary64)
//   0x00A RESULT   R  bit0 = hit, bits[15:8] = sphere index
//   0x00B RESULT_T R  hit distance t (binary64)
//   0x00C CYCLES   R  clock cycles of the last query
//   0x100 + 4*k + f  sphere k field f: 0..2 = centre x,y,z  3 = radius^2
module ray_sphere_accel #(
    parameter MAXS = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire        rd_en,
    input  wire [11:0] addr,
    input  wire [63:0] wdata,
    output reg  [63:0] rdata,
    output wire        irq
);
    reg [63:0] scx [0:MAXS-1], scy [0:MAXS-1], scz [0:MAXS-1], sr2 [0:MAXS-1];
    reg [63:0] nspheres, tmin, px, py, pz, dx, dy, dz, cycles;
    reg        mode, busy, done;
    reg        hit;
    reg [7:0]  hit_idx;
    reg [63:0] hit_t;
    assign irq = done;

    localparam PH_IDLE = 2'd0, PH_TEST = 2'd1, PH_RSQ = 2'd2;
    reg [1:0]  phase;
    reg [3:0]  uop;
    reg [7:0]  k;                     // current sphere

    reg [63:0] cx, cy, cz, v, t0, t1, t2, disc, t;

    reg  [63:0] ma, mb, aa, ab;
    reg         asub;
    wire [63:0] mp, ay;
    fp_mul u_mul (.a(ma), .b(mb), .y(mp));
    fp_add u_add (.a(aa), .b(ab), .sub(asub), .y(ay));

    reg         rs_start;
    wire        rs_done;
    wire [63:0] rs_y;
    fp_rsqrt u_rsqrt (.clk(clk), .rst(rst), .start(rs_start), .x(disc),
                      .done(rs_done), .y(rs_y));

    wire above_tmin, closer;
    fp_lt u_lt_tmin (.a(tmin), .b(t), .lt(above_tmin));       // t > TMIN
    fp_lt u_lt_best (.a(t), .b(hit_t), .lt(closer));          // t < best

    wire disc_neg = disc[63] && (disc[62:0] != 0);

    always @* begin
        ma = 64'd0; mb = 64'd0; aa = 64'd0; ab = 64'd0; asub = 1'b0;
        if (phase == PH_TEST) begin
            case (uop)
                0:  begin aa = scx[k]; ab = px; asub = 1; end
                1:  begin aa = scy[k]; ab = py; asub = 1; ma = cx; mb = dx; end
                2:  begin aa = scz[k]; ab = pz; asub = 1; ma = cy; mb = dy; end
                3:  begin aa = t0; ab = t1; ma = cz; mb = dz; end   // cx*dx + cy*dy
                4:  begin aa = v;  ab = t0; ma = cx; mb = cx; end   // v += cz*dz
                5:  begin ma = cy; mb = cy; end
                6:  begin aa = t1; ab = t0; ma = cz; mb = cz; end
                7:  begin aa = t1; ab = t0; ma = v;  mb = v;  end   // cp.cp, v*v
                8:  begin aa = t1; ab = t2; asub = 1; end           // cp.cp - v*v
                9:  begin aa = sr2[k]; ab = t1; asub = 1; end       // disc
                11: begin ma = disc; mb = t0; end                   // sqrt(disc)
                12: begin aa = v; ab = t1; asub = 1; end             // t = v - sqrt
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rd_en) begin
            if (addr[11:8] == 4'h1) begin
                case (addr[1:0])
                    2'd0: rdata <= scx[addr[7:2]];
                    2'd1: rdata <= scy[addr[7:2]];
                    2'd2: rdata <= scz[addr[7:2]];
                    2'd3: rdata <= sr2[addr[7:2]];
                endcase
            end else begin
                case (addr)
                    12'h001: rdata <= {62'd0, done, busy};
                    12'h002: rdata <= nspheres;
                    12'h003: rdata <= tmin;
                    12'h004: rdata <= px;
                    12'h005: rdata <= py;
                    12'h006: rdata <= pz;
                    12'h007: rdata <= dx;
                    12'h008: rdata <= dy;
                    12'h009: rdata <= dz;
                    12'h00A: rdata <= {48'd0, hit_idx, 7'd0, hit};
                    12'h00B: rdata <= hit_t;
                    12'h00C: rdata <= cycles;
                    default: rdata <= 64'd0;
                endcase
            end
        end
    end

    // Advance to the next sphere or finish the query
    task next_sphere;
        begin
            uop <= 0;
            if (k == nspheres - 1) begin
                busy  <= 1'b0;
                done  <= 1'b1;
                phase <= PH_IDLE;
            end else
                k <= k + 1;
        end
    endtask

    always @(posedge clk) begin
        rs_start <= 1'b0;
        if (rst) begin
            phase <= PH_IDLE;
            busy <= 1'b0; done <= 1'b0; hit <= 1'b0;
            nspheres <= 0; cycles <= 0;
        end else begin
            if (busy) cycles <= cycles + 1;
            case (phase)
            PH_IDLE: if (wr_en) begin
                if (addr[11:8] == 4'h1) begin
                    case (addr[1:0])
                        2'd0: scx[addr[7:2]] <= wdata;
                        2'd1: scy[addr[7:2]] <= wdata;
                        2'd2: scz[addr[7:2]] <= wdata;
                        2'd3: sr2[addr[7:2]] <= wdata;
                    endcase
                end else begin
                    case (addr)
                        12'h000: if (wdata[0]) begin
                            mode    <= wdata[1];
                            hit     <= 1'b0;
                            hit_idx <= 8'd0;
                            hit_t   <= 64'd0;
                            cycles  <= 0;
                            k       <= 0;
                            uop     <= 0;
                            done    <= 1'b0;
                            if (nspheres == 0) done <= 1'b1;
                            else begin busy <= 1'b1; phase <= PH_TEST; end
                        end
                        12'h002: nspheres <= wdata;
                        12'h003: tmin <= wdata;
                        12'h004: px <= wdata;
                        12'h005: py <= wdata;
                        12'h006: pz <= wdata;
                        12'h007: dx <= wdata;
                        12'h008: dy <= wdata;
                        12'h009: dz <= wdata;
                        default: ;
                    endcase
                end
            end

            PH_TEST: begin
                uop <= uop + 1;
                case (uop)
                    0:  cx <= ay;
                    1:  begin cy <= ay; t0 <= mp; end
                    2:  begin cz <= ay; t1 <= mp; end
                    3:  begin v  <= ay; t0 <= mp; end
                    4:  begin v  <= ay; t1 <= mp; end
                    5:  t0 <= mp;
                    6:  begin t1 <= ay; t0 <= mp; end
                    7:  begin t1 <= ay; t2 <= mp; end
                    8:  t1 <= ay;
                    9:  disc <= ay;
                    10: if (disc_neg)
                            next_sphere;              // ray misses this sphere
                        else begin
                            rs_start <= 1'b1;
                            phase    <= PH_RSQ;
                        end
                    11: t1 <= mp;
                    12: t  <= ay;
                    13: begin
                        if (above_tmin && (mode || !hit || closer)) begin
                            hit     <= 1'b1;
                            hit_idx <= k;
                            hit_t   <= t;
                        end
                        if (mode && above_tmin) begin  // any-hit: stop early
                            uop   <= 0;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            phase <= PH_IDLE;
                        end else
                            next_sphere;
                    end
                    default: ;
                endcase
            end

            PH_RSQ: if (rs_done) begin
                t0    <= rs_y;
                uop   <= 11;
                phase <= PH_TEST;
            end
            default: phase <= PH_IDLE;
            endcase
        end
    end
endmodule
