
`timescale 1ns/1ps
// Shape sweep: grid candidate -> polar/letter classifier.
// 4 classes x 3 sizes x filled/hollow, on a 640x240 canvas.
module tb_shape_sweep;
    localparam integer HP = 320;
    localparam integer VL = 240;
    localparam integer W  = 640;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;

    wire [2:0] g_num;
    wire [3:0] g_valid;
    wire [63:0] g_area;
    wire [107:0] g_sx, g_sy;
    wire [43:0] g_bx0, g_bx1, g_by0, g_by1;
    wire g_done;

    wire [4:0] p_cls;
    wire p_upd;
    wire [7:0] p_cov, p_rmin;
    wire [15:0] p_s;

    reg [26:0] sel_sx, sel_sy;
    reg [15:0] sel_area;
    reg [10:0] sel_bx0, sel_bx1, sel_by0, sel_by1;
    reg i_start;

    shape_grid_multi_v2 #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(32), .GRID_Y(18),
        .CELL_SEED_MIN(4), .CELL_MERGE_MIN(1),
        .MIN_AREA(12), .MIN_BBOX(6), .FILL_MIN(8), .MERGE_GAP(1),
        .MAX_BBOX_W(1800), .MAX_BBOX_H(1000)
    ) u_grid (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170),
        .i_gate_en(1'b0), .i_gx0(11'd0), .i_gx1(11'd0),
        .i_gy0(11'd0), .i_gy1(11'd0),
        .o_num(g_num), .o_valid(g_valid),
        .o_bx0(g_bx0), .o_bx1(g_bx1), .o_by0(g_by0), .o_by1(g_by1),
        .o_sx(g_sx), .o_sy(g_sy), .o_area(g_area), .o_done(g_done)
    );

    shape_polar #(
        .H_PAIRS(HP), .V_LINES(VL), .BLK_SHIFT(2), .NRAY(128),
        .GAP_TOL(3), .MIN_AREA(8), .MIN_BBOX(16), .COV_MIN(80),
        .CAND_MODE(1), .LETTER_EN(1), .LETTER_MIN_BBOX(56),
        .LETTER_THAM(26), .LETTER_MARGIN(4),
        .LETTER_SIG_EN(0), .RING_EN(1),
        .RING_THAM(56), .RING_MARGIN(10)
    ) u_polar (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_start(i_start), .i_roi(1'b1), .i_g0(i_g0), .i_g1(i_g1),
        .i_ty(8'd170),
        .i_sx(sel_sx), .i_sy(sel_sy), .i_area(sel_area),
        .i_bx0(sel_bx0), .i_bx1(sel_bx1), .i_by0(sel_by0), .i_by1(sel_by1),
        .i_valid(1'b1),
        .o_cls(p_cls), .o_upd(p_upd),
        .o_blk_cov(), .o_blk_bx0(), .o_blk_bx1(), .o_blk_by0(), .o_blk_by1(),
        .o_dbg_cov(p_cov), .o_dbg_rmin(p_rmin), .o_dbg_s(p_s)
    );

    integer r, c, k, n, errs, sel, idx, kind, size, hollow, exp_cls;
    integer ki, si, hi;
    integer cx, cy, R, half, bw, bh;

    // kind: 0 circle, 1 square, 2 triangle, 3 rect, 4 cross
    function in_shape(input integer x, input integer y);
        integer dx, dy, half_t;
        begin
            dx = x - cx; dy = y - cy;
            case (kind)
            0: in_shape = (dx*dx + dy*dy <= R*R);
            1: in_shape = (dx >= -R) && (dx <= R) && (dy >= -R) && (dy <= R);
            2: begin
                   // apex up at cy-R, base at cy+R
                   if ((y < cy-R) || (y > cy+R)) in_shape = 1'b0;
                   else begin
                       half_t = (y - (cy-R)) * R / (2*R);
                       in_shape = (dx >= -half_t) && (dx <= half_t);
                   end
               end
            3: in_shape = (dx >= -R*3/2) && (dx <= R*3/2) && (dy >= -R*2/3) && (dy <= R*2/3);
            default: begin
                   in_shape = ((dx >= -R/3) && (dx <= R/3) && (dy >= -R) && (dy <= R)) ||
                              ((dy >= -R/3) && (dy <= R/3) && (dx >= -R) && (dx <= R));
               end
            endcase
        end
    endfunction

    function shape_px(input integer x, input integer y);
        reg inner;
        begin
            inner = in_shape(x-6,y) && in_shape(x+6,y) && in_shape(x,y-6) && in_shape(x,y+6);
            if (hollow) shape_px = in_shape(x,y) && !inner;
            else        shape_px = in_shape(x,y);
        end
    endfunction

    task send_frame;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = shape_px(2*c,   r) ? 8'd40 : 8'd255;
                    i_g1 = shape_px(2*c+1, r) ? 8'd40 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0;
                repeat (20) @(negedge clk);
            end
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            repeat (5) @(negedge clk);
        end
    endtask

    task select_candidate;
        begin
            sel = 0;
            for (k = 3; k >= 0; k = k - 1)
                if (g_valid[k]) sel = k;
            sel_area = g_area[16*sel +: 16];
            sel_sx   = g_sx[27*sel +: 27];
            sel_sy   = g_sy[27*sel +: 27];
            sel_bx0  = g_bx0[11*sel +: 11];
            sel_bx1  = g_bx1[11*sel +: 11];
            sel_by0  = g_by0[11*sel +: 11];
            sel_by1  = g_by1[11*sel +: 11];
        end
    endtask

    task run_shape(input integer kk, input integer ss, input integer hh);
        begin
            kind = kk; size = ss; hollow = hh;
            case (size)
            0: R = 30;
            1: R = 45;
            default: R = 58;
            endcase
            cx = 320; cy = 120;
            case (kk)
            0: exp_cls = 1;
            1: exp_cls = 2;
            2: exp_cls = 3;
            3: exp_cls = 5;
            default: exp_cls = 4;
            endcase
            send_frame();
            n = 0;
            while (!g_done && n < 20000) begin @(posedge clk); #1; n = n + 1; end
            if (!g_done || g_num == 0) begin
                $display("SHAPE k=%0d R=%0d h=%0d NO CANDIDATE done=%0d num=%0d", kk, R, hh, g_done, g_num);
                errs = errs + 1;
            end else begin
                select_candidate();
                repeat (2) @(negedge clk);
                i_start = 1'b1;
                @(posedge clk); #1; i_start = 1'b0;
                n = 0;
                while (!p_upd && n < 200000) begin @(posedge clk); #1; n = n + 1; end
                if (!p_upd) begin
                    $display("SHAPE k=%0d R=%0d h=%0d TIMEOUT", kk, R, hh);
                    errs = errs + 1;
                end else begin
                    $display("SHAPE k=%0d R=%0d h=%0d cls=%0d exp=%0d ring=%0d/%0d second=%0d band=%0d fill=%0d tw=%0d th=%0d geo=%0d shape=%0d crn=%0d/%0d st=%0d edg T=%0d/%0d B=%0d/%0d L=%0d/%0d R=%0d/%0d",
                             kk, R, hh, p_cls, exp_cls,
                             u_polar.rng_best, u_polar.rng_best_idx, u_polar.rng_second,
                             u_polar.rng_band_cnt, u_polar.ltr_fill,
                             u_polar.pro_solid_cnt, u_polar.ltr_scan,
                             u_polar.geo_edge_ok, u_polar.shape_cls_r, u_polar.crn_conv, u_polar.crn_conc, u_polar.crn_steps,
                             u_polar.edg_runs_t, u_polar.edg_q_t, u_polar.edg_runs_b, u_polar.edg_q_b,
                             u_polar.edg_runs_l, u_polar.edg_q_l, u_polar.edg_runs_r, u_polar.edg_q_r);
                    if (p_cls !== exp_cls[4:0]) errs = errs + 1;
                end
            end
            repeat (8) @(negedge clk);
        end
    endtask

    initial begin
        errs = 0; i_start = 1'b0; i_vs = 1'b0; i_de = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        for (ki = 0; ki < 5; ki = ki + 1)
            for (si = 0; si < 3; si = si + 1)
                for (hi = 0; hi < 2; hi = hi + 1)
                    run_shape(ki, si, hi);
        $display("SHAPE SWEEP RESULT: %0d ERROR(S)", errs);
        $finish;
    end

    initial begin
        #400000000;
        $display("SHAPE SWEEP GLOBAL TIMEOUT");
        $finish;
    end
endmodule

