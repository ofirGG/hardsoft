`timescale 1ns/1ps
// N-body integration accelerator (binary64).
//
// Runs NSTEPS iterations of the benchmark's advance() entirely in hardware:
// for every pair (i, j) it computes the gravitational velocity update, then
// moves every body by dt * v. Body state lives in on-chip registers, so the
// host only transfers the system once before and once after the whole run.
//
// Datapath: one fp_add, one fp_mul (both single-cycle) and one multi-cycle
// fp_rsqrt. A control FSM issues at most one add and one mul per cycle, with
// the same operation order as the Python code (see report_nbody.txt).
//
// Host interface: 64-bit memory-mapped registers (word addresses):
//   0x000 CTRL     W  bit0 = start
//   0x001 STATUS   R  bit0 = busy, bit1 = done (sticky until next start)
//   0x002 NBODIES  RW number of bodies (2..MAXB)
//   0x003 NSTEPS   RW number of time steps
//   0x004 DT       RW time step (binary64)
//   0x005 CYCLES   R  clock cycles taken by the last run
//   0x100 + 8*i + k  body i field k: 0..2 = x,y,z  3..5 = vx,vy,vz  6 = mass
module nbody_accel #(
    parameter MAXB = 8
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire        rd_en,
    input  wire [11:0] addr,
    input  wire [63:0] wdata,
    output reg  [63:0] rdata,
    output wire        irq            // level: high while done
);
    // ---------------- architectural state ----------------
    reg [63:0] bx [0:MAXB-1], by [0:MAXB-1], bz [0:MAXB-1];
    reg [63:0] bvx[0:MAXB-1], bvy[0:MAXB-1], bvz[0:MAXB-1];
    reg [63:0] bm [0:MAXB-1];
    reg [63:0] nbodies, nsteps, dt, cycles;
    reg        busy, done;
    assign irq = done;

    // ---------------- control ----------------
    localparam PH_IDLE = 2'd0, PH_PAIR = 2'd1, PH_RSQ = 2'd2, PH_POS = 2'd3;
    reg [1:0]  phase;
    reg [4:0]  uop;                   // micro-step inside a pair / body update
    reg [3:0]  i, j;                  // current pair, or body (i) in PH_POS
    reg [63:0] step;

    // ---------------- datapath registers ----------------
    reg [63:0] dx, dy, dz, t0, t1, r2, inv, mag, b1m, b2m;

    reg  [63:0] ma, mb, aa, ab;
    reg         asub;
    wire [63:0] mp, ay;
    fp_mul u_mul (.a(ma), .b(mb), .y(mp));
    fp_add u_add (.a(aa), .b(ab), .sub(asub), .y(ay));

    reg         rs_start;
    wire        rs_done;
    wire [63:0] rs_y;
    fp_rsqrt u_rsqrt (.clk(clk), .rst(rst), .start(rs_start), .x(r2),
                      .done(rs_done), .y(rs_y));

    // Operand selection: which add/mul each micro-step issues
    always @* begin
        ma = 64'd0; mb = 64'd0; aa = 64'd0; ab = 64'd0; asub = 1'b0;
        if (phase == PH_PAIR) begin
            case (uop)
                0:  begin aa = bx[i]; ab = bx[j]; asub = 1; end            // dx
                1:  begin aa = by[i]; ab = by[j]; asub = 1;                // dy
                          ma = dx; mb = dx; end                            // dx*dx
                2:  begin aa = bz[i]; ab = bz[j]; asub = 1;                // dz
                          ma = dy; mb = dy; end                            // dy*dy
                3:  begin aa = t0; ab = t1; ma = dz; mb = dz; end          // dx2+dy2, dz*dz
                4:  begin aa = t0; ab = t1; end                            // r2
                6:  begin ma = inv; mb = inv; end                          // inv^2
                7:  begin ma = t0;  mb = inv; end                          // inv^3
                8:  begin ma = dt;  mb = t0;  end                          // mag
                9:  begin ma = bm[i]; mb = mag; end                        // b1m
                10: begin ma = bm[j]; mb = mag; end                        // b2m
                11: begin ma = dx; mb = b2m; end
                12: begin aa = bvx[i]; ab = t0; asub = 1; ma = dy; mb = b2m; end
                13: begin aa = bvy[i]; ab = t1; asub = 1; ma = dz; mb = b2m; end
                14: begin aa = bvz[i]; ab = t0; asub = 1; ma = dx; mb = b1m; end
                15: begin aa = bvx[j]; ab = t1;           ma = dy; mb = b1m; end
                16: begin aa = bvy[j]; ab = t0;           ma = dz; mb = b1m; end
                17: begin aa = bvz[j]; ab = t1; end
                default: ;
            endcase
        end else if (phase == PH_POS) begin
            case (uop)
                0: begin ma = dt; mb = bvx[i]; end
                1: begin aa = bx[i]; ab = t0; ma = dt; mb = bvy[i]; end
                2: begin aa = by[i]; ab = t1; ma = dt; mb = bvz[i]; end
                3: begin aa = bz[i]; ab = t0; end
                default: ;
            endcase
        end
    end

    // Host register reads
    always @(posedge clk) begin
        if (rd_en) begin
            if (addr[11:8] == 4'h1) begin
                case (addr[2:0])
                    3'd0: rdata <= bx [addr[6:3]];
                    3'd1: rdata <= by [addr[6:3]];
                    3'd2: rdata <= bz [addr[6:3]];
                    3'd3: rdata <= bvx[addr[6:3]];
                    3'd4: rdata <= bvy[addr[6:3]];
                    3'd5: rdata <= bvz[addr[6:3]];
                    3'd6: rdata <= bm [addr[6:3]];
                    default: rdata <= 64'd0;
                endcase
            end else begin
                case (addr)
                    12'h001: rdata <= {62'd0, done, busy};
                    12'h002: rdata <= nbodies;
                    12'h003: rdata <= nsteps;
                    12'h004: rdata <= dt;
                    12'h005: rdata <= cycles;
                    default: rdata <= 64'd0;
                endcase
            end
        end
    end

    // Main FSM + host register writes
    always @(posedge clk) begin
        rs_start <= 1'b0;
        if (rst) begin
            phase <= PH_IDLE;
            busy  <= 1'b0;
            done  <= 1'b0;
            nbodies <= 0; nsteps <= 0; dt <= 0; cycles <= 0;
        end else begin
            if (busy) cycles <= cycles + 1;

            case (phase)
            PH_IDLE: begin
                if (wr_en) begin
                    if (addr[11:8] == 4'h1) begin
                        case (addr[2:0])
                            3'd0: bx [addr[6:3]] <= wdata;
                            3'd1: by [addr[6:3]] <= wdata;
                            3'd2: bz [addr[6:3]] <= wdata;
                            3'd3: bvx[addr[6:3]] <= wdata;
                            3'd4: bvy[addr[6:3]] <= wdata;
                            3'd5: bvz[addr[6:3]] <= wdata;
                            3'd6: bm [addr[6:3]] <= wdata;
                            default: ;
                        endcase
                    end else begin
                        case (addr)
                            12'h000: if (wdata[0]) begin
                                busy   <= 1'b1;
                                done   <= 1'b0;
                                cycles <= 0;
                                step   <= 0;
                                uop    <= 0;
                                i      <= 0;
                                j      <= 1;
                                if (nsteps == 0) begin
                                    busy <= 1'b0;
                                    done <= 1'b1;
                                end else
                                    phase <= PH_PAIR;
                            end
                            12'h002: nbodies <= wdata;
                            12'h003: nsteps  <= wdata;
                            12'h004: dt      <= wdata;
                            default: ;
                        endcase
                    end
                end
            end

            PH_PAIR: begin
                uop <= uop + 1;
                case (uop)
                    0:  dx <= ay;
                    1:  begin dy <= ay; t0 <= mp; end
                    2:  begin dz <= ay; t1 <= mp; end
                    3:  begin t0 <= ay; t1 <= mp; end
                    4:  r2 <= ay;
                    5:  begin rs_start <= 1'b1; phase <= PH_RSQ; end
                    6:  t0  <= mp;
                    7:  t0  <= mp;
                    8:  mag <= mp;
                    9:  b1m <= mp;
                    10: b2m <= mp;
                    11: t0  <= mp;
                    12: begin bvx[i] <= ay; t1 <= mp; end
                    13: begin bvy[i] <= ay; t0 <= mp; end
                    14: begin bvz[i] <= ay; t1 <= mp; end
                    15: begin bvx[j] <= ay; t0 <= mp; end
                    16: begin bvy[j] <= ay; t1 <= mp; end
                    17: begin
                        bvz[j] <= ay;
                        uop    <= 0;
                        if (j == nbodies - 1) begin
                            if (i == nbodies - 2) begin   // last pair done
                                i     <= 0;
                                phase <= PH_POS;
                            end else begin
                                i <= i + 1;
                                j <= i + 2;
                            end
                        end else
                            j <= j + 1;
                    end
                    default: ;
                endcase
            end

            PH_RSQ: if (rs_done) begin
                inv   <= rs_y;
                uop   <= 6;
                phase <= PH_PAIR;
            end

            PH_POS: begin
                uop <= uop + 1;
                case (uop)
                    0: t0 <= mp;
                    1: begin bx[i] <= ay; t1 <= mp; end
                    2: begin by[i] <= ay; t0 <= mp; end
                    3: begin
                        bz[i] <= ay;
                        uop   <= 0;
                        if (i == nbodies - 1) begin       // all bodies moved
                            i <= 0;
                            j <= 1;
                            if (step == nsteps - 1) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                phase <= PH_IDLE;
                            end else begin
                                step  <= step + 1;
                                phase <= PH_PAIR;
                            end
                        end else
                            i <= i + 1;
                    end
                    default: ;
                endcase
            end
            endcase
        end
    end
endmodule
