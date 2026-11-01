module shape_polar #(
    parameter integer H_PAIRS   = 960,
    parameter integer V_LINES   = 1080,
    parameter integer BLK_SHIFT = 3,
    parameter integer NRAY      = 128,
    parameter integer GAP_TOL   = 3,
    parameter integer MIN_AREA  = 10,
    parameter integer MIN_BBOX  = 32,
    parameter integer MAX_R     = 160,
    parameter integer COV_MIN   = 96
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire        i_start,
    input  wire        i_roi,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_g1,
    input  wire [7:0]  i_ty,
    input  wire [26:0] i_sx,
    input  wire [26:0] i_sy,
    input  wire [15:0] i_area,
    input  wire [10:0] i_bx0,
    input  wire [10:0] i_bx1,
    input  wire [10:0] i_by0,
    input  wire [10:0] i_by1,
    input  wire        i_valid,
    output wire [2:0]  o_cls,
    output wire        o_upd,
    output wire [7:0]  o_dbg_cov,
    output wire [7:0]  o_dbg_rmin,
    output wire [15:0] o_dbg_s
);

    assign o_cls      = 3'd0;
    assign o_upd      = 1'b0;
    assign o_dbg_cov  = 8'd0;
    assign o_dbg_rmin = 8'd0;
    assign o_dbg_s    = 16'd0;

endmodule
