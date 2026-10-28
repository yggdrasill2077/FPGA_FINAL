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
//  Output classes (kept compatible with shape_osd):
//    1 circle, 2 square, 3 triangle, 4 cross, 5 rectangle, 0 unknown
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
    parameter integer CAND_MODE = 0   // 1: candidate bbox/moments supplied by
                                      //    shape_grid_multi; i_area is the
                                      //    4x4 block count of this candidate.
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
    output reg  [2:0]  o_cls,
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

    reg bm_wr_q;
    always @(posedge clk) bm_wr_q <= bm[wr_addr];

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
    wire        blk_hit     = bm_wr_q | fg_any;
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
    wire [6:0] feat_idx_n = (k + 7'd1) & 7'h7F;
    wire [6:0] trig_idx_f = (pass[2:0] * k[6:0]) & 7'h7F;
    wire [7:0] rq = rram[feat_idx_n];
    wire [17:0] trig_feat = trig_rom[trig_idx_f];
    wire signed [8:0] cos_feat = trig_feat[8:0];
    wire signed [8:0] sin_feat = trig_feat[17:9];

    //--------------------------------------------------------------------------
    // Control / snapshot
    //--------------------------------------------------------------------------
    reg [4:0] state;
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
    reg [7:0]  rmax, ev_r, last_r, gap_cnt;
    reg        ev_inb, seen;
    reg [17:0] map_addr;
    reg [7:0]  cov;

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

    reg  [7:0] bm_q;
    always @(posedge clk) begin
        bm_q <= bm[map_addr];
    end

    // Candidate mode: the shared 4x4 block map still contains every object in
    // the frame. Restrict every ray to the candidate bbox so a neighbouring
    // object cannot become this candidate's outer contour.
    wire [10:0] cbx0 = bx0_l >> BLK_SHIFT;
    wire [10:0] cbx1 = bx1_l >> BLK_SHIFT;
    wire [10:0] cby0 = by0_l >> BLK_SHIFT;
    wire [10:0] cby1 = by1_l >> BLK_SHIFT;
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

    wire [7:0] rm = med3(ra, rb, rq);
    wire signed [17:0] mul_c = $signed({1'b0, rm}) * $signed(cos_feat);
    wire signed [17:0] mul_s = $signed({1'b0, rm}) * $signed(sin_feat);
    wire [15:0] rm2 = rm * rm;

    //--------------------------------------------------------------------------
    // Harmonic energies and final thresholds
    //--------------------------------------------------------------------------
    reg [63:0] e2, e3, e4, sq_s, cv_n;
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
    // 4x4 block quantization and real lens/edge noise perturb the radius by
    // roughly 5-10%; a 8% gate rejects valid circles. 10% still keeps the
    // square's A4 signature (lowest observed CV ~1.26%) out of this branch.
    wire circle_hit=(cv_s < (sq_s * 64'd100));
    wire cov_ok   = (cov >= COV_MIN) && (s_total != 16'd0);

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
                           (fill_lhs >= (map_blocks * 232)) &&
                           (e4 > e2) && (e4 > e3);
    wire fill_circle_hit = small_target && near_square &&
                           (fill_lhs >= (map_blocks * 144)) &&
                           (fill_lhs <= (map_blocks * 216)) &&
                           (e4 > e2) && (e4 > e3);
    wire fill_ring_hit   = small_target && near_square &&
                           (fill_lhs < (map_blocks * 112)) &&
                           (e4 > e2) && (e4 > e3);

    //--------------------------------------------------------------------------
    // Main FSM
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            o_cls <= 3'd0; o_upd <= 1'b0;
            area_l <= 16'd0; sx_l <= 27'd0; sy_l <= 27'd0;
            bx0_l <= 11'h7FF; bx1_l <= 11'd0; by0_l <= 11'h7FF; by1_l <= 11'd0;
            valid_l <= 1'b0;
            div_num <= 30'd0; div_rem <= 16'd0; div_q <= 16'd0;
            div_cnt <= 5'd0; area_q <= 16'd0; cxq <= 16'd0; cyq <= 16'd0;
            cent_blk <= 1'b0;
            cx_fp <= 20'd0; cy_fp <= 20'd0; xf <= 20'd0; yf <= 20'd0;
            cos_r <= 9'd0; sin_r <= 9'd0;
            ray <= 8'd0; rmax <= 8'd0; ev_r <= 8'd0; last_r <= 8'd0; gap_cnt <= 8'd0;
            ev_inb <= 1'b0; seen <= 1'b0; map_addr <= 18'd0; cov <= 8'd0;
            pass <= 3'd0; k <= 7'd0; ra <= 8'd0; rb <= 8'd0;
            csum <= 24'sd0; ssum <= 24'sd0;
            c2 <= 24'sd0; s2 <= 24'sd0; c3 <= 24'sd0; s3 <= 24'sd0;
            c4 <= 24'sd0; s4 <= 24'sd0;
            s_total <= 16'd0; sum2 <= 32'd0; rmin <= 8'hFF;
            e2 <= 64'd0; e3 <= 64'd0; e4 <= 64'd0; sq_s <= 64'd0; cv_n <= 64'd0;
            bbox_w <= 16'd0; bbox_h <= 16'd0; bbox_max <= 16'd0;
        end else begin
            o_upd <= 1'b0;
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
                gap_cnt <= 8'd0;
                seen <= 1'b0;
                state <= S_REQ;
            end
            S_REQ: begin
                state <= S_EVAL;
            end
            S_EVAL: begin
                if (hit_now) begin
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
                if (!cov_ok) begin
                    o_cls <= 3'd0;
                end else if (rect_hit) begin
                    o_cls <= 3'd5;
                end else if (tri_hit) begin
                    o_cls <= 3'd3;
                end else if (cross_hit) begin
                    o_cls <= 3'd4;
                end else if (fill_square_hit) begin
                    o_cls <= 3'd2;
                end else if (fill_circle_hit || fill_ring_hit) begin
                    o_cls <= 3'd1;
                end else if (square_hit) begin
                    o_cls <= 3'd2;
                end else if (circle_hit) begin
                    o_cls <= 3'd1;
                end else begin
                    o_cls <= 3'd0;
                end
                state <= S_OUT;
            end
            S_DROP: begin
                o_cls <= 3'd0;
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
