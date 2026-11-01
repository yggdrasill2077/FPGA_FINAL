//==============================================================================
// shape_multi_recog.v -- multi-object shape recognition front end
//
//  Pixel path:
//    4x4 foreground blocks -> GRID_X x GRID_Y statistics -> frame-end BFS
//    -> up to four tight candidates -> one shared polar classifier.
//
//  This keeps the expensive 128-ray engine single-instance.  The scheduler
//  presents one candidate at a time and restricts the ray scanner to that
//  candidate's bbox, so a nearby object cannot be mistaken for part of the
//  current radial fingerprint.
//==============================================================================
module shape_multi_recog #(
    parameter integer H_PAIRS        = 960,
    parameter integer V_LINES        = 1080,
    parameter integer GRID_X         = 32,
    parameter integer GRID_Y         = 18,
    parameter integer CELL_SEED_MIN  = 4,
    parameter integer CELL_MERGE_MIN = 1,
    parameter integer MIN_AREA       = 12,
    parameter integer MIN_BBOX       = 6,
    parameter integer FILL_MIN       = 4,
    parameter integer MERGE_GAP      = 1,
    parameter integer MAX_BBOX_W     = 1800,
    parameter integer MAX_BBOX_H     = 1000,
    parameter integer POLAR_NRAY     = 128,
    parameter integer POLAR_GAP_TOL  = 3,
    parameter integer POLAR_MIN_AREA = 8,
    parameter integer POLAR_MIN_BBOX = 16,
    parameter integer POLAR_COV_MIN  = 96,
    parameter integer POLAR_MAX_R    = 160,
    parameter integer SCHED_TIMEOUT  = 60000,
    parameter integer AUTO_TY        = 1,
    parameter [7:0]   TY_MARGIN      = 8'd20,
    parameter [7:0]   TY_CAP         = 8'd110,
    parameter [7:0]   TY_FLOOR       = 8'd24,
    parameter integer PAPER_GATE_EN  = 1,
    parameter [7:0]   PAPER_MIN_LEVEL = 8'd56,
    parameter integer PAPER_ERODE    = 8,
    parameter integer PAPER_MIN_SAMPLES = 32,
    parameter integer PAPER_MIN_SIZE    = 32,
    parameter integer PAPER_FILL_MIN    = 64,
    parameter integer PAPER_MARGIN      = 12,
    parameter integer PAPER_HOLD_FRAMES = 6,
    parameter integer LETTER_EN         = 1,
    parameter integer LETTER_MIN_BBOX   = 72,
    parameter integer LETTER_THAM       = 26,
    parameter integer LETTER_MARGIN     = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_g1,
    input  wire [7:0]  i_ty,

    output wire [2:0]  o_num,
    output wire [3:0]  o_valid,
    output wire [19:0] o_cls,
    output wire [63:0] o_area,
    output wire [107:0] o_sx,
    output wire [107:0] o_sy,
    output wire [43:0] o_bx0,
    output wire [43:0] o_bx1,
    output wire [43:0] o_by0,
    output wire [43:0] o_by1,
    output wire        o_done
);

    // The original single-target recogniser derived the white-paper threshold
    // from the previous frame's brightest pixel.  Keep the same behaviour here;
    // otherwise a fixed 170 threshold admits shadows and dark table edges.
    reg  [7:0] max_y, max_y_l;
    reg        vs_d;
    wire [7:0] pix_max = (i_g0 > i_g1) ? i_g0 : i_g1;
    wire       vs_rise = i_vs & ~vs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d    <= 1'b0;
            max_y   <= 8'd0;
            max_y_l <= 8'd200;
        end else begin
            vs_d <= i_vs;
            if (vs_rise) begin
                max_y_l <= max_y;
                max_y   <= 8'd0;
            end else if (i_de && (pix_max > max_y)) begin
                max_y <= pix_max;
            end
        end
    end

    wire [8:0] ty_calc = (max_y_l > TY_MARGIN) ?
                         ({1'b0, max_y_l} - {1'b0, TY_MARGIN}) : 9'd0;
    wire [7:0] ty_auto = (ty_calc > {1'b0, TY_CAP}) ? TY_CAP :
                         ((ty_calc < {1'b0, TY_FLOOR}) ? TY_FLOOR : ty_calc[7:0]);
    wire [7:0] ty_eff  = !AUTO_TY ? i_ty : ty_auto;

    // The paper/display carrier must be genuinely bright.  Gate dark-ink
    // detection to the eroded previous-frame carrier bbox so the tabletop and
    // shadows cannot create foreground blocks around a distant sheet.
    wire paper_inside;
    wire paper_valid;
    wire [10:0] paper_bx0, paper_bx1, paper_by0, paper_by1;
    wire [7:0] paper_ty = (ty_eff < PAPER_MIN_LEVEL) ? PAPER_MIN_LEVEL : ty_eff;

    shape_paper_gate #(
        .H_PAIRS(H_PAIRS), .V_LINES(V_LINES),
        .ERODE_PX(PAPER_ERODE),
        .MIN_SAMPLES(PAPER_MIN_SAMPLES),
        .MIN_SIZE(PAPER_MIN_SIZE),
        .FILL_MIN(PAPER_FILL_MIN),
        .HOLD_FRAMES(PAPER_HOLD_FRAMES)
    ) u_paper_gate (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(paper_ty),
        .o_valid(paper_valid),
        .o_bx0(paper_bx0), .o_bx1(paper_bx1),
        .o_by0(paper_by0), .o_by1(paper_by1),
        .o_cur_inside(paper_inside)
    );

    wire carrier_ok = !PAPER_GATE_EN || paper_inside;
    wire [7:0] fg_mask0 = ((i_g0 < ty_eff) && carrier_ok) ? 8'd0 : 8'd255;
    wire [7:0] fg_mask1 = ((i_g1 < ty_eff) && carrier_ok) ? 8'd0 : 8'd255;

    wire [2:0]  g_num;
    wire [3:0]  g_valid;
    wire [63:0] g_area;
    wire [107:0] g_sx, g_sy;
    wire [43:0] g_bx0, g_bx1, g_by0, g_by1;
    wire        g_done;

    // Reject a component that runs into the carrier border.  When a lamp or a
    // window is included in the bright-pixel bbox, the gate box grows over the
    // dark tabletop between the two regions; that tabletop then becomes one
    // huge foreground component and displaces the real shapes in the top-4
    // list.  The grid applies this test before its area sort, so a border band
    // can never consume one of the four candidate slots.
    wire paper_box_ok = (paper_bx1 > (paper_bx0 + PAPER_MARGIN*2)) &&
                        (paper_by1 > (paper_by0 + PAPER_MARGIN*2));

    shape_grid_multi_v2 #(
        .H_PAIRS(H_PAIRS), .V_LINES(V_LINES),
        .GRID_X(GRID_X), .GRID_Y(GRID_Y),
        .CELL_SEED_MIN(CELL_SEED_MIN),
        .CELL_MERGE_MIN(CELL_MERGE_MIN),
        .MIN_AREA(MIN_AREA), .MIN_BBOX(MIN_BBOX),
        .FILL_MIN(FILL_MIN), .MERGE_GAP(MERGE_GAP),
        .MAX_BBOX_W(MAX_BBOX_W), .MAX_BBOX_H(MAX_BBOX_H),
        .PAPER_MARGIN_PX(PAPER_MARGIN)
    ) u_grid (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs),
        .i_g0(fg_mask0), .i_g1(fg_mask1), .i_ty(8'd1),
        .i_gate_en(PAPER_GATE_EN && paper_valid && paper_box_ok),
        .i_gx0(paper_bx0), .i_gx1(paper_bx1),
        .i_gy0(paper_by0), .i_gy1(paper_by1),
        .o_num(g_num), .o_valid(g_valid),
        .o_bx0(g_bx0), .o_bx1(g_bx1),
        .o_by0(g_by0), .o_by1(g_by1),
        .o_sx(g_sx), .o_sy(g_sy), .o_area(g_area),
        .o_done(g_done)
    );

    wire        s_start;
    wire [1:0]  s_sel;
    wire [15:0] s_sel_area;
    wire [26:0] s_sel_sx, s_sel_sy;
    wire [10:0] s_sel_bx0, s_sel_bx1, s_sel_by0, s_sel_by1;

    wire [4:0]  p_cls;
    wire        p_upd;

    shape_multi_sched #(
        .MAX_CAND(4), .TIMEOUT(SCHED_TIMEOUT)
    ) u_sched (
        .clk(clk), .rst_n(rst_n),
        .i_grid_done(g_done), .i_num(g_num), .i_valid(g_valid),
        .i_area(g_area), .i_sx(g_sx), .i_sy(g_sy),
        .i_bx0(g_bx0), .i_bx1(g_bx1), .i_by0(g_by0), .i_by1(g_by1),
        .i_pol_upd(p_upd), .i_pol_cls(p_cls),
        .o_start(s_start), .o_sel(s_sel),
        .o_num(o_num), .o_valid(o_valid), .o_cls(o_cls),
        .o_area(o_area), .o_sx(o_sx), .o_sy(o_sy),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_sel_area(s_sel_area), .o_sel_sx(s_sel_sx), .o_sel_sy(s_sel_sy),
        .o_sel_bx0(s_sel_bx0), .o_sel_bx1(s_sel_bx1),
        .o_sel_by0(s_sel_by0), .o_sel_by1(s_sel_by1),
        .o_done(o_done)
    );

    shape_polar #(
        .H_PAIRS(H_PAIRS), .V_LINES(V_LINES), .BLK_SHIFT(2),
        .NRAY(POLAR_NRAY), .GAP_TOL(POLAR_GAP_TOL),
        .MIN_AREA(POLAR_MIN_AREA), .MIN_BBOX(POLAR_MIN_BBOX),
        .MAX_R(POLAR_MAX_R), .COV_MIN(POLAR_COV_MIN),
        .CAND_MODE(1),
        .LETTER_EN(LETTER_EN), .LETTER_MIN_BBOX(LETTER_MIN_BBOX),
        .LETTER_THAM(LETTER_THAM), .LETTER_MARGIN(LETTER_MARGIN)
    ) u_polar (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_start(s_start), .i_roi(1'b1),
        .i_g0(fg_mask0), .i_g1(fg_mask1), .i_ty(8'd1),
        .i_sx(s_sel_sx), .i_sy(s_sel_sy), .i_area(s_sel_area),
        .i_bx0(s_sel_bx0), .i_bx1(s_sel_bx1),
        .i_by0(s_sel_by0), .i_by1(s_sel_by1), .i_valid(1'b1),
        .o_cls(p_cls), .o_upd(p_upd),
        .o_blk_cov(), .o_blk_bx0(), .o_blk_bx1(), .o_blk_by0(), .o_blk_by1(),
        .o_dbg_cov(), .o_dbg_rmin(), .o_dbg_s()
    );

endmodule
