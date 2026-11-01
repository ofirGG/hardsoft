`timescale 1ns/1ps
// Reciprocal square root, y = 1 / sqrt(x), for binary64 x > 0.
//
// Multi-cycle unit: a bit-trick seed followed by Newton-Raphson iterations
//     y <- y * (1.5 - (0.5 * x) * y * y)
// Each iteration roughly doubles the number of correct bits; the seed is good
// to ~3.4e-3 relative error, so 4 iterations reach double precision
// (verified < 1e-15 relative error in common/tb/tb_fp.v).
//
// It owns one fp_mul and one fp_add. Latency: 1 + 4*ITER cycles = 17.
module fp_rsqrt #(
    parameter ITER = 4
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [63:0] x,
    output reg         done,          // one-cycle pulse, y valid from then on
    output reg  [63:0] y
);
    localparam [63:0] MAGIC = 64'h5FE6EB50C7B537A9;  // seed constant for binary64
    localparam [63:0] HALF  = 64'h3FE0000000000000;  // 0.5
    localparam [63:0] THREE_HALVES = 64'h3FF8000000000000;  // 1.5

    localparam S_IDLE = 3'd0, S_HALF = 3'd1, S_SQ = 3'd2, S_MULH = 3'd3,
               S_SUB  = 3'd4, S_UPD = 3'd5;

    reg  [2:0]  state;
    reg  [3:0]  iter;
    reg  [63:0] xin, hx, t;

    reg  [63:0] ma, mb;
    wire [63:0] mp;
    wire [63:0] as;
    fp_mul u_mul (.a(ma), .b(mb), .y(mp));
    fp_add u_add (.a(THREE_HALVES), .b(t), .sub(1'b1), .y(as));

    always @* begin
        case (state)
            S_HALF:  begin ma = xin; mb = HALF; end   // hx = 0.5 * x
            S_SQ:    begin ma = y;   mb = y;    end   // t  = y * y
            S_MULH:  begin ma = hx;  mb = t;    end   // t  = hx * t
            S_UPD:   begin ma = y;   mb = t;    end   // y  = y * t
            default: begin ma = 64'd0; mb = 64'd0; end
        endcase
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    xin   <= x;
                    y     <= MAGIC - (x >> 1);
                    iter  <= 0;
                    state <= S_HALF;
                end
                S_HALF: begin hx <= mp; state <= S_SQ; end
                S_SQ:   begin t  <= mp; state <= S_MULH; end
                S_MULH: begin t  <= mp; state <= S_SUB; end
                S_SUB:  begin t  <= as; state <= S_UPD; end
                S_UPD:  begin
                    y <= mp;
                    if (iter == ITER - 1) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        iter  <= iter + 1;
                        state <= S_SQ;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
