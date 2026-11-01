//==============================================================================
// shape_polar.v -- polar / radial fingerprint shape classifier
//
//  Map builder:
//    one foreground bit per 2^BLK_SHIFT square block (4x4 -> 480x270)
//    a block is set when any pixel in it is foreground
//
//  Frame-end scanner:
//    128 rays from the grayscale moment centroid, Q8 block coordinates.
//    Each ray keeps the outermost foreground block.  A three-block miss gap
//    terminates the ray, which tolerates holes and short shadow dropouts.
//
//  Shape fingerprint:
//    r(theta) = outer radius of the target for each ray.
//    A 3-point circular median removes isolated ray spikes.
//    Normalized DFT harmonics:
//      A2 -> rectangle / two-fold anisotropy
//      A3 -> triangle
//      A4 -> square (and cross)
//      CV -> circle versus polygon
//      min(r)/mean(r) -> cross versus square
//
//  Output classes:
//    0 unknown, 1 circle, 2 square, 3 triangle, 4 cross, 5 rectangle,
//    6..31 = uppercase A..Z.  A high-confidence letter match takes priority;
//    otherwise the polar geometry result is kept.
//
//  Letter path (after the polar classification):
//    candidate bbox -> tight bbox -> geometric centre.
//    Around that centre the scanner visits 16 concentric radii and samples
//    32 angles on each circle.  For every radius it records
//      ink   = sampled arc coverage (how much of the circumference is inked)
//      cross = number of ink/background transitions (how many strokes it cuts)
//    The 16-step radial waveform is matched against 26 x 10 font/size
//    prototypes.  This ring waveform is the primary letter decision.  The old
//    16x16 occupancy signature is retained as an optional fallback only and is
//    disabled by default to save RAM.  Both reuse the same 4x4 block map.
//
//  Contour direction-code corner channel:
//    After the tight bbox is known, an 8-connected Moore trace walks the
//    block-map outline.  The differential of the clockwise direction code
//    marks convex turns (2,3) and concave turns (6,7).  The resulting
//    {convex,concave} pair is a soft second opinion: it re-ranks only very
//    close ring matches and supplies a geometry sanity gate.  It never
//    replaces the ring waveform as the primary letter feature.
//==============================================================================
module shape_polar #(
    parameter integer H_PAIRS   = 960,
    parameter integer V_LINES   = 1080,
    parameter integer BLK_SHIFT = 3,
    parameter integer NRAY      = 128,
    parameter integer GAP_TOL   = 3,
    parameter integer MIN_AREA  = 10,
    parameter integer MIN_BBOX  = 32,
    parameter integer MAX_R     = 160,
    parameter integer COV_MIN   = 96,
    parameter integer MIN_BLOCKS = 8,
    parameter integer CAND_MODE = 0,   // 1: candidate bbox/moments supplied by
                                       //    shape_grid_multi; i_area is the
                                       //    4x4 block count of this candidate.
    parameter integer LETTER_EN = 1,
    parameter integer LETTER_MIN_BBOX = 72,
    parameter integer LETTER_THAM = 26,
    parameter integer LETTER_MARGIN = 4,
    parameter integer LETTER_SIG_EN = 0,
    parameter integer RING_EN = 1,
    parameter integer RING_THAM = 56,
    parameter integer RING_MARGIN = 10,
    parameter integer RAY_THAM = 64,
    parameter integer RAY_BAD_MAX = 9,
    parameter integer RAY_MARGIN = 0
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
    output reg  [4:0]  o_cls,
    output reg         o_upd,
    output wire [16:0] o_blk_cov,
    output wire [8:0]  o_blk_bx0,
    output wire [8:0]  o_blk_bx1,
    output wire [8:0]  o_blk_by0,
    output wire [8:0]  o_blk_by1,
    output wire [7:0]  o_dbg_cov,
    output wire [7:0]  o_dbg_rmin,
    output wire [15:0] o_dbg_s
);

    localparam integer IMG_W = H_PAIRS * 2;
    localparam integer BM_W  = IMG_W >> BLK_SHIFT;
    localparam integer BM_H  = (V_LINES + (1 << BLK_SHIFT) - 1) >> BLK_SHIFT;
    localparam integer BM_STRIDE = 512;
    localparam integer BM_DEPTH  = BM_STRIDE * BM_H;

    localparam [BLK_SHIFT-1:0] Y_LAST = {BLK_SHIFT{1'b1}};
    localparam [BLK_SHIFT-2:0] X_LAST = {(BLK_SHIFT-1){1'b1}};

    // FSM
    localparam [4:0] S_IDLE      = 5'd0;
    localparam [4:0] S_DIVX      = 5'd1;
    localparam [4:0] S_DIVX_END  = 5'd2;
    localparam [4:0] S_DIVY      = 5'd3;
    localparam [4:0] S_DIVY_END  = 5'd4;
    localparam [4:0] S_TRIG_SET  = 5'd5;
    localparam [4:0] S_EVAL      = 5'd7;
    localparam [4:0] S_RAY_SAVE  = 5'd8;
    localparam [4:0] S_FEAT_INIT = 5'd9;
    localparam [4:0] S_PRIME0    = 5'd10;
    localparam [4:0] S_FEAT_ACC  = 5'd13;
    localparam [4:0] S_PASS_END  = 5'd14;
    localparam [4:0] S_CLASS_MUL = 5'd15;
    localparam [4:0] S_CLASS_CMP = 5'd16;
    localparam [4:0] S_OUT       = 5'd17;
    localparam [4:0] S_DROP      = 5'd18;
    localparam [4:0] S_REQ       = 5'd19;
    localparam [4:0] S_LTR_INIT  = 5'd20;
    localparam [4:0] S_LTR_CELL  = 5'd21;
    localparam [4:0] S_LTR_SAMP  = 5'd22;
    localparam [4:0] S_LTR_NEXT  = 5'd23;
    localparam [4:0] S_LTR_CINIT = 5'd24;
    localparam [4:0] S_LTR_CREQ  = 5'd25;
    localparam [4:0] S_LTR_CACC  = 5'd26;
    localparam [4:0] S_LTR_DEC   = 5'd27;
localparam [4:0] S_LTR_BBOX  = 5'd28;
localparam [4:0] S_LTR_BCHK  = 5'd29;
localparam [4:0] S_LTR_BDONE = 5'd30;
localparam [4:0] S_LTR_WAIT  = 5'd31;
localparam [5:0] S_LTR_BWAIT = 6'd32;
localparam [5:0] S_RNG_INIT  = 6'd33;
localparam [5:0] S_RNG_REQ   = 6'd34;
localparam [5:0] S_RNG_WAIT  = 6'd35;
localparam [5:0] S_RNG_ACC   = 6'd36;
localparam [5:0] S_RNG_MREQ  = 6'd37;
localparam [5:0] S_RNG_MACC  = 6'd38;
localparam [5:0] S_RNG_DEC   = 6'd39;
localparam [5:0] S_RNG_CALC  = 6'd40;
localparam [5:0] S_RNG_ADDR  = 6'd41;
    localparam [5:0] S_CRN_INIT  = 6'd42;
    localparam [5:0] S_CRN_PROBE = 6'd43;
    localparam [5:0] S_CRN_WAIT  = 6'd44;
    localparam [5:0] S_CRN_TEST  = 6'd45;
    localparam [5:0] S_CRN_DONE  = 6'd46;
    localparam [5:0] S_EDG_INIT  = 6'd47;
    localparam [5:0] S_EDG_REQ   = 6'd48;
    localparam [5:0] S_EDG_WAIT  = 6'd49;
    localparam [5:0] S_EDG_SAMP  = 6'd50;
    localparam [5:0] S_EDG_DONE  = 6'd51;
    localparam [5:0] S_PRO_REQ   = 6'd52;
    localparam [5:0] S_PRO_WAIT  = 6'd53;
    localparam [5:0] S_PRO_ACC   = 6'd54;
    localparam [5:0] S_RAY_REQ   = 6'd55;
    localparam [5:0] S_RAY_ACC   = 6'd56;
    localparam [5:0] S_RAY_DONE  = 6'd57;
    localparam [5:0] S_PRO_CALC  = 6'd58;
    localparam [5:0] S_PRO_ADDR  = 6'd59;
    localparam [5:0] S_RAY_RD    = 6'd60;
    localparam [5:0] S_LTR_PREP  = 6'd61;
    localparam [5:0] S_GEO_PREP  = 6'd62;

    localparam integer LTR_NVAR = 10; // 5 fonts x 2 render sizes
    localparam integer LTR_NROM = 26 * LTR_NVAR * 16;

    localparam integer RNG_NANG = 32; // samples per circle
    localparam integer RNG_NRAD = 16; // concentric radii per glyph
    localparam integer RNG_NVAR = 10; // 5 fonts x 2 render sizes
    localparam integer RNG_NROM = 26 * RNG_NVAR * RNG_NRAD;
    localparam integer RAY_NVAR = 10;
    localparam integer RAY_NROM = 26 * RAY_NVAR * RNG_NANG;

    //--------------------------------------------------------------------------
    // Block bitmap: one bit per block.  Width padded to 512 so the address is
    // {block_y[8:0], block_x[8:0]}; no multiply is needed in the ray scanner.
    //--------------------------------------------------------------------------
    reg bm [0:BM_DEPTH-1];

    reg [10:0] pcol;
    reg [11:0] row;
    reg        de_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol <= 11'd0;
            row  <= 12'd0;
            de_d <= 1'b0;
        end else begin
            de_d <= i_de;
            if (i_vs) begin
                row <= 12'd0;
            end else if (de_d && !i_de) begin
                row <= row + 12'd1;
            end
            if (!i_de) begin
                pcol <= 11'd0;
            end else if (pcol == (H_PAIRS-1)) begin
                pcol <= 11'd0;
            end else begin
                pcol <= pcol + 11'd1;
            end
        end
    end

    wire [8:0] block_x = pcol >> (BLK_SHIFT-1);
    wire [8:0] block_y = row  >> BLK_SHIFT;
    wire       blk_end = i_de && (row[BLK_SHIFT-1:0] == Y_LAST) &&
                                  (pcol[BLK_SHIFT-2:0] == X_LAST);
    wire       blk_start = i_de && (row[BLK_SHIFT-1:0] == 0) &&
                                    (pcol[BLK_SHIFT-2:0] == 0);
    wire       fg0     = i_roi && (i_g0 < i_ty);
    wire       fg1     = i_roi && (i_g1 < i_ty);
    wire       fg_any  = fg0 | fg1;
    wire [17:0] wr_addr = {block_y, block_x};

    always @(posedge clk) begin
        // Clear each block on its first pixel, then set-if-any for the rest of
        // the block. This keeps independent state for every block column.
        if (blk_start)
            bm[wr_addr] <= fg_any;
        else if (fg_any)
            bm[wr_addr] <= 1'b1;
    end

    // Per-block foreground accumulator.  The old code read bm[wr_addr] back
    // while streaming, which forced a second physical copy of the whole map.
    // blk_acc tracks exactly the same OR-of-pixels value in one FF.
    reg blk_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         blk_acc <= 1'b0;
        else if (blk_start) blk_acc <= fg_any;
        else if (i_de)      blk_acc <= blk_acc | fg_any;
    end

    //--------------------------------------------------------------------------
    // Block-map coverage / centroid evidence.
    // Unlike the 1/16 point sampler, a block is set by ANY foreground pixel,
    // so a thin printed outline still contributes evidence at a distance.
    //--------------------------------------------------------------------------
    reg  [16:0] blk_cnt;
    reg  [26:0] blk_sumx, blk_sumy;
    reg  [16:0] blk_cnt_l;
    reg  [26:0] blk_sumx_l, blk_sumy_l;
    reg  [8:0]  blk_bx0, blk_bx1, blk_by0, blk_by1;
    reg  [8:0]  blk_bx0_l, blk_bx1_l, blk_by0_l, blk_by1_l;
    reg         blk_vs_d;
    wire        blk_vs_rise = i_vs & ~blk_vs_d;
    wire        blk_hit     = blk_acc | fg_any;
    // Explicit widening is required: in Verilog a shift result keeps the
    // left operand width, which would truncate the four fractional bits.
    wire [29:0] blk_numx    = {blk_sumx_l[25:0], 4'b0};  // avg block_x in Q4
    wire [29:0] blk_numy    = {blk_sumy_l[25:0], 4'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk_vs_d   <= 1'b0;
            blk_cnt    <= 17'd0;
            blk_sumx   <= 27'd0;
            blk_sumy   <= 27'd0;
            blk_cnt_l  <= 17'd0;
            blk_sumx_l <= 27'd0;
            blk_sumy_l <= 27'd0;
            blk_bx0    <= 9'h1FF; blk_bx1 <= 9'd0;
            blk_by0    <= 9'h1FF; blk_by1 <= 9'd0;
            blk_bx0_l  <= 9'h1FF; blk_bx1_l <= 9'd0;
            blk_by0_l  <= 9'h1FF; blk_by1_l <= 9'd0;
        end else begin
            blk_vs_d <= i_vs;
            if (blk_vs_rise) begin
                blk_cnt_l  <= blk_cnt;
                blk_sumx_l <= blk_sumx;
                blk_sumy_l <= blk_sumy;
                blk_bx0_l  <= blk_bx0;
                blk_bx1_l  <= blk_bx1;
                blk_by0_l  <= blk_by0;
                blk_by1_l  <= blk_by1;
            end
            if (i_vs) begin
                blk_cnt  <= 17'd0;
                blk_sumx <= 27'd0;
                blk_sumy <= 27'd0;
                blk_bx0  <= 9'h1FF; blk_bx1 <= 9'd0;
                blk_by0  <= 9'h1FF; blk_by1 <= 9'd0;
            end else if (blk_end && blk_hit) begin
                blk_cnt  <= blk_cnt + 17'd1;
                blk_sumx <= blk_sumx + {18'd0, block_x};
                blk_sumy <= blk_sumy + {18'd0, block_y};
                if (block_x < blk_bx0) blk_bx0 <= block_x;
                if (block_x > blk_bx1) blk_bx1 <= block_x;
                if (block_y < blk_by0) blk_by0 <= block_y;
                if (block_y > blk_by1) blk_by1 <= block_y;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Trig LUT: 128 x {sin[8:0],cos[8:0]}, Q8, scale 255 to stay in signed 9 bit.
    //--------------------------------------------------------------------------
    reg [17:0] trig_rom [0:NRAY-1];
    initial begin
        $readmemh("rtl/edge/polar_trig.mem", trig_rom);
    end

    reg [7:0]  ray;
    reg [2:0]  pass;
    reg [6:0]  k;
    wire [17:0] trig_ray = trig_rom[ray[6:0]];
    wire signed [8:0] cos_ray = trig_ray[8:0];
    wire signed [8:0] sin_ray = trig_ray[17:9];

    //--------------------------------------------------------------------------
    // Raw ray radius storage
    //--------------------------------------------------------------------------
    reg [7:0] rram [0:NRAY-1];
    // F53: `rram` now holds the measured ink-segment length of each of the
    // 128 rays (last_ink - first_ink + 1), not centre-to-boundary distance.
    // For a filled primitive the segment starts at the centroid, so this is
    // still its radius; for an outline it is the stroke thickness along the
    // ray.  Both keep the same rotational symmetry as the old radius curve.
    wire [6:0] feat_idx_n = (k[6:0] + 7'd1) & 7'h7F;
    wire [6:0] trig_idx_f = (pass[2:0] * k[6:0]) & 7'h7F;
    wire [7:0] rq = rram[feat_idx_n];
    wire [17:0] trig_feat = trig_rom[trig_idx_f];
    wire signed [8:0] cos_feat = trig_feat[8:0];
    wire signed [8:0] sin_feat = trig_feat[17:9];

    //--------------------------------------------------------------------------
    // Control / snapshot
    //--------------------------------------------------------------------------
    reg [5:0] state;
    reg [15:0] area_l;
    reg [26:0] sx_l, sy_l;
    reg [10:0] bx0_l, bx1_l, by0_l, by1_l;
    reg        valid_l;

    reg [29:0] div_num;
    reg [15:0] div_rem;
    reg [15:0] div_q;
    reg [4:0]  div_cnt;
    reg [15:0] area_q;
    reg [15:0] cxq, cyq;
    reg        cent_blk;

    wire [16:0] div_rl = {div_rem, div_num[29]};
    wire        div_ge = (div_rl >= {1'b0, area_q});

    reg signed [19:0] cx_fp, cy_fp;
    reg signed [19:0] xf, yf;
    reg signed [8:0]  cos_r, sin_r;
    reg [7:0]  rmax, ev_r, last_r, first_r, gap_cnt;
    reg        ev_inb, seen;
    reg [17:0] map_addr;
    reg [7:0]  cov;

    // Contour direction-code channel.
    reg  [5:0]  crn_conv, crn_conc;
    reg  [8:0]  crn_x, crn_y, crn_sx, crn_sy, crn_nx, crn_ny;
    reg  [2:0]  crn_dir, crn_prev_dir, crn_first_dir, crn_back_dir, crn_try;
    reg         crn_started, crn_valid, crn_rd_ok;
    reg  [10:0] crn_steps;
    reg  [17:0] crn_addr;
    reg  [8:0]  ltr_fg_x, ltr_fg_y;
    reg         ltr_fg_seen;

    //--------------------------------------------------------------------------
    // Letter signature / template matcher.
    //--------------------------------------------------------------------------
    reg  [4:0]  shape_cls_r;
    reg  [11:0] ltr_bx0_b, ltr_bx1_b, ltr_by0_b, ltr_by1_b;
    reg  [15:0] ltr_lw_b, ltr_lh_b, ltr_span, ltr_xpad, ltr_ypad;
    reg  [15:0] ltr_xa, ltr_ya;
    reg  [3:0]  ltr_gx, ltr_gy, ltr_row, ltr_var;
    reg  [2:0]  ltr_sub;
    reg signed [11:0] ltr_sx0, ltr_sy0;
    reg  [17:0] ltr_rd_addr;
    reg         ltr_rd_ok;
    reg         ltr_hit;
    reg  [15:0] ltr_work;
    reg  [15:0] sig_rows [0:15];
    reg  [4:0]  ltr_idx;
    reg  [8:0]  ltr_dist, ltr_var_best, ltr_best, ltr_second;
    reg  [4:0]  ltr_best_idx;
    reg  [8:0]  ltr_tmpl_idx;
    reg  [15:0] ltr_rom_q;
    reg  [8:0]  ltr_pbx, ltr_pby;
    reg  [8:0]  ltr_wx0, ltr_wx1, ltr_wy0, ltr_wy1;
    reg  [8:0]  ltr_tx0, ltr_tx1, ltr_ty0, ltr_ty1;
    reg  [15:0] ltr_fill, ltr_scan;
    reg         ltr_ok_q;
    integer     sri;
    integer     sii;
    integer     pii;

    reg [15:0] ltr_rom [0:LTR_NROM-1];
    initial begin
        $readmemh("rtl/edge/letter_templates.mem", ltr_rom);
    end

    wire [12:0] ltr_rom_addr = {ltr_tmpl_idx, ltr_row};

    function [4:0] popcount16;
        input [15:0] v;
        integer i;
        begin
            popcount16 = 5'd0;
            for (i = 0; i < 16; i = i + 1)
                popcount16 = popcount16 + {4'd0, v[i]};
        end
    endfunction

    wire signed [11:0] ltr_sx_s = ltr_sx0 + (ltr_sub[0] ? 12'sd1 : 12'sd0);
    wire signed [11:0] ltr_sy_s = ltr_sy0 + (ltr_sub[2] ? 12'sd1 : 12'sd0);
    wire ltr_in_b = (ltr_sx_s >= $signed({1'b0,ltr_bx0_b[10:0]})) &&
                    (ltr_sx_s <= $signed({1'b0,ltr_bx1_b[10:0]})) &&
                    (ltr_sy_s >= $signed({1'b0,ltr_by0_b[10:0]})) &&
                    (ltr_sy_s <= $signed({1'b0,ltr_by1_b[10:0]})) &&
                    (ltr_sx_s >= 0) && (ltr_sy_s >= 0) &&
                    (ltr_sx_s < BM_W) && (ltr_sy_s < BM_H);
    wire [17:0] ltr_addr_n = ltr_in_b ? {ltr_sy_s[8:0], ltr_sx_s[8:0]} : 18'd0;

    wire signed [11:0] ltr_sx0_n = $signed(ltr_bx0_b) +
                                   $signed({1'b0,ltr_xa[15:4]}) -
                                   $signed({1'b0,ltr_xpad[11:0]});
    wire signed [11:0] ltr_sy0_n = $signed(ltr_by0_b) +
                                   $signed({1'b0,ltr_ya[15:4]}) -
                                   $signed({1'b0,ltr_ypad[11:0]});
    wire ltr_pre_b = (ltr_sx0_n >= $signed({1'b0,ltr_bx0_b[10:0]})) &&
                     (ltr_sx0_n <= $signed({1'b0,ltr_bx1_b[10:0]})) &&
                     (ltr_sy0_n >= $signed({1'b0,ltr_by0_b[10:0]})) &&
                     (ltr_sy0_n <= $signed({1'b0,ltr_by1_b[10:0]})) &&
                     (ltr_sx0_n >= 0) && (ltr_sy0_n >= 0) &&
                     (ltr_sx0_n < BM_W) && (ltr_sy0_n < BM_H);
    wire [17:0] ltr_pre_addr = ltr_pre_b ?
        {ltr_sy0_n[8:0], ltr_sx0_n[8:0]} : 18'd0;

    wire [2:0]  ltr_sub_n = ltr_sub + 3'd1;
    wire signed [11:0] ltr_sx_n = ltr_sx0 + (ltr_sub_n[0] ? 12'sd1 : 12'sd0);
    wire signed [11:0] ltr_sy_n = ltr_sy0 + (ltr_sub_n[2] ? 12'sd1 : 12'sd0);
    wire ltr_nx_b = (ltr_sx_n >= $signed({1'b0,ltr_bx0_b[10:0]})) &&
                    (ltr_sx_n <= $signed({1'b0,ltr_bx1_b[10:0]})) &&
                    (ltr_sy_n >= $signed({1'b0,ltr_by0_b[10:0]})) &&
                    (ltr_sy_n <= $signed({1'b0,ltr_by1_b[10:0]})) &&
                    (ltr_sx_n >= 0) && (ltr_sy_n >= 0) &&
                    (ltr_sx_n < BM_W) && (ltr_sy_n < BM_H);
    wire [17:0] ltr_nx_addr = ltr_nx_b ?
        {ltr_sy_n[8:0], ltr_sx_n[8:0]} : 18'd0;

    wire [4:0] ltr_row_pc = popcount16(sig_rows[ltr_row] ^ ltr_rom_q);
    wire [8:0] ltr_total  = ltr_dist + {4'd0,ltr_row_pc};
    wire [8:0] ltr_letter_min = (ltr_total < ltr_var_best) ? ltr_total : ltr_var_best;

    wire ltr_sig_hit = LETTER_SIG_EN &&
                       (ltr_best <= LETTER_THAM) &&
                       (ltr_fill <= (ltr_scan - (ltr_scan >> 2))) &&
                       ((ltr_second - ltr_best) >= LETTER_MARGIN);

    //--------------------------------------------------------------------------
    // Ring waveform channel.
    //
    // The tight bbox gives a centre (bx0+bx1+1)/2 and a span.  For radius
    // k = 1..16 (block radius span*k/32) the scanner visits 32 angles and
    // records
    //     ink   = foreground hits        -> swept arc length on that circle
    //     cross = ink/background changes -> how many strokes the circle cuts
    // The 16 x {ink,cross} pairs are the glyph's radial fingerprint.
    //--------------------------------------------------------------------------
    // F53: the separate ring scan and its 26x10x16 template ROM are retired.
    // The 32 ray ink segments carry the letter features instead.

    reg  [3:0]  rng_k;
    reg  [4:0]  rng_a;
    reg  [5:0]  rng_ink, rng_cross;
    reg         rng_prev, rng_first;
    reg  [5:0]  ring_ink   [0:15];
    reg  [5:0]  ring_cross [0:15];
    reg  [2:0]  ring_q0 [0:15];
    reg  [2:0]  ring_q1 [0:15];
    reg  [2:0]  ring_q2 [0:15];
    reg  [2:0]  ring_q3 [0:15];
    reg  [3:0]  rq0, rq1, rq2, rq3;
    reg  [17:0] rng_rd_addr;
    reg         rng_rd_ok;
    reg         rng_ok_q;
    wire        bm_q, ltr_bm_q, rng_bm_q, crn_bm_q;
    reg  [15:0] rng_rom_q;
    reg  [9:0]  rng_tmpl;
    reg  [3:0]  rng_row;
    reg  [4:0]  rng_var;
    reg  [8:0]  rng_idx;
    reg  [10:0] rng_acc0, rng_acc1, rng_acc2, rng_var_best;
    reg  [11:0] rng_best, rng_second;
reg  [5:0]  rng_best_bad, rng_second_bad;

    // Ray-run channel: for every angle record the first ink sample, the last
    // ink sample and the number of ink/background runs along the ray.
    reg  [15:0] ray_rom [0:RAY_NROM-1];
    initial begin
        $readmemh("rtl/edge/letter_ray.mem", ray_rom);
    end
    reg  [15:0] pro_meas [0:31];
    reg  [15:0] ray_rom_q;
    reg  [13:0] ray_rd_addr;
    reg  [5:0]  ray_a;
    reg  [5:0]  ray_bad;
    reg  [3:0]  pro_start, pro_end;
    reg  [1:0]  pro_runs;
    reg         pro_prev, pro_seen;
    reg  [5:0]  pro_solid_cnt;
    reg  [15:0] ray_m_word;
    always @* ray_m_word = pro_meas[ray_a[4:0]];

    // Boundary-tip scan ("sharp points"): every bbox edge is walked once and
    // the number of separate ink runs plus the run coverage is recorded.
    reg  [8:0]  edg_x, edg_y;
    reg  [7:0]  seg_t [0:3];
    reg  [7:0]  seg_b [0:3];
    reg  [7:0]  seg_l [0:3];
    reg  [7:0]  seg_r [0:3];
    reg  [3:0]  edg_seg_t, edg_seg_b, edg_seg_l, edg_seg_r;
    reg  [1:0]  edg_runs_t, edg_runs_b, edg_runs_l, edg_runs_r;
    reg  [7:0]  edg_ink_t,  edg_ink_b,  edg_ink_l,  edg_ink_r;
    reg         edg_in_t,   edg_in_b,   edg_in_l,   edg_in_r;
    reg         edg_c_q1,   edg_c_q3;
    reg  [2:0]  edg_q_t,    edg_q_b,    edg_q_l,    edg_q_r;
    reg  [11:0] rng_best_raw, rng_second_raw;
    reg  [10:0] rng_best_core, rng_second_core;
    reg  [4:0]  rng_best_idx, rng_second_idx;
    reg  [5:0]  rng_var_corner;
    reg         ltr_sig_ok;
    reg  [15:0] rng_r8_q;
    reg  [16:0] rng_cx_q, rng_cy_q;
    reg  signed [8:0]  rng_cos_q, rng_sin_q;
    reg  signed [24:0] rng_dx_q, rng_dy_q;

    // Centre of the tight bbox in Q8 block coordinates (letter templates).
    wire [16:0] rng_cx8 = ({5'd0, ltr_bx0_b} + {5'd0, ltr_bx1_b} + 17'd1) << 7;
    wire [16:0] rng_cy8 = ({5'd0, ltr_by0_b} + {5'd0, ltr_by1_b} + 17'd1) << 7;
    // The 32-ray letter scan is centred on the tight bbox, matching the
    // template generator.  Geometry uses the 128-ray centroid scan instead.
    wire [16:0] pro_cx8 = rng_cx8;
    wire [16:0] pro_cy8 = rng_cy8;

    // Radius of circle k in Q8: span*(k+1)*12/256 = 0.75*span at k=15, so the
    // outer rings also cut the bbox corners instead of only the inscribed disc.
    wire [31:0] rng_r32 = ({16'd0, ltr_span} * ({28'd0, rng_k} + 32'd1)) * 32'd12;
    wire [15:0] rng_r8  = rng_r32[15:0];

    wire [6:0]  rng_tidx = {rng_a, 2'b00};   // 32 evenly spaced LUT entries
    wire [17:0] rng_trig = trig_rom[rng_tidx];
    wire signed [8:0] rng_cos = rng_trig[8:0];
    wire signed [8:0] rng_sin = rng_trig[17:9];

    // Two pipeline stages keep the radius multiply off the RAM address path.
    wire signed [24:0] rng_xq = $signed({8'd0, rng_cx_q}) + rng_dx_q;
    wire signed [24:0] rng_yq = $signed({8'd0, rng_cy_q}) + rng_dy_q;
    wire signed [11:0] rng_bx = rng_xq >>> 8;
    wire signed [11:0] rng_by = rng_yq >>> 8;

    // Samples outside the tight bbox count as background, which is exactly what
    // the template generator does for a w x h glyph grid.
    wire rng_in_b = (rng_bx >= $signed({1'b0,ltr_bx0_b})) &&
                    (rng_bx <= $signed({1'b0,ltr_bx1_b})) &&
                    (rng_by >= $signed({1'b0,ltr_by0_b})) &&
                    (rng_by <= $signed({1'b0,ltr_by1_b})) &&
                    (rng_bx >= 0) && (rng_by >= 0) &&
                    (rng_bx < BM_W) && (rng_by < BM_H);
    wire [17:0] rng_addr_n = rng_in_b ? {rng_by[8:0], rng_bx[8:0]} : 18'd0;

    wire rng_hit = rng_bm_q & rng_ok_q;

    // The ray-run scan deliberately walks angle-major, unlike the ring scan.
    // For one ray it records where ink starts, where it ends and how many
    // separate ink runs are crossed.  A filled geometric primitive starts at
    // rho=0 and has one run; a glyph normally starts later or has several runs.
    wire [17:0] pro_addr_n = rng_in_b ? {rng_by[8:0], rng_bx[8:0]} : 18'd0;
    wire        pro_hit    = rng_bm_q & rng_ok_q;
    wire [3:0]  pro_start_n = (rng_k == 4'd0) ?
                              (pro_hit ? 4'd0 : 4'd15) :
                              ((!pro_seen && pro_hit) ? rng_k : pro_start);
    wire [3:0]  pro_end_n   = pro_hit ? rng_k : pro_end;
    wire [1:0]  pro_runs_n  = (rng_k == 4'd0) ? {1'b0, pro_hit} :
                              ((pro_hit && !pro_prev && (pro_runs != 2'd3)) ?
                               pro_runs + 2'd1 : pro_runs);
    wire        pro_seen_n  = (rng_k == 4'd0) ? pro_hit : (pro_seen | pro_hit);
    wire        pro_solid_n = (rng_k == 4'd15) &&
                              (pro_start_n == 4'd0) && (pro_runs_n == 2'd1);
    wire [15:0] pro_word_n  = {6'd0, pro_start_n, pro_end_n, pro_runs_n};
    // Ink-segment length along one ray: rho(end) - rho(start) + 1.
    // A missing ray stores 0.  This replaces the old centre-to-boundary
    // radius waveform used by the geometry harmonic classifier.

    wire [3:0] ray_t_start = ray_rom_q[9:6];
    wire [3:0] ray_t_end   = ray_rom_q[5:2];
    wire [1:0] ray_t_runs  = ray_rom_q[1:0];
    wire [3:0] ray_m_start = ray_m_word[9:6];
    wire [3:0] ray_m_end   = ray_m_word[5:2];
    wire [1:0] ray_m_runs  = ray_m_word[1:0];
    // Tolerant ray-curve vote.  The 4x4 block grid can shift the glyph by up
    // to two samples, so a raw L1 distance is dominated by sampling phase.
    // Each of the 32 rays instead votes on whether the ink interval
    // (start, end, chord length) and the ink-run count agree within tolerance.
    wire        ray_m_ink   = (ray_m_start != 4'd15);
    wire        ray_t_ink   = (ray_t_start != 4'd15);
    wire [3:0]  ray_m_len   = ray_m_ink ? (ray_m_end - ray_m_start) : 4'd0;
    wire [3:0]  ray_t_len   = ray_t_ink ? (ray_t_end - ray_t_start) : 4'd0;
    wire        ray_span_ok = (absdiff4(ray_m_start, ray_t_start) <= 4'd2) &&
                              (absdiff4(ray_m_end,   ray_t_end)   <= 4'd3) &&
                              (absdiff4(ray_m_len,   ray_t_len)   <= 4'd2);
    wire        ray_run_ok  = (absdiff2(ray_m_runs, ray_t_runs) <= 2'd1);
    wire        ray_miss    = (ray_m_ink != ray_t_ink) ||
                              (ray_m_ink && !(ray_span_ok && ray_run_ok));
    wire [5:0]  ray_bad_n   = ray_bad + {5'd0, ray_miss};
    wire [13:0] ray_rom_addr = {rng_tmpl[9:0], ray_a[4:0]};

    function [5:0] absdiff6;
        input [5:0] a;
        input [5:0] b;
        begin
            absdiff6 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    function [3:0] absdiff4;
        input [3:0] a;
        input [3:0] b;
        begin
            absdiff4 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    function [2:0] absdiff3;
        input [2:0] a;
        input [2:0] b;
        begin
            absdiff3 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    function [1:0] absdiff2;
        input [1:0] a;
        input [1:0] b;
        begin
            absdiff2 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    // Four sub-border votes per side.  A segment counts when at least half of
    // its samples hit ink, i.e. a straight border covers the whole quarter.
    // Bit 3 is the first quarter (leftmost / topmost), matching the .mem
    // generator which packs segments MSB-first.
    function [3:0] segmask4;
        input [7:0] a0, a1, a2, a3;
        input [8:0] l0, l1, l2, l3;
        begin
            segmask4[3] = (l3 != 9'd0) && ({1'b0, a3} >= (l3 - (l3 >> 1)));
            segmask4[2] = (l2 != 9'd0) && ({1'b0, a2} >= (l2 - (l2 >> 1)));
            segmask4[1] = (l1 != 9'd0) && ({1'b0, a1} >= (l1 - (l1 >> 1)));
            segmask4[0] = (l0 != 9'd0) && ({1'b0, a0} >= (l0 - (l0 >> 1)));
        end
    endfunction

    function [4:0] pc16;
        input [15:0] v;
        integer i;
        begin
            pc16 = 5'd0;
            for (i = 0; i < 16; i = i + 1)
                pc16 = pc16 + {4'd0, v[i]};
        end
    endfunction

    // Coverage of one bbox edge in eighths, rounded like the Python model:
    //   q = floor((ink*8 + len/2) / len), saturated at 7.
    function [2:0] cov8;
        input [7:0] ink;
        input [8:0] len;
        reg  [10:0] i8, l1, l2, l3, l4, l5, l6, l7;
        begin
            i8 = ({3'd0, ink} << 3) + {2'd0, len >> 1};
            l1 = {2'd0, len};
            l2 = l1 << 1;
            l3 = l2 + l1;
            l4 = l1 << 2;
            l5 = l4 + l1;
            l6 = l4 + l2;
            l7 = l4 + l3;
            cov8 = 3'd0;
            if (i8 >= l1) cov8 = 3'd1;
            if (i8 >= l2) cov8 = 3'd2;
            if (i8 >= l3) cov8 = 3'd3;
            if (i8 >= l4) cov8 = 3'd4;
            if (i8 >= l5) cov8 = 3'd5;
            if (i8 >= l6) cov8 = 3'd6;
            if (i8 >= l7) cov8 = 3'd7;
        end
    endfunction

    function [4:0] absdiff5;
        input [4:0] a;
        input [4:0] b;
        begin
            absdiff5 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    function [10:0] min3_11;
        input [10:0] a;
        input [10:0] b;
        input [10:0] c;
        reg  [10:0] m;
        begin
            m = (a < b) ? a : b;
            min3_11 = (m < c) ? m : c;
        end
    endfunction

    // Per-template contour signature: {convex[2:0], concave[4:0]}.
    // There are exactly ten font/size variants per letter, in the same order
    // as letter_ring.mem.
    reg  [7:0] cor_rom [0:259];
    initial begin
        $readmemh("rtl/edge/letter_corner.mem", cor_rom);
    end
    // Ten font/size variants per letter: addr = idx*10 + var (NOT idx*16+var).
    wire [12:0] rng_cor_addr = ({8'd0, rng_idx[4:0]} * 13'd10) + {8'd0, rng_var};
    wire [7:0]  rng_cor_q = cor_rom[rng_cor_addr];

    // Boundary-tip template: {top_runs,top_cov, bot_runs,bot_cov,
    //                           left_runs,left_cov, right_runs,right_cov}
    // Five hex digits per variant, 26 letters x 10 variants, same order as
    // letter_ring.mem / letter_corner.mem.
    reg  [35:0] edg_rom [0:259];
    initial begin
        $readmemh("rtl/edge/letter_edge.mem", edg_rom);
    end
    wire [35:0] edg_tpl = edg_rom[rng_cor_addr];
    wire [2:0] rng_tcor_conv = rng_cor_q[7:5];
    wire [4:0] rng_tcor_conc = rng_cor_q[4:0];
    wire [2:0] crn_conv_c = (crn_conv > 6'd7) ? 3'd7 : crn_conv[2:0];
    wire [4:0] crn_conc_c = (crn_conc > 6'd31) ? 5'd31 : crn_conc[4:0];
    wire [5:0] rng_cor_cost = {3'd0, absdiff3(crn_conv_c, rng_tcor_conv)} +
                              {1'd0, absdiff5(crn_conc_c, rng_tcor_conc)};

    // Boundary-tip distance: run-count differences count double, coverage
    // differences single.  This is the "how many sharp points per side" vote.
    wire [5:0] edg_cost =
        {3'd0, absdiff2(edg_runs_t, edg_tpl[19:18]), 1'b0} +
        {3'd0, absdiff3(edg_q_t,    edg_tpl[17:15])} +
        {3'd0, absdiff2(edg_runs_b, edg_tpl[14:13]), 1'b0} +
        {3'd0, absdiff3(edg_q_b,    edg_tpl[12:10])} +
        {3'd0, absdiff2(edg_runs_l, edg_tpl[9:8]),   1'b0} +
        {3'd0, absdiff3(edg_q_l,    edg_tpl[7:5])} +
        {3'd0, absdiff2(edg_runs_r, edg_tpl[4:3]),   1'b0} +
        {3'd0, absdiff3(edg_q_r,    edg_tpl[2:0])};

    // 16-segment border signature: each bbox side is split into four equal
    // sub-borders and a segment votes 1 when at least half of it is inked.
    // A straight, square border sets all 16 bits; a circle only lights the
    // middle segments of each side; a D lights the whole left stem.
    wire [15:0] edg_seg_meas = {edg_seg_t, edg_seg_b, edg_seg_l, edg_seg_r};
    wire [15:0] edg_seg_diff = edg_seg_meas ^ edg_tpl[35:20];
    wire [4:0]  edg_seg_cost = pc16(edg_seg_diff);
    wire [6:0]  edg_cost_tot = {1'b0, edg_cost} + {2'd0, edg_seg_cost};

    // F53 letter score: 32-ray ink-segment agreement is the primary term.
    // Each mismatching ray costs 8, then the contour direction code and the
    // 16-segment border signature break the near-identical pairs.
    // Rank primarily by the number of mismatching rays.  The contour and
    // border costs are only tie-breakers: on serif prints the bbox edge is a
    // serif tip rather than the stem, so those costs are noisy and must not
    // outvote a one-ray difference.
    wire [11:0] ray_score = ({6'd0, ray_bad} << 6) +
                            {5'd0, rng_cor_cost, 1'b0} +
                            {5'd0, edg_cost_tot};

    //--------------------------------------------------------------------------
    // bm single read port.
    //   The three frame-end consumers (polar ray scan, tight-bbox scan and
    //   ring scan) run strictly one after another, so they time-share one
    //   physical read port.  Previously each had its own read port and the
    //   synthesizer replicated the 135 kbit map three times (51 RAM10 blocks).
    //--------------------------------------------------------------------------
    localparam [1:0] BM_SEL_POL = 2'd0;
    localparam [1:0] BM_SEL_BOX = 2'd1;
    localparam [1:0] BM_SEL_RNG = 2'd2;
    localparam [1:0] BM_SEL_CRN = 2'd3;

    wire crn_phase = (state == S_CRN_INIT) || (state == S_CRN_PROBE) ||
                     (state == S_CRN_WAIT) || (state == S_CRN_TEST) ||
                     (state == S_CRN_DONE);
    wire rng_phase = ((state >= S_RNG_INIT) && (state <= S_RNG_DEC)) ||
                     (state == S_PRO_REQ) || (state == S_PRO_CALC) ||
                     (state == S_PRO_ADDR) || (state == S_PRO_WAIT) ||
                     (state == S_PRO_ACC);
    wire box_phase = ((state >= S_LTR_BBOX) && (state < S_RNG_INIT)) ||
                     ((state >= S_EDG_INIT) && (state <= S_EDG_DONE));
    wire [1:0]  bm_sel   = crn_phase ? BM_SEL_CRN :
                           rng_phase ? BM_SEL_RNG :
                           box_phase ? BM_SEL_BOX : BM_SEL_POL;
    wire [17:0] bm_raddr = (bm_sel == BM_SEL_CRN) ? crn_addr :
                           (bm_sel == BM_SEL_RNG) ? rng_rd_addr :
                           (bm_sel == BM_SEL_BOX) ? ltr_rd_addr : map_addr;

    reg        bm_rq;
    reg [1:0]  bm_sel_d;
    always @(posedge clk) begin
        bm_rq    <= bm[bm_raddr];
        bm_sel_d <= bm_sel;
    end

    assign bm_q     = bm_rq & (bm_sel_d == BM_SEL_POL);
    assign ltr_bm_q = bm_rq & (bm_sel_d == BM_SEL_BOX);
    assign rng_bm_q = bm_rq & (bm_sel_d == BM_SEL_RNG);
    assign crn_bm_q = bm_rq & (bm_sel_d == BM_SEL_CRN);

    always @(posedge clk) begin
        rng_ok_q <= rng_rd_ok;
        ltr_ok_q <= ltr_rd_ok;
    end

    wire signed [19:0] xf_n = xf + {{11{cos_r[8]}}, cos_r};
    wire signed [19:0] yf_n = yf + {{11{sin_r[8]}}, sin_r};
    wire signed [11:0] bx_n = xf_n >>> 8;
    wire signed [11:0] by_n = yf_n >>> 8;
    wire               inb_n = (bx_n >= 0) && (bx_n < BM_W) &&
                               (by_n >= 0) && (by_n < BM_H);
    wire [17:0] addr_n = inb_n ? {by_n[8:0], bx_n[8:0]} : 18'd0;

    wire signed [19:0] xfirst = cx_fp + {{11{cos_ray[8]}}, cos_ray};
    wire signed [19:0] yfirst = cy_fp + {{11{sin_ray[8]}}, sin_ray};
    wire signed [11:0] bxf = xfirst >>> 8;
    wire signed [11:0] byf = yfirst >>> 8;
    wire               inb_f = (bxf >= 0) && (bxf < BM_W) &&
                               (byf >= 0) && (byf < BM_H);
    wire [17:0] addr_f = inb_f ? {byf[8:0], bxf[8:0]} : 18'd0;

    // Candidate mode: the shared 4x4 block map still contains every object in
    // the frame. Restrict every ray to the candidate bbox so a neighbouring
    // object cannot become this candidate's outer contour.
    wire [10:0] cbx0 = bx0_l >> BLK_SHIFT;
    wire [10:0] cbx1 = bx1_l >> BLK_SHIFT;
    wire [10:0] cby0 = by0_l >> BLK_SHIFT;
    wire [10:0] cby1 = by1_l >> BLK_SHIFT;
    wire [11:0] ltr_cw = (cbx1 >= cbx0) ? ({1'b0,cbx1} - {1'b0,cbx0} + 12'd1) : 12'd0;
    wire [11:0] ltr_ch = (cby1 >= cby0) ? ({1'b0,cby1} - {1'b0,cby0} + 12'd1) : 12'd0;
    wire [11:0] ltr_span_c = (ltr_cw > ltr_ch) ? ltr_cw : ltr_ch;
    wire [11:0] ltr_xpad_c = (ltr_span_c - ltr_cw) >> 1;
    wire [11:0] ltr_ypad_c = (ltr_span_c - ltr_ch) >> 1;
    // The grid candidate box is cell-snapped and can clip the last block row
    // of a glyph.  Scan a small margin around it and take the tight block
    // bbox, which is what the template generator uses.
    wire [10:0] ltr_wx0_c = (cbx0 > 11'd2) ? (cbx0 - 11'd2) : 11'd0;
    wire [10:0] ltr_wx1_c = ((cbx1 + 11'd2) < (BM_W-1)) ?
                            (cbx1 + 11'd2) : (BM_W-1);
    wire [10:0] ltr_wy0_c = (cby0 > 11'd2) ? (cby0 - 11'd2) : 11'd0;
    wire [10:0] ltr_wy1_c = ((cby1 + 11'd2) < (BM_H-1)) ?
                            (cby1 + 11'd2) : (BM_H-1);
    wire [8:0]  ltr_tb_x0 = (ltr_tx0 <= ltr_tx1) ? ltr_tx0 : ltr_wx0;
    wire [8:0]  ltr_tb_x1 = (ltr_tx0 <= ltr_tx1) ? ltr_tx1 : ltr_wx1;
    wire [8:0]  ltr_tb_y0 = (ltr_ty0 <= ltr_ty1) ? ltr_ty0 : ltr_wy0;
    wire [8:0]  ltr_tb_y1 = (ltr_ty0 <= ltr_ty1) ? ltr_ty1 : ltr_wy1;
    wire [15:0] ltr_tb_w = {7'd0,ltr_tb_x1} - {7'd0,ltr_tb_x0} + 16'd1;
    wire [15:0] ltr_tb_h = {7'd0,ltr_tb_y1} - {7'd0,ltr_tb_y0} + 16'd1;
    wire [15:0] ltr_tb_span = (ltr_tb_w > ltr_tb_h) ? ltr_tb_w : ltr_tb_h;
    wire [15:0] ltr_tb_xpad = (ltr_tb_span - ltr_tb_w) >> 1;
    wire [15:0] ltr_tb_ypad = (ltr_tb_span - ltr_tb_h) >> 1;

    // Quarter boundaries for the 4-way sub-border signature.  These are the
    // same boundaries the template generator uses: len/4, len/2, len-len/4.
    wire [8:0] edg_w9  = ltr_tb_w[8:0];
    wire [8:0] edg_h9  = ltr_tb_h[8:0];
    wire [8:0] edg_xq1 = edg_w9 >> 2;
    wire [8:0] edg_xq2 = edg_w9 >> 1;
    wire [8:0] edg_xq3 = edg_w9 - (edg_w9 >> 2);
    wire [8:0] edg_yq1 = edg_h9 >> 2;
    wire [8:0] edg_yq2 = edg_h9 >> 1;
    wire [8:0] edg_yq3 = edg_h9 - (edg_h9 >> 2);
    wire [8:0] edg_xoff = edg_x - ltr_tb_x0;
    wire [8:0] edg_yoff = edg_y - ltr_tb_y0;
    wire [1:0] edg_xseg = (edg_xoff >= edg_xq3) ? 2'd3 :
                          (edg_xoff >= edg_xq2) ? 2'd2 :
                          (edg_xoff >= edg_xq1) ? 2'd1 : 2'd0;
    wire [1:0] edg_yseg = (edg_yoff >= edg_yq3) ? 2'd3 :
                          (edg_yoff >= edg_yq2) ? 2'd2 :
                          (edg_yoff >= edg_yq1) ? 2'd1 : 2'd0;
    wire seg_big_enough = (edg_w9 >= 9'd10) && (edg_h9 >= 9'd10);
    wire [2:0] seg_full_sides =
        {2'd0, (edg_seg_t == 4'hF)} + {2'd0, (edg_seg_b == 4'hF)} +
        {2'd0, (edg_seg_l == 4'hF)} + {2'd0, (edg_seg_r == 4'hF)};
    wire seg_rect_strong = seg_big_enough && (seg_full_sides >= 3'd3);
    wire in_cand_cur = !CAND_MODE ||
                       (({1'b0,map_addr[8:0]} >= cbx0) &&
                        ({1'b0,map_addr[8:0]} <= cbx1) &&
                        ({1'b0,map_addr[17:9]} >= cby0) &&
                        ({1'b0,map_addr[17:9]} <= cby1));
    wire cand_exit_n = CAND_MODE &&
                       ((bx_n < $signed({1'b0,cbx0})) ||
                        (bx_n > $signed({1'b0,cbx1})) ||
                        (by_n < $signed({1'b0,cby0})) ||
                        (by_n > $signed({1'b0,cby1})));
    wire hit_now = ev_inb && bm_q && in_cand_cur;
    wire gap_stop = (!hit_now) && seen && (gap_cnt == (GAP_TOL-1));
    wire rmax_stop = (ev_r >= rmax);
    wire ray_done = (hit_now ? rmax_stop : (rmax_stop || gap_stop)) || cand_exit_n;

    // Clockwise 8-neighbour code: E,SE,S,SW,W,NW,N,NE.
    function signed [2:0] dir_dx;
        input [2:0] d;
        begin
            case (d)
            3'd0: dir_dx = 3'sd1;  3'd1: dir_dx = 3'sd1;
            3'd2: dir_dx = 3'sd0;  3'd3: dir_dx = -3'sd1;
            3'd4: dir_dx = -3'sd1; 3'd5: dir_dx = -3'sd1;
            3'd6: dir_dx = 3'sd0;  3'd7: dir_dx = 3'sd1;
            default: dir_dx = 3'sd0;
            endcase
        end
    endfunction

    function signed [2:0] dir_dy;
        input [2:0] d;
        begin
            case (d)
            3'd0: dir_dy = 3'sd0;  3'd1: dir_dy = 3'sd1;
            3'd2: dir_dy = 3'sd1;  3'd3: dir_dy = 3'sd1;
            3'd4: dir_dy = 3'sd0;  3'd5: dir_dy = -3'sd1;
            3'd6: dir_dy = -3'sd1; 3'd7: dir_dy = -3'sd1;
            default: dir_dy = 3'sd0;
            endcase
        end
    endfunction

    wire signed [2:0] crn_dx = dir_dx(crn_dir);
    wire signed [2:0] crn_dy = dir_dy(crn_dir);
    wire signed [10:0] crn_nxs = {2'b0, crn_x} + {{8{crn_dx[2]}}, crn_dx};
    wire signed [10:0] crn_nys = {2'b0, crn_y} + {{8{crn_dy[2]}}, crn_dy};
    wire crn_in_map_n = (crn_nxs >= 0) && (crn_nxs < BM_W) &&
                        (crn_nys >= 0) && (crn_nys < BM_H);
    wire crn_inb_n = crn_in_map_n &&
                     (crn_nxs >= {2'b0, ltr_tb_x0}) &&
                     (crn_nxs <= {2'b0, ltr_tb_x1}) &&
                     (crn_nys >= {2'b0, ltr_tb_y0}) &&
                     (crn_nys <= {2'b0, ltr_tb_y1});
    wire [17:0] crn_addr_n = crn_inb_n ? {crn_nys[8:0], crn_nxs[8:0]} : 18'd0;

    //--------------------------------------------------------------------------
    // Feature accumulators (3 passes over the ray table: h = 2, 3, 4)
    //--------------------------------------------------------------------------
    reg [7:0] ra, rb;
    reg signed [23:0] csum, ssum;
    reg signed [23:0] c2, s2, c3, s3, c4, s4;
    reg [15:0] s_total;
    reg [31:0] sum2;
    reg [7:0]  rmin;

    function [7:0] med3;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        reg [7:0] lo, hi;
        begin
            if (a < b) begin lo=a; hi=b; end else begin lo=b; hi=a; end
            if (c < lo)       med3 = lo;
            else if (c > hi)  med3 = hi;
            else              med3 = c;
        end
    endfunction

    // 128 samples: a 3-tap median removes isolated ray spikes without
    // clipping the 3rd/4th harmonic of a triangle or square.
    wire [7:0] rm = med3(ra, rb, rq);
    wire signed [17:0] mul_c = $signed({1'b0, rm}) * $signed(cos_feat);
    wire signed [17:0] mul_s = $signed({1'b0, rm}) * $signed(sin_feat);
    wire [15:0] rm2 = rm * rm;

    //--------------------------------------------------------------------------
    // Harmonic energies and final thresholds
    //--------------------------------------------------------------------------
    reg [63:0] e2, e3, e4, sq_s, cv_n;

    // Radius harmonics and tight-bbox gate.
    reg [15:0] bbox_w, bbox_h, bbox_max;
    wire [15:0] bw_l = (bx1_l >= bx0_l) ? (bx1_l - bx0_l + 11'd1) : 16'd0;
    wire [15:0] bh_l = (by1_l >= by0_l) ? (by1_l - by0_l + 11'd1) : 16'd0;
    wire [15:0] bm_l = (bw_l > bh_l) ? bw_l : bh_l;
    // Candidate mode computes the foreground centroid inside the scan box,
    // then clamps it to the middle half of that box.  The centroid gives the
    // correct origin for a triangle; the clamp stops shadows/noise from
    // pulling the origin to an extreme corner.
    wire [15:0] cx_lo = {5'd0,bx0_l} + {2'd0,(bw_l >> 2)};
    wire [15:0] cx_hi = {5'd0,bx1_l} - {2'd0,(bw_l >> 2)};
    wire [15:0] cy_lo = {5'd0,by0_l} + {2'd0,(bh_l >> 2)};
    wire [15:0] cy_hi = {5'd0,by1_l} - {2'd0,(bh_l >> 2)};
    wire [15:0] cx_cl = (cxq < cx_lo) ? cx_lo : ((cxq > cx_hi) ? cx_hi : cxq);
    wire [15:0] cy_cl = (div_q < cy_lo) ? cy_lo : ((div_q > cy_hi) ? cy_hi : div_q);

    wire [63:0] e2s = e2 << 12;
    wire [63:0] e3s = e3 << 12;
    wire [63:0] e4s = e4 << 12;
    // The trig LUT is Q8: C/S are 255x larger than a unit-amplitude DFT.
    wire [63:0] sq_h = sq_s * 64'd65025;
    wire [63:0] cv_s = cv_n * 64'd10000;
    wire [63:0] sq18  = sq_s * 64'd324;

    wire rect_hit = (e2s > (sq_h * 64'd60)) && (e2 > e4) && (e2 > e3);
    wire tri_hit  = (e3s > (sq_h * 64'd33)) && (e3 > e2) && (e3 > e4);
    wire cross_r  = (({8'd0,rmin} * 16'd12800) < ({8'd0,s_total} * 16'd70));
    wire cross_hit= (e4s > (sq_h * 64'd50)) && cross_r && (e4 > e2) && (e4 > e3);
    wire square_hit=(e4s > (sq_h * 64'd9)) && (cv_s < sq18) &&
                    (e4 > e2) && (e4 > e3);
    // 4x4 block quantization, centroid clamp and lens distortion perturb the
    // radius by more than 10% on paper targets.  Squares are still kept out
    // of this branch because square_hit runs first and requires e4 dominance,
    // so the CV gate only needs to reject irregular blobs.
    wire circle_hit=(cv_s < (sq_s * 64'd144));
    wire cov_ok   = (cov >= COV_MIN) && (s_total != 16'd0);

    // Contour-direction geometry gate.  The block-map Moore trace is noisy
    // enough that convex count alone cannot be a hard letter decision, but it
    // is a strong sanity check for the five geometric classes.
    wire crn_near_square = (ltr_tb_w * 5 >= ltr_tb_h * 4) &&
                           (ltr_tb_h * 5 >= ltr_tb_w * 4);
    reg [4:0] shape_cls_g;
    always @* begin
        shape_cls_g = shape_cls_r;
        if (crn_valid) begin
            case (shape_cls_r)
            5'd1: begin
                if (crn_conv >= 6)
                    shape_cls_g = 5'd4;                 // cross / plus
                else if ((crn_conv >= 3) && crn_near_square)
                    shape_cls_g = 5'd2;                 // square missed by harmonic
                else if (crn_conv > 1)
                    shape_cls_g = 5'd0;
            end
            5'd2: begin
                if (crn_conv <= 1)
                    shape_cls_g = 5'd1;
                else if ((crn_conv < 3) || (crn_conv > 6))
                    shape_cls_g = 5'd0;
            end
            5'd3: if ((crn_conv < 2) || (crn_conv > 4)) shape_cls_g = 5'd0;
            5'd4: if (crn_conv < 6) shape_cls_g = 5'd0;
            5'd5: if ((crn_conv < 3) || (crn_conv > 6)) shape_cls_g = 5'd0;
            default: shape_cls_g = shape_cls_r;
            endcase
        end
        // A circle whose border is straight across three or four whole sides
        // is a rounded-corner square/rectangle that the harmonic fit missed.
        if (seg_rect_strong && (shape_cls_g == 5'd1))
            shape_cls_g = crn_near_square ? 5'd2 : 5'd5;
    end

    // Structural check of the geometry class against the measured bbox edge
    // profile.  A circle must be round on all four sides, a square/rectangle
    // must have four full single-run edges, a triangle needs a full base and a
    // pointed top, and a cross needs four narrow single-run arms.  Letters
    // (L/H/B/E/K...) fail these tests, which stops them from jumping into a
    // primitive shape class when the ring distance drifts on paper.
    wire [2:0] eg_t = edg_q_t, eg_b = edg_q_b, eg_l = edg_q_l, eg_r = edg_q_r;
    wire geo_edge_ok =
        // A tangent circle can quantise to 0 on one or two sides at large
        // radii.  It is still round as long as no side is a full straight
        // edge; square/rectangle classes require all four full sides below.
        (shape_cls_g == 5'd1) ? ((eg_t <= 3'd6) && (eg_b <= 3'd6) &&
                                 (eg_l <= 3'd6) && (eg_r <= 3'd6)) :
        ((shape_cls_g == 5'd2) || (shape_cls_g == 5'd5)) ?
                                (((eg_t >= 3'd6) && (eg_b >= 3'd6) &&
                                 (eg_l >= 3'd6) && (eg_r >= 3'd6) &&
                                 (edg_runs_t == 2'd1) && (edg_runs_b == 2'd1) &&
                                 (edg_runs_l == 2'd1) && (edg_runs_r == 2'd1)) ||
                                // One broken side is common on printed or
                                // shaded squares; the 16-segment signature
                                // still shows a straight border on 3 sides.
                                (seg_rect_strong &&
                                 (eg_t >= 3'd4) && (eg_b >= 3'd4) &&
                                 (eg_l >= 3'd4) && (eg_r >= 3'd4) &&
                                 (edg_runs_t <= 2'd2) && (edg_runs_b <= 2'd2) &&
                                 (edg_runs_l <= 2'd2) && (edg_runs_r <= 2'd2))) :
        (shape_cls_g == 5'd3) ? ((eg_b >= 3'd5) && (eg_t <= 3'd3) &&
                                 (eg_l <= 3'd4) && (eg_r <= 3'd4)) :
        (shape_cls_g == 5'd4) ? ((eg_t <= 3'd5) && (eg_b <= 3'd5) &&
                                 (eg_l <= 3'd5) && (eg_r <= 3'd5) &&
                                 (edg_runs_t <= 2'd1) && (edg_runs_b <= 2'd1) &&
                                 (edg_runs_l <= 2'd1) && (edg_runs_r <= 2'd1)) :
        1'b1;

    // F53 solid rule: a geometric primitive is a filled body.  At least 28 of
    // the 32 rays must start in ink at rho=0 and cross exactly one ink run,
    // i.e. every ray sees object -> background and nothing else.  An isolated
    // vertical bar (letter I) also has that property, so the bbox aspect ratio
    // keeps it in the letter path.
    wire solid_aspect_ok = (ltr_tb_w * 3 >= ltr_tb_h) &&
                           (ltr_tb_h * 3 >= ltr_tb_w);
    wire one_full_side = (eg_t >= 3'd6) || (eg_b >= 3'd6) ||
                         (eg_l >= 3'd6) || (eg_r >= 3'd6);
    // At block resolution a letter junction can also look like "ink at rho=0,
    // one run" (K, X, Y).  A filled primitive covers at least 45% of its bbox,
    // except a triangle whose bbox corners are empty: that case is confirmed
    // by shape_cls_g==3 plus one fully inked bbox side.
    wire solid_geo = (pro_solid_cnt >= 6'd30) && solid_aspect_ok &&
                     (((ltr_fill * 20) >= (ltr_scan * 9)) ||
                      ((shape_cls_g == 5'd3) && one_full_side));
    wire ray_geo_lock = solid_geo && (shape_cls_g != 5'd0);

    // T signature: a single full-width top bar over a narrow bottom stem.
    // Printed Y never has it, so a Y result can be vetoed when it appears.
    wire top_bar_full = (edg_runs_t == 2'd1) && (eg_t >= 3'd6) &&
                        (eg_b <= 3'd5) && (eg_l <= 3'd4) && (eg_r <= 3'd4);

    // Upper centre-stem signature.  T has a continuous vertical stroke at
    // one quarter and three eighths of the glyph height; Y has already split
    // into two arms there.  Sampling reuses the existing block-map walk.
    wire [8:0] edg_mid_x     = (ltr_tb_x0 + ltr_tb_x1) >> 1;
    wire [8:0] edg_quarter_y = ltr_tb_y0 + {1'b0, ltr_tb_h[8:2]};
    wire [8:0] edg_three8_y  = ltr_tb_y0 + {1'b0, ltr_tb_h[8:2]} +
                               {2'b0, ltr_tb_h[8:3]};
    wire centre_stem_top = edg_c_q1 & edg_c_q3;

    // L signature: a full left stem joined to a full bottom foot, with an
    // open top/right.  C has four short arc runs instead, so this signature
    // stops an L from being reported as C when the two ring scores are close.
    wire left_foot_full = (eg_l >= 3'd6) && (eg_b >= 3'd6) &&
                          (eg_t <= 3'd4) && (eg_r <= 3'd4);

    // Geometry class from the bbox edge skeleton.  The ring/harmonic class is
    // weak on a square whose corners are slightly rounded or whose edges are
    // broken by paper shading.  This independent path makes straight edges
    // dominant for square/rectangle decisions.
    wire [2:0] edge_full_single_cnt =
        ((eg_t >= 3'd6) && (edg_runs_t == 2'd1) ? 3'd1 : 3'd0) +
        ((eg_b >= 3'd6) && (edg_runs_b == 2'd1) ? 3'd1 : 3'd0) +
        ((eg_l >= 3'd6) && (edg_runs_l == 2'd1) ? 3'd1 : 3'd0) +
        ((eg_r >= 3'd6) && (edg_runs_r == 2'd1) ? 3'd1 : 3'd0);
    wire edges_all_ge4 = (eg_t >= 3'd4) && (eg_b >= 3'd4) &&
                         (eg_l >= 3'd4) && (eg_r >= 3'd4);
    wire edges_all_le6 = (eg_t <= 3'd6) && (eg_b <= 3'd6) &&
                         (eg_l <= 3'd6) && (eg_r <= 3'd6);
    wire edges_all_le5 = (eg_t <= 3'd5) && (eg_b <= 3'd5) &&
                         (eg_l <= 3'd5) && (eg_r <= 3'd5);
    wire edges_all_single = (edg_runs_t == 2'd1) && (edg_runs_b == 2'd1) &&
                            (edg_runs_l == 2'd1) && (edg_runs_r == 2'd1);
    wire rect_edge_strong = (edge_full_single_cnt >= 3'd3) &&
                            edges_all_ge4 && edges_all_single;
    wire circle_edge_strong = (edge_full_single_cnt == 3'd0) &&
                              edges_all_le6 &&
                              ((shape_cls_r == 5'd1) || (shape_cls_g == 5'd1));
    wire tri_edge_strong = (eg_b >= 3'd5) && (eg_t <= 3'd4) &&
                           (eg_l <= 3'd5) && (eg_r <= 3'd5) &&
                           ((shape_cls_r == 5'd3) || (shape_cls_g == 5'd3));
    wire cross_edge_strong = edges_all_le5 && edges_all_single &&
                             ((shape_cls_r == 5'd4) || (shape_cls_g == 5'd4));
    wire geom_edge_strong = rect_edge_strong || circle_edge_strong ||
                            tri_edge_strong || cross_edge_strong;

    reg [4:0] geom_cls_e;
    always @* begin
        geom_cls_e = shape_cls_g;
        if (rect_edge_strong)
            geom_cls_e = crn_near_square ? 5'd2 : 5'd5;
        else if (circle_edge_strong)
            geom_cls_e = 5'd1;
        else if (tri_edge_strong)
            geom_cls_e = 5'd3;
        else if (cross_edge_strong)
            geom_cls_e = 5'd4;
    end

    // A square may be misclassified as a circle by the harmonic channel.  A
    // full-edge skeleton is allowed to override that one wrong polar label,
    // but the override is still gated by the letter distance.
    wire polar_geo_class_ok = rect_edge_strong ?
        ((shape_cls_r == 5'd1) || (shape_cls_r == 5'd2) || (shape_cls_r == 5'd5) ||
         (shape_cls_g == 5'd1) || (shape_cls_g == 5'd2) || (shape_cls_g == 5'd5)) :
        (circle_edge_strong || tri_edge_strong || cross_edge_strong);
    // A hollow box with three fully inked sides (bottom/left/right) and a
    // broken top is a printed rectangle outline, not H.  Letters never put
    // three complete bbox sides in ink: E leaves the right side open and U
    // never has a fully inked bottom.
    wire hollow_box = (edg_q_b >= 3'd7) && (edg_q_l >= 3'd7) &&
                      (edg_q_r >= 3'd7) && (edg_q_t <= 3'd5);
    wire letter_weak = (rng_best_bad > RAY_BAD_MAX) || hollow_box;

    // D keeps a straight, full-height left stem; O only touches its bbox edge
    // near the vertical middle.  Veto O only when that stem is unambiguous,
    // so B/P/R (which also have a full left stem) keep their own templates.
    wire d_stem_ok = seg_big_enough && (edg_seg_l == 4'hF) &&
                     (edg_seg_r != 4'hF);
    // Radial ink coverage derived from the 32 ray segments.  A printed O is a
    // thick annulus and inks many consecutive radii on almost every angle;
    // D only inks its straight left stem at the inner radii.
    wire [4:0] rng_band_cnt =
        {4'd0,(ring_ink[0]  >= 6'd28)} + {4'd0,(ring_ink[1]  >= 6'd28)} +
        {4'd0,(ring_ink[2]  >= 6'd28)} + {4'd0,(ring_ink[3]  >= 6'd28)} +
        {4'd0,(ring_ink[4]  >= 6'd28)} + {4'd0,(ring_ink[5]  >= 6'd28)} +
        {4'd0,(ring_ink[6]  >= 6'd28)} + {4'd0,(ring_ink[7]  >= 6'd28)} +
        {4'd0,(ring_ink[8]  >= 6'd28)} + {4'd0,(ring_ink[9]  >= 6'd28)} +
        {4'd0,(ring_ink[10] >= 6'd28)} + {4'd0,(ring_ink[11] >= 6'd28)} +
        {4'd0,(ring_ink[12] >= 6'd28)} + {4'd0,(ring_ink[13] >= 6'd28)} +
        {4'd0,(ring_ink[14] >= 6'd28)} + {4'd0,(ring_ink[15] >= 6'd28)};
    wire o_band = (rng_band_cnt >= 5'd4);
    wire [4:0] rng_letter_cls =
        // B has one continuous top bar and one continuous bottom bowl; N has
        // two vertical stems (two runs per horizontal edge) and S has low
        // top/bottom coverage.  This recovers B when a serif print ties it
        // with N or S on the ray count.
        (((rng_best_idx == 5'd13) || (rng_best_idx == 5'd18)) &&
         (edg_runs_t == 2'd1) && (edg_runs_b == 2'd1) &&
         (edg_q_t >= 3'd5) && (edg_q_b >= 3'd5)) ? 5'd7 :
        ((rng_best_idx == 5'd3) && o_band && !d_stem_ok) ? 5'd20 :
        (((5'd6 + rng_best_idx) == 5'd20) && d_stem_ok) ?
        5'd9 : (5'd6 + rng_best_idx);
    // The F50 skeleton override is retained only as an archived experiment;
    // F51 uses the ray-run evidence above.
    wire geo_lock = 1'b0;

    //--------------------------------------------------------------------------
    // Block fill is a much more stable small-target feature than a high-order
    // harmonic: a filled circle occupies about 75% of its square bbox, while a
    // square occupies nearly 100%. The same ratio also separates circle and
    // square printed outlines (circle has a shorter perimeter).
    //--------------------------------------------------------------------------
    wire [31:0] bbox_wb = (bbox_w + ((1 << BLK_SHIFT) - 1)) >> BLK_SHIFT;
    wire [31:0] bbox_hb = (bbox_h + ((1 << BLK_SHIFT) - 1)) >> BLK_SHIFT;
    wire [31:0] map_blocks = bbox_wb * bbox_hb;
    wire [31:0] fill_cnt   = CAND_MODE ? {15'd0, i_area} : {15'd0, blk_cnt_l};
    wire [31:0] fill_lhs   = fill_cnt << 8;             // Q8 block fill
    wire small_target = (bbox_max <= 16'd64);
    wire near_square = (bbox_w * 5 >= bbox_h * 4) &&
                       (bbox_h * 5 >= bbox_w * 4);
    wire fill_square_hit = small_target && near_square &&
                           (fill_lhs >= (map_blocks * 228)) &&
                           (e4 > e2) && (e4 > e3);
    wire fill_circle_hit = small_target && near_square &&
                           (fill_lhs >= (map_blocks * 136)) &&
                           (fill_lhs <= (map_blocks * 224)) &&
                           (e4 > e2) && (e4 > e3);
    wire fill_ring_hit   = small_target && near_square &&
                           (fill_lhs < (map_blocks * 112)) &&
                           (e4 > e2) && (e4 > e3);

    reg [4:0] shape_cls_n;
    always @* begin
        if (!cov_ok)                       shape_cls_n = 5'd0;
        else if (rect_hit)                 shape_cls_n = 5'd5;
        else if (tri_hit)                  shape_cls_n = 5'd3;
        else if (cross_hit)                shape_cls_n = 5'd4;
        else if (fill_square_hit)          shape_cls_n = 5'd2;
        else if (fill_circle_hit || fill_ring_hit) shape_cls_n = 5'd1;
        else if (square_hit)               shape_cls_n = 5'd2;
        else if (circle_hit)               shape_cls_n = 5'd1;
        else                               shape_cls_n = 5'd0;
    end

    // Fallback for a solid target whose harmonic class is unknown: the bbox
    // edge skeleton still separates a four-sided body from a round one.
    reg [4:0] solid_cls;
    always @* begin
        solid_cls = shape_cls_n;
        if (solid_cls == 5'd0) begin
            if (rect_edge_strong)
                solid_cls = crn_near_square ? 5'd2 : 5'd5;
            else if (edges_all_le6)
                solid_cls = 5'd1;
        end
    end

    //--------------------------------------------------------------------------
    // Main FSM
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            o_cls <= 5'd0; o_upd <= 1'b0;
            area_l <= 16'd0; sx_l <= 27'd0; sy_l <= 27'd0;
            bx0_l <= 11'h7FF; bx1_l <= 11'd0; by0_l <= 11'h7FF; by1_l <= 11'd0;
            valid_l <= 1'b0;
            div_num <= 30'd0; div_rem <= 16'd0; div_q <= 16'd0;
            div_cnt <= 5'd0; area_q <= 16'd0; cxq <= 16'd0; cyq <= 16'd0;
            cent_blk <= 1'b0;
            cx_fp <= 20'd0; cy_fp <= 20'd0; xf <= 20'd0; yf <= 20'd0;
            cos_r <= 9'd0; sin_r <= 9'd0;
            ray <= 8'd0; rmax <= 8'd0; ev_r <= 8'd0; last_r <= 8'd0;
            first_r <= 8'd0; gap_cnt <= 8'd0;
            ev_inb <= 1'b0; seen <= 1'b0; map_addr <= 18'd0; cov <= 8'd0;
            crn_conv <= 6'd0; crn_conc <= 6'd0;
            crn_x <= 9'd0; crn_y <= 9'd0; crn_sx <= 9'd0; crn_sy <= 9'd0;
            crn_nx <= 9'd0; crn_ny <= 9'd0;
            crn_dir <= 3'd5; crn_prev_dir <= 3'd0; crn_first_dir <= 3'd0;
            crn_back_dir <= 3'd4; crn_try <= 3'd0;
            crn_started <= 1'b0; crn_valid <= 1'b0; crn_rd_ok <= 1'b0;
            crn_steps <= 11'd0; crn_addr <= 18'd0;
            ltr_fg_x <= 9'd0; ltr_fg_y <= 9'd0; ltr_fg_seen <= 1'b0;
            pass <= 3'd0; k <= 7'd0; ra <= 8'd0; rb <= 8'd0;
            csum <= 24'sd0; ssum <= 24'sd0;
            c2 <= 24'sd0; s2 <= 24'sd0; c3 <= 24'sd0; s3 <= 24'sd0;
            c4 <= 24'sd0; s4 <= 24'sd0;
            s_total <= 16'd0; sum2 <= 32'd0; rmin <= 8'hFF;
            e2 <= 64'd0; e3 <= 64'd0; e4 <= 64'd0; sq_s <= 64'd0; cv_n <= 64'd0;
            bbox_w <= 16'd0; bbox_h <= 16'd0; bbox_max <= 16'd0;
            shape_cls_r <= 5'd0;
            ltr_bx0_b <= 12'd0; ltr_bx1_b <= 12'd0;
            ltr_by0_b <= 12'd0; ltr_by1_b <= 12'd0;
            ltr_lw_b <= 16'd0; ltr_lh_b <= 16'd0; ltr_span <= 16'd0;
            ltr_xpad <= 16'd0; ltr_ypad <= 16'd0;
            ltr_xa <= 16'd0; ltr_ya <= 16'd0;
            ltr_gx <= 4'd0; ltr_gy <= 4'd0; ltr_row <= 4'd0; ltr_var <= 4'd0;
            ltr_sub <= 3'd0; ltr_sx0 <= 12'sd0; ltr_sy0 <= 12'sd0;
        ltr_rd_addr <= 18'd0; ltr_rd_ok <= 1'b0;
            ltr_hit <= 1'b0;
            ltr_work <= 16'd0;
            ltr_idx <= 5'd0; ltr_dist <= 9'd0; ltr_var_best <= 9'd511;
            ltr_best <= 9'd511; ltr_second <= 9'd511; ltr_best_idx <= 5'd0;
            ltr_tmpl_idx <= 9'd0; ltr_rom_q <= 16'd0;
            rng_best_raw <= 12'hFFF; rng_second_raw <= 12'hFFF;
            rng_best_core <= 11'd1023; rng_second_core <= 11'd1023;
            rng_second_idx <= 5'd0; rng_var_corner <= 6'd63;
            ray_rom_q <= 16'd0; ray_a <= 6'd0; ray_bad <= 6'd0;
            pro_start <= 4'd15; pro_end <= 4'd15; pro_runs <= 2'd0;
            pro_prev <= 1'b0; pro_seen <= 1'b0; pro_solid_cnt <= 6'd0;
            for (sri = 0; sri < 16; sri = sri + 1)
                sig_rows[sri] <= 16'd0;
        end else begin
            o_upd <= 1'b0;
            if (LETTER_SIG_EN)
                ltr_rom_q <= ltr_rom[ltr_rom_addr];
            else
                ltr_rom_q <= 16'd0;
            case (state)
            S_IDLE: begin
                if (i_start) begin
                    area_l  <= i_area;
                    sx_l    <= i_sx;
                    sy_l    <= i_sy;
                    bx0_l   <= i_bx0;
                    bx1_l   <= i_bx1;
                    by0_l   <= i_by0;
                    by1_l   <= i_by1;
                    valid_l <= i_valid;
                    // Prefer block-map centroid evidence. The sparse moment
                    // centroid remains only as a fallback for very large maps.
                    if (!i_valid ||
                        (CAND_MODE ? (i_area < MIN_AREA) :
                         ((blk_cnt_l < MIN_BLOCKS) && (i_area < MIN_AREA)))) begin
                        state <= S_DROP;
                    end else begin
                        if (!CAND_MODE && blk_cnt_l >= MIN_BLOCKS &&
                            blk_cnt_l <= 17'd60000) begin
                            cent_blk <= 1'b1;
                            div_num  <= blk_numx;
                            area_q   <= blk_cnt_l[15:0];
                        end else begin
                            cent_blk <= 1'b0;
                            div_num  <= {3'd0, i_sx};
                            area_q   <= i_area;
                        end
                        div_rem <= 16'd0;
                        div_q   <= 16'd0;
                        div_cnt <= 5'd30;
                        state   <= S_DIVX;
                    end
                end
            end

            S_DIVX: begin
                div_rem <= div_ge ? (div_rl - {1'b0,area_q}) : div_rl;
                div_q   <= {div_q[14:0], div_ge};
                div_num <= {div_num[28:0], 1'b0};
                div_cnt <= div_cnt - 5'd1;
                if (div_cnt == 5'd1) state <= S_DIVX_END;
            end
            S_DIVX_END: begin
                cxq <= div_q;
                div_num <= cent_blk ? blk_numy : {3'd0, sy_l};
                div_rem <= 16'd0;
                div_q   <= 16'd0;
                div_cnt <= 5'd30;
                state   <= S_DIVY;
            end
            S_DIVY: begin
                div_rem <= div_ge ? (div_rl - {1'b0,area_q}) : div_rl;
                div_q   <= {div_q[14:0], div_ge};
                div_num <= {div_num[28:0], 1'b0};
                div_cnt <= div_cnt - 5'd1;
                if (div_cnt == 5'd1) state <= S_DIVY_END;
            end
            S_DIVY_END: begin
                cyq <= div_q;
                if (CAND_MODE) begin
                    cx_fp <= $signed({5'd0,cx_cl[10:0]}) <<< (8-BLK_SHIFT);
                    cy_fp <= $signed({5'd0,cy_cl[10:0]}) <<< (8-BLK_SHIFT);
                end else if (cent_blk) begin
                    // blk_num = (sum block_x)<<4 / count => Q4 block units.
                    cx_fp <= $signed({1'b0,cxq}) <<< 4;
                    cy_fp <= $signed({1'b0,div_q}) <<< 4;
                end else begin
                    cx_fp <= $signed({1'b0,cxq}) <<< (8-BLK_SHIFT);
                    cy_fp <= $signed({1'b0,div_q}) <<< (8-BLK_SHIFT);
                end
                bbox_w <= bw_l;
                bbox_h <= bh_l;
                bbox_max <= bm_l;
                rmax <= ((bm_l + ((1<<BLK_SHIFT)-1)) >> BLK_SHIFT) + 3 > MAX_R ?
                        MAX_R[7:0] :
                        (((bm_l + ((1<<BLK_SHIFT)-1)) >> BLK_SHIFT) + 3);
                ray <= 8'd0;
                cov <= 8'd0;
                state <= S_TRIG_SET;
            end

            S_TRIG_SET: begin
                cos_r <= cos_ray;
                sin_r <= sin_ray;
                xf <= xfirst;
                yf <= yfirst;
                ev_r <= 8'd1;
                ev_inb <= inb_f;
                map_addr <= addr_f;
                last_r <= 8'd0;
                first_r <= 8'd0;
                gap_cnt <= 8'd0;
                seen <= 1'b0;
                state <= S_REQ;
            end
            S_REQ: begin
                state <= S_EVAL;
            end
            S_EVAL: begin
                if (hit_now) begin
                    if (!seen) first_r <= ev_r;
                    last_r <= ev_r;
                    seen <= 1'b1;
                    gap_cnt <= 8'd0;
                end else if (seen) begin
                    gap_cnt <= gap_cnt + 8'd1;
                end

                if (ray_done) begin
                    state <= S_RAY_SAVE;
                end else begin
                    xf <= xf_n;
                    yf <= yf_n;
                    ev_r <= ev_r + 8'd1;
                    ev_inb <= inb_n;
                    map_addr <= addr_n;
                    state <= S_REQ;
                end
            end
            S_RAY_SAVE: begin
                // The geometry waveform uses the outer end of the measured
                // ink segment: for a filled body the segment starts at the
                // centre, for an outline it is the outer contour.  start/end/
                // runs are still recorded by the 32-ray scan below.
                rram[ray[6:0]] <= seen ? last_r : 8'd0;
                if (seen && (cov != 8'd255)) cov <= cov + 8'd1;
                if (ray == (NRAY-1)) begin
                    state <= S_FEAT_INIT;
                end else begin
                    ray <= ray + 8'd1;
                    state <= S_TRIG_SET;
                end
            end

            S_FEAT_INIT: begin
                pass <= 3'd2;
                s_total <= 16'd0;
                sum2 <= 32'd0;
                rmin <= 8'hFF;
                ra <= rram[NRAY-2];
                rb <= rram[NRAY-1];
                k <= 7'd0;
                csum <= 24'sd0;
                ssum <= 24'sd0;
                // Letter search state (ray templates only).
                rng_tmpl       <= 10'd0;
                rng_idx        <= 9'd0;
                rng_var        <= 5'd0;
                rng_best       <= 12'hFFF;
                rng_second     <= 12'hFFF;
                rng_best_raw   <= 12'hFFF;
                rng_second_raw <= 12'hFFF;
                rng_best_bad   <= 6'd63;
                rng_second_bad <= 6'd63;
                rng_best_core  <= 11'd1023;
                rng_second_core<= 11'd1023;
                rng_best_idx   <= 5'd0;
                rng_second_idx <= 5'd0;
                ray_a          <= 6'd0;
                ray_bad        <= 6'd0;
                state <= S_FEAT_ACC;
            end
            S_PRIME0: begin
                ra <= rram[NRAY-2];
                rb <= rram[NRAY-1];
                k <= 7'd0;
                csum <= 24'sd0;
                ssum <= 24'sd0;
                state <= S_FEAT_ACC;
            end
            S_FEAT_ACC: begin
                csum <= csum + {{6{mul_c[17]}}, mul_c};
                ssum <= ssum + {{6{mul_s[17]}}, mul_s};
                if (pass == 3'd2) begin
                    s_total <= s_total + {8'd0, rm};
                    sum2 <= sum2 + {16'd0, rm2};
                    if (rm < rmin) rmin <= rm;
                end
                ra <= rb;
                rb <= rq;
                k <= k + 7'd1;
                if (k == (NRAY-1)) state <= S_PASS_END;
            end
            S_PASS_END: begin
                if (pass == 3'd2) begin c2 <= csum; s2 <= ssum; end
                if (pass == 3'd3) begin c3 <= csum; s3 <= ssum; end
                if (pass == 3'd4) begin c4 <= csum; s4 <= ssum; end
                if (pass == 3'd4) begin
                    state <= S_CLASS_MUL;
                end else begin
                    pass <= pass + 3'd1;
                    state <= S_PRIME0;
                end
            end

            S_CLASS_MUL: begin
                e2 <= ($signed(c2) * $signed(c2)) + ($signed(s2) * $signed(s2));
                e3 <= ($signed(c3) * $signed(c3)) + ($signed(s3) * $signed(s3));
                e4 <= ($signed(c4) * $signed(c4)) + ($signed(s4) * $signed(s4));
                sq_s <= s_total * s_total;
                if ((NRAY * sum2) >= (s_total * s_total))
                    cv_n <= (NRAY * sum2) - (s_total * s_total);
                else
                    cv_n <= 64'd0;
                state <= S_CLASS_CMP;
            end
            S_CLASS_CMP: begin
                shape_cls_r <= shape_cls_n;
                state <= S_LTR_PREP;
            end
            S_LTR_PREP: begin
                ltr_bx0_b <= {1'b0,cbx0};
                ltr_bx1_b <= {1'b0,cbx1};
                ltr_by0_b <= {1'b0,cby0};
                ltr_by1_b <= {1'b0,cby1};
                ltr_lw_b  <= {4'd0,ltr_cw};
                ltr_lh_b  <= {4'd0,ltr_ch};
                ltr_span  <= {4'd0,ltr_span_c};
                ltr_xpad  <= {4'd0,ltr_xpad_c};
                ltr_ypad  <= {4'd0,ltr_ypad_c};
                ltr_gx    <= 4'd0;
                ltr_gy    <= 4'd0;
                ltr_work  <= 16'd0;
                ltr_sub   <= 3'd0;
                ltr_wx0   <= ltr_wx0_c[8:0];
                ltr_wx1   <= ltr_wx1_c[8:0];
                ltr_wy0   <= ltr_wy0_c[8:0];
                ltr_wy1   <= ltr_wy1_c[8:0];
                ltr_pbx   <= ltr_wx0_c[8:0];
                ltr_pby   <= ltr_wy0_c[8:0];
                ltr_tx0   <= 9'h1FF;
                ltr_tx1   <= 9'd0;
                ltr_ty0   <= 9'h1FF;
                ltr_ty1   <= 9'd0;
                ltr_fill  <= 16'd0;
                ltr_scan  <= 16'd0;
                state     <= S_LTR_BBOX;
            end
            S_LTR_BBOX: begin
                ltr_rd_addr <= {ltr_pby, ltr_pbx};
                ltr_rd_ok   <= 1'b1;
                ltr_fg_seen <= 1'b0;
                ltr_fg_x    <= ltr_wx0;
                ltr_fg_y    <= ltr_wy0;
                state       <= S_LTR_BWAIT;
            end
            S_LTR_BWAIT: begin
                state <= S_LTR_BCHK;
            end
            S_LTR_BCHK: begin
                ltr_scan <= ltr_scan + 16'd1;
                if (ltr_bm_q & ltr_ok_q) begin
                    ltr_fill <= ltr_fill + 16'd1;
                    if (!ltr_fg_seen) begin
                        ltr_fg_seen <= 1'b1;
                        ltr_fg_x    <= ltr_pbx;
                        ltr_fg_y    <= ltr_pby;
                    end
                    if (ltr_pbx < ltr_tx0) ltr_tx0 <= ltr_pbx;
                    if (ltr_pbx > ltr_tx1) ltr_tx1 <= ltr_pbx;
                    if (ltr_pby < ltr_ty0) ltr_ty0 <= ltr_pby;
                    if (ltr_pby > ltr_ty1) ltr_ty1 <= ltr_pby;
                end
                if ((ltr_pbx == ltr_wx1) && (ltr_pby == ltr_wy1)) begin
                    state <= S_LTR_BDONE;
                end else begin
                    if (ltr_pbx == ltr_wx1) begin
                        ltr_pbx <= ltr_wx0;
                        ltr_pby <= ltr_pby + 9'd1;
                        ltr_rd_addr <= {ltr_pby + 9'd1, ltr_wx0};
                    end else begin
                        ltr_pbx <= ltr_pbx + 9'd1;
                        ltr_rd_addr <= {ltr_pby, ltr_pbx + 9'd1};
                    end
                    state <= S_LTR_BWAIT;
                end
            end
            S_LTR_BDONE: begin
                ltr_bx0_b <= {3'd0,ltr_tb_x0};
                ltr_bx1_b <= {3'd0,ltr_tb_x1};
                ltr_by0_b <= {3'd0,ltr_tb_y0};
                ltr_by1_b <= {3'd0,ltr_tb_y1};
                ltr_lw_b  <= ltr_tb_w;
                ltr_lh_b  <= ltr_tb_h;
                ltr_span  <= ltr_tb_span;
                ltr_xpad  <= ltr_tb_xpad;
                ltr_ypad  <= ltr_tb_ypad;
                ltr_gx    <= 4'd0;
                ltr_gy    <= 4'd0;
                ltr_work  <= 16'd0;
                ltr_sub   <= 3'd0;
                edg_x      <= ltr_tb_x0;
                edg_y      <= ltr_tb_y0;
                edg_runs_t <= 2'd0; edg_runs_b <= 2'd0;
                edg_runs_l <= 2'd0; edg_runs_r <= 2'd0;
                edg_ink_t  <= 8'd0; edg_ink_b  <= 8'd0;
                edg_ink_l  <= 8'd0; edg_ink_r  <= 8'd0;
                edg_in_t   <= 1'b0; edg_in_b   <= 1'b0;
                edg_in_l   <= 1'b0; edg_in_r   <= 1'b0;
                edg_c_q1   <= 1'b0; edg_c_q3   <= 1'b0;
                for (sii = 0; sii < 4; sii = sii + 1) begin
                    seg_t[sii] <= 8'd0; seg_b[sii] <= 8'd0;
                    seg_l[sii] <= 8'd0; seg_r[sii] <= 8'd0;
                end
                state <= S_EDG_INIT;
            end
            S_EDG_INIT: begin
                ltr_rd_addr <= {edg_y, edg_x};
                ltr_rd_ok   <= 1'b1;
                state       <= S_EDG_WAIT;
            end
            S_EDG_WAIT: begin
                state <= S_EDG_SAMP;
            end
            S_EDG_SAMP: begin
                // Top edge: how many separate ink runs, how much ink.
                if (edg_y == ltr_by0_b) begin
                    if (ltr_bm_q & ltr_ok_q) begin
                        if (edg_ink_t != 8'd255) edg_ink_t <= edg_ink_t + 8'd1;
                        if (seg_t[edg_xseg] != 8'd255)
                            seg_t[edg_xseg] <= seg_t[edg_xseg] + 8'd1;
                        if (!edg_in_t) begin
                            edg_in_t <= 1'b1;
                            if (edg_runs_t != 2'd3) edg_runs_t <= edg_runs_t + 2'd1;
                        end
                    end else edg_in_t <= 1'b0;
                end
                // Bottom edge.
                if (edg_y == ltr_by1_b) begin
                    if (ltr_bm_q & ltr_ok_q) begin
                        if (edg_ink_b != 8'd255) edg_ink_b <= edg_ink_b + 8'd1;
                        if (seg_b[edg_xseg] != 8'd255)
                            seg_b[edg_xseg] <= seg_b[edg_xseg] + 8'd1;
                        if (!edg_in_b) begin
                            edg_in_b <= 1'b1;
                            if (edg_runs_b != 2'd3) edg_runs_b <= edg_runs_b + 2'd1;
                        end
                    end else edg_in_b <= 1'b0;
                end
                // Left edge.
                if (edg_x == ltr_bx0_b) begin
                    if (ltr_bm_q & ltr_ok_q) begin
                        if (edg_ink_l != 8'd255) edg_ink_l <= edg_ink_l + 8'd1;
                        if (seg_l[edg_yseg] != 8'd255)
                            seg_l[edg_yseg] <= seg_l[edg_yseg] + 8'd1;
                        if (!edg_in_l) begin
                            edg_in_l <= 1'b1;
                            if (edg_runs_l != 2'd3) edg_runs_l <= edg_runs_l + 2'd1;
                        end
                    end else edg_in_l <= 1'b0;
                end
                // Right edge.
                if (edg_x == ltr_bx1_b) begin
                    if (ltr_bm_q & ltr_ok_q) begin
                        if (edg_ink_r != 8'd255) edg_ink_r <= edg_ink_r + 8'd1;
                        if (seg_r[edg_yseg] != 8'd255)
                            seg_r[edg_yseg] <= seg_r[edg_yseg] + 8'd1;
                        if (!edg_in_r) begin
                            edg_in_r <= 1'b1;
                            if (edg_runs_r != 2'd3) edg_runs_r <= edg_runs_r + 2'd1;
                        end
                    end else edg_in_r <= 1'b0;
                end
                // T/Y discriminator on the upper part of the centre column.
                if (edg_x == edg_mid_x) begin
                    if (edg_y == edg_quarter_y) edg_c_q1 <= ltr_bm_q & ltr_ok_q;
                    if (edg_y == edg_three8_y)  edg_c_q3 <= ltr_bm_q & ltr_ok_q;
                end
                if ((edg_x == ltr_bx1_b) && (edg_y == ltr_by1_b)) begin
                    state <= S_EDG_DONE;
                end else begin
                    if (edg_x == ltr_bx1_b) begin
                        edg_x <= ltr_bx0_b;
                        edg_y <= edg_y + 9'd1;
                    end else begin
                        edg_x <= edg_x + 9'd1;
                    end
                    state <= S_EDG_INIT;
                end
            end
            S_EDG_DONE: begin
                edg_q_t <= cov8(edg_ink_t, ltr_tb_w[8:0]);
                edg_q_b <= cov8(edg_ink_b, ltr_tb_w[8:0]);
                edg_q_l <= cov8(edg_ink_l, ltr_tb_h[8:0]);
                edg_q_r <= cov8(edg_ink_r, ltr_tb_h[8:0]);
                edg_seg_t <= segmask4(seg_t[0], seg_t[1], seg_t[2], seg_t[3],
                                      edg_xq1, edg_xq2 - edg_xq1,
                                      edg_xq3 - edg_xq2, edg_w9 - edg_xq3);
                edg_seg_b <= segmask4(seg_b[0], seg_b[1], seg_b[2], seg_b[3],
                                      edg_xq1, edg_xq2 - edg_xq1,
                                      edg_xq3 - edg_xq2, edg_w9 - edg_xq3);
                edg_seg_l <= segmask4(seg_l[0], seg_l[1], seg_l[2], seg_l[3],
                                      edg_yq1, edg_yq2 - edg_yq1,
                                      edg_yq3 - edg_yq2, edg_h9 - edg_yq3);
                edg_seg_r <= segmask4(seg_r[0], seg_r[1], seg_r[2], seg_r[3],
                                      edg_yq1, edg_yq2 - edg_yq1,
                                      edg_yq3 - edg_yq2, edg_h9 - edg_yq3);
                crn_valid <= 1'b0;
                crn_conv  <= 6'd0;
                crn_conc  <= 6'd0;
                crn_steps <= 11'd0;
                crn_sx    <= ltr_fg_seen ? ltr_fg_x : ltr_tb_x0;
                crn_sy    <= ltr_fg_seen ? ltr_fg_y : ltr_tb_y0;
                crn_x     <= ltr_fg_seen ? ltr_fg_x : ltr_tb_x0;
                crn_y     <= ltr_fg_seen ? ltr_fg_y : ltr_tb_y0;
                crn_back_dir  <= 3'd4;
                crn_dir       <= 3'd5;
                crn_prev_dir  <= 3'd0;
                crn_first_dir <= 3'd0;
                crn_try       <= 3'd0;
                crn_started   <= 1'b0;
                state <= S_CRN_INIT;
            end
            S_CRN_INIT: begin
                // Start at the top-left foreground block.  The pixel to its
                // west is outside the shape, so the Moore backtrack starts west
                // and the first probe is north-west.
                if (!ltr_fg_seen || (ltr_tb_span < 3)) begin
                    crn_valid <= 1'b0;
                    state     <= S_CRN_DONE;
                end else begin
                    crn_x       <= crn_sx;
                    crn_y       <= crn_sy;
                    crn_back_dir <= 3'd4;
                    crn_dir      <= 3'd5;
                    crn_try      <= 3'd0;
                    crn_prev_dir <= 3'd0;
                    crn_first_dir <= 3'd0;
                    crn_started  <= 1'b0;
                    crn_steps    <= 11'd0;
                    state        <= S_CRN_PROBE;
                end
            end
            S_CRN_PROBE: begin
                crn_addr  <= crn_addr_n;
                crn_rd_ok <= crn_inb_n;
                crn_nx    <= crn_nxs[8:0];
                crn_ny    <= crn_nys[8:0];
                state     <= S_CRN_WAIT;
            end
            S_CRN_WAIT: begin
                state <= S_CRN_TEST;
            end
            S_CRN_TEST: begin
                if (crn_bm_q && crn_rd_ok) begin
                    if (crn_started) begin
                        case ((crn_dir - crn_prev_dir) & 3'd7)
                        3'd2, 3'd3: if (crn_conv != 6'd63) crn_conv <= crn_conv + 6'd1;
                        3'd6, 3'd7: if (crn_conc != 6'd63) crn_conc <= crn_conc + 6'd1;
                        default: ;
                        endcase
                    end else begin
                        crn_first_dir <= crn_dir;
                        crn_started   <= 1'b1;
                    end
                    if (crn_started && (crn_nx == crn_sx) &&
                        (crn_ny == crn_sy) && (crn_steps > 11'd4)) begin
                        crn_valid <= 1'b1;
                        state     <= S_CRN_DONE;
                    end else if (crn_steps >= 11'd2047) begin
                        crn_valid <= 1'b0;
                        state     <= S_CRN_DONE;
                    end else begin
                        crn_x        <= crn_nx;
                        crn_y        <= crn_ny;
                        crn_back_dir <= (crn_dir + 3'd4) & 3'd7;
                        crn_dir      <= (crn_dir + 3'd5) & 3'd7;
                        crn_prev_dir <= crn_dir;
                        crn_try      <= 3'd0;
                        crn_steps    <= crn_steps + 11'd1;
                        state        <= S_CRN_PROBE;
                    end
                end else if (crn_try == 3'd7) begin
                    crn_valid <= (crn_steps >= 11'd8);
                    state     <= S_CRN_DONE;
                end else begin
                    crn_try <= crn_try + 3'd1;
                    crn_dir <= (crn_back_dir + 3'd1 + crn_try + 3'd1) & 3'd7;
                    state   <= S_CRN_PROBE;
                end
            end
            S_CRN_DONE: begin
                // F53: always run the 32-ray ink-segment scan.  It feeds both
                // the geometry waveform and the letter templates.
                state <= S_LTR_DEC;
            end
            S_LTR_DEC: begin
                // Start the 32-angle x 16-radius ink-segment scan.
                rng_k          <= 4'd0;
                rng_a          <= 5'd0;
                pro_start      <= 4'd15;
                pro_end        <= 4'd15;
                pro_runs       <= 2'd0;
                pro_prev       <= 1'b0;
                pro_seen       <= 1'b0;
                pro_solid_cnt  <= 6'd0;
                for (pii = 0; pii < 16; pii = pii + 1)
                    ring_ink[pii] <= 6'd0;
                rng_tmpl       <= 10'd0;
                rng_idx        <= 9'd0;
                rng_var        <= 5'd0;
                rng_best       <= 12'hFFF;
                rng_second     <= 12'hFFF;
                rng_best_raw   <= 12'hFFF;
                rng_second_raw <= 12'hFFF;
                rng_best_bad   <= 6'd63;
                rng_second_bad <= 6'd63;
                rng_best_idx   <= 5'd0;
                rng_second_idx <= 5'd0;
                ray_a          <= 6'd0;
                ray_bad        <= 6'd0;
                state          <= S_PRO_REQ;
            end
            S_PRO_REQ: begin
                rng_r8_q  <= rng_r8;
                rng_cx_q  <= pro_cx8;
                rng_cy_q  <= pro_cy8;
                rng_cos_q <= rng_cos;
                rng_sin_q <= rng_sin;
                state     <= S_PRO_CALC;
            end
            S_PRO_CALC: begin
                rng_dx_q <= ($signed({1'b0, rng_r8_q}) * $signed(rng_cos_q)) >>> 8;
                rng_dy_q <= ($signed({1'b0, rng_r8_q}) * $signed(rng_sin_q)) >>> 8;
                state    <= S_PRO_ADDR;
            end
            S_PRO_ADDR: begin
                rng_rd_addr <= pro_addr_n;
                rng_rd_ok   <= rng_in_b;
                state       <= S_PRO_WAIT;
            end
            S_PRO_WAIT: begin
                state <= S_PRO_ACC;
            end
            S_PRO_ACC: begin
                if (rng_k == 4'd15) begin
                    pro_meas[rng_a[4:0]] <= pro_word_n;
                    // Transpose the completed ray into the per-radius ink
                    // coverage counters.  This is derived from the same ray
                    // samples, not from a second circular scan.
                    for (pii = 0; pii < 16; pii = pii + 1)
                        if (pro_seen_n && (pro_start_n <= pii) &&
                            (pro_end_n >= pii))
                            ring_ink[pii] <= ring_ink[pii] + 6'd1;
                    if (pro_solid_n)
                        pro_solid_cnt <= pro_solid_cnt + 6'd1;
                    pro_start <= 4'd15;
                    pro_end   <= 4'd15;
                    pro_runs  <= 2'd0;
                    pro_prev  <= 1'b0;
                    pro_seen  <= 1'b0;
                    rng_k     <= 4'd0;
                    if (rng_a == 5'd31) begin
                        if (LETTER_EN &&
                            (ltr_span_c >= (LETTER_MIN_BBOX/4)) &&
                            (bw_l >= 16'd12) && (bh_l >= 16'd12))
                            state <= S_RAY_REQ;
                        else
                            state <= S_RNG_DEC;
                    end else begin
                        rng_a <= rng_a + 5'd1;
                        state <= S_PRO_REQ;
                    end
                end else begin
                    pro_start <= pro_start_n;
                    pro_end   <= pro_end_n;
                    pro_runs  <= pro_runs_n;
                    pro_prev  <= pro_hit;
                    pro_seen  <= pro_seen_n;
                    rng_k     <= rng_k + 4'd1;
                    state     <= S_PRO_REQ;
                end
            end
            S_RAY_REQ: begin
                ray_rd_addr <= ray_rom_addr;
                state       <= S_RAY_RD;
            end
            S_RAY_RD: begin
                ray_rom_q <= ray_rom[ray_rd_addr];
                state     <= S_RAY_ACC;
            end
            S_RAY_ACC: begin
                ray_bad <= ray_bad_n;
                if (ray_a == 6'd31) begin
                    state    <= S_RAY_DONE;
                end else begin
                    ray_a <= ray_a + 6'd1;
                    state <= S_RAY_REQ;
                end
            end
            S_RAY_DONE: begin
                ray_a <= 6'd0;
                ray_bad <= 6'd0;
                if (ray_score < rng_best) begin
                    rng_second      <= rng_best;
                    rng_second_raw  <= rng_best_raw;
                    rng_second_idx  <= rng_best_idx;
                    rng_best        <= ray_score;
                    rng_best_raw    <= ray_score;
                    rng_best_bad    <= ray_bad;
                    rng_second_bad  <= rng_best_bad;
                    rng_best_idx    <= rng_idx[4:0];
                end else if (ray_score < rng_second) begin
                    rng_second      <= ray_score;
                    rng_second_raw  <= ray_score;
                    rng_second_bad  <= ray_bad;
                    rng_second_idx  <= rng_idx[4:0];
                end
                if (rng_var == (RNG_NVAR-1)) begin
                    rng_var  <= 5'd0;
                    rng_tmpl <= rng_tmpl + 10'd1;
                    if (rng_idx == 9'd25) begin
                        state <= S_RNG_DEC;
                    end else begin
                        rng_idx <= rng_idx + 9'd1;
                        state   <= S_RAY_REQ;
                    end
                end else begin
                    rng_var  <= rng_var + 5'd1;
                    rng_tmpl <= rng_tmpl + 10'd1;
                    state    <= S_RAY_REQ;
                end
            end
            S_RNG_DEC: begin
                // F53 decision: solid ink segments lock geometry, otherwise
                // the 32-ray letter templates decide.
                if (ray_geo_lock)
                    o_cls <= shape_cls_g;
                else if (solid_geo && (solid_cls != 5'd0))
                    o_cls <= solid_cls;
                else if ((rng_best_idx == 5'd14) && (rng_band_cnt < 5'd3) &&
                         (shape_cls_g == 5'd1))
                    // Thin printed ring: the ray templates call it O, but a
                    // real O is a thick annulus with many inked radii.
                    o_cls <= 5'd1;
                else if ((rng_best_bad <= RAY_BAD_MAX) && !hollow_box &&
                         (rng_second_raw >= (rng_best_raw + RAY_MARGIN)))
                    o_cls <= left_foot_full && (rng_best_idx == 5'd2) ? 5'd17 :
                             (top_bar_full || centre_stem_top) &&
                             ((rng_best_idx == 5'd24) ||
                              (rng_best_idx == 5'd19)) ? 5'd25 :
                             rng_letter_cls;
                else if (LETTER_SIG_EN && ltr_sig_ok)
                    o_cls <= 5'd6 + ltr_best_idx;
                else if (seg_rect_strong && cov_ok && solid_aspect_ok &&
                         letter_weak)
                    o_cls <= crn_near_square ? 5'd2 : 5'd5;
                else if (geo_edge_ok && (shape_cls_g != 5'd0))
                    o_cls <= shape_cls_g;
                else
                    o_cls <= 5'd0;
                state <= S_OUT;
            end
            S_DROP: begin
                o_cls <= 5'd0;
                state <= S_OUT;
            end
            S_OUT: begin
                o_upd <= 1'b1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end

    assign o_blk_cov  = blk_cnt_l;
    assign o_blk_bx0  = blk_bx0_l;
    assign o_blk_bx1  = blk_bx1_l;
    assign o_blk_by0  = blk_by0_l;
    assign o_blk_by1  = blk_by1_l;
    assign o_dbg_cov  = cov;
    assign o_dbg_rmin = rmin;
    assign o_dbg_s    = s_total;

endmodule
