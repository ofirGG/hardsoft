`timescale 1ns/1ps
// Batched front end for ray_sphere_accel.
//
// Instead of ~10 uncached MMIO accesses per query from the CPU, rays arrive
// as a 64-bit stream (fed by a DMA engine from a ray buffer in memory) and
// results leave as a 64-bit stream (written back by DMA). The CPU only sets
// up the scene once and starts the DMA transfers for a whole batch of rays.
//
// The verified ray_sphere_accel core is reused unchanged; this module drives
// its register port. While the core works on one ray, the next ray is already
// accepted into a 7-word prefetch buffer, and the previous result waits in an
// output register, so stream transfers overlap with computation.
//
// Input stream, 7 words per ray (valid/ready handshake):
//   word 0: bit0 = mode (0 nearest-hit, TMIN = -EPSILON; 1 any-hit, TMIN = +EPSILON)
//   words 1..6: px, py, pz, dx, dy, dz (binary64)
// Output stream, 2 words per ray, in input order:
//   word 0: bit0 = hit, bits[15:8] = sphere index
//   word 1: t (binary64)
// Configuration port (use before streaming): same register map as
// ray_sphere_accel, i.e. NSPHERES at 0x002 and the sphere table at 0x100+.
module ray_batch_accel #(
    parameter MAXS = 16
) (
    input  wire        clk,
    input  wire        rst,
    // configuration
    input  wire        cfg_wr,
    input  wire [11:0] cfg_addr,
    input  wire [63:0] cfg_wdata,
    // ray stream in
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [63:0] in_data,
    // result stream out
    output reg         out_valid,
    input  wire        out_ready,
    output reg  [63:0] out_data
);
    localparam [63:0] EPS_POS = 64'h3EE4F8B588E368F1;   // +0.00001
    localparam [63:0] EPS_NEG = 64'hBEE4F8B588E368F1;   // -0.00001

    // ---------------------------------------------------------- core port
    reg         c_wr, c_rd;
    reg  [11:0] c_addr;
    reg  [63:0] c_wdata;
    wire [63:0] c_rdata;
    wire        c_done;

    ray_sphere_accel #(.MAXS(MAXS)) u_core (
        .clk(clk), .rst(rst), .wr_en(c_wr), .rd_en(c_rd), .addr(c_addr),
        .wdata(c_wdata), .rdata(c_rdata), .irq(c_done));

    // ----------------------------------------------------- prefetch buffer
    reg [63:0] buf_w [0:6];
    reg [2:0]  buf_cnt;
    wire       buf_full = (buf_cnt == 3'd7);
    reg        buf_free;                         // engine has consumed the ray
    assign in_ready = !buf_full;

    always @(posedge clk) begin
        if (rst)
            buf_cnt <= 3'd0;
        else if (buf_free)
            buf_cnt <= 3'd0;                     // only happens when full
        else if (in_valid && in_ready) begin
            buf_w[buf_cnt] <= in_data;
            buf_cnt <= buf_cnt + 3'd1;
        end
    end

    // -------------------------------------------------------------- engine
    localparam E_IDLE = 3'd0, E_LOAD = 3'd1, E_START = 3'd2, E_WAIT = 3'd3,
               E_RD0 = 3'd4, E_RD1 = 3'd5, E_RD2 = 3'd6;
    reg [2:0]  state;
    reg [2:0]  f;                                // ray word being loaded
    reg        mode_r;
    reg [63:0] res_hit;
    reg        res_pending;                      // result captured, not yet sent
    reg        out_sel;                          // 0: word 0 next, 1: word 1 next
    reg [63:0] res0, res1;

    // Core port driver (combinational from the engine state)
    always @* begin
        c_wr = 1'b0; c_rd = 1'b0; c_addr = 12'd0; c_wdata = 64'd0;
        buf_free = 1'b0;
        case (state)
            E_IDLE: if (cfg_wr) begin
                c_wr = 1'b1; c_addr = cfg_addr; c_wdata = cfg_wdata;
            end
            E_LOAD: begin
                c_wr = 1'b1;
                if (f == 3'd0) begin
                    c_addr  = 12'h003;           // TMIN from the mode bit
                    c_wdata = buf_w[0][0] ? EPS_POS : EPS_NEG;
                end else begin
                    c_addr  = 12'h003 + f;       // 0x004..0x009 ray registers
                    c_wdata = buf_w[f];
                end
                if (f == 3'd6) buf_free = 1'b1;  // next ray may stream in
            end
            E_START: begin
                c_wr = 1'b1; c_addr = 12'h000; c_wdata = {62'd0, mode_r, 1'b1};
            end
            E_RD0: begin c_rd = 1'b1; c_addr = 12'h00A; end
            E_RD1: begin c_rd = 1'b1; c_addr = 12'h00B; end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= E_IDLE;
            f <= 3'd0;
            res_pending <= 1'b0;
            out_valid <= 1'b0;
            out_sel <= 1'b0;
        end else begin
            case (state)
                E_IDLE: if (buf_full && !cfg_wr) begin
                    mode_r <= buf_w[0][0];
                    f      <= 3'd0;
                    state  <= E_LOAD;
                end
                E_LOAD: begin
                    f <= f + 3'd1;
                    if (f == 3'd6) state <= E_START;
                end
                E_START: state <= E_WAIT;
                E_WAIT:  if (c_done) state <= E_RD0;
                E_RD0:   state <= E_RD1;
                E_RD1:   begin res_hit <= c_rdata; state <= E_RD2; end
                // The result is stored once the previous one has been sent
                E_RD2:   if (!res_pending) begin
                    res0 <= res_hit;
                    res1 <= c_rdata;
                    res_pending <= 1'b1;
                    state <= E_IDLE;
                end
                default: state <= E_IDLE;
            endcase

            // Output stream: two words per pending result
            if (out_valid && out_ready) begin
                if (out_sel) begin
                    out_valid   <= 1'b0;
                    out_sel     <= 1'b0;
                    res_pending <= 1'b0;
                end else begin
                    out_sel  <= 1'b1;
                    out_data <= res1;
                end
            end else if (res_pending && !out_valid) begin
                out_valid <= 1'b1;
                out_data  <= res0;
            end
        end
    end
endmodule
