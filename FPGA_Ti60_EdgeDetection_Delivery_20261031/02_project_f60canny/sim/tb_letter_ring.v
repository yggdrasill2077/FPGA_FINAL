`timescale 1ns/1ps
// End-to-end letter probe: grid candidate -> shared polar/letter classifier.
module tb_letter_ring;
    localparam integer HP = 320;   // 640 px
    localparam integer VL = 240;
    localparam integer W  = 640;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;
    reg [7:0] img_all [0:26*W*VL-1];
    integer base;

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
        .CAND_MODE(1), .LETTER_EN(1), .LETTER_MIN_BBOX(72),
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

    integer r, c, k, n, errs, sel, exp, j;
    integer idx;

    task send_frame;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = img_all[base + r*W + 2*c];
                    i_g1 = img_all[base + r*W + 2*c + 1];
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

    task run_letter(input integer which, input integer expected_cls, input [7:0] lch);
        begin
            base = which * W * VL;
            send_frame();
            n = 0;
            while (!g_done && n < 20000) begin @(posedge clk); #1; n = n + 1; end
            if (!g_done) begin
                $display("LETTER %c GRID TIMEOUT", lch);
                errs = errs + 1;
            end else if (g_num == 0) begin
                $display("LETTER %c NO CANDIDATE", lch);
                errs = errs + 1;
            end else begin
                select_candidate();
                repeat (2) @(negedge clk);
                i_start = 1'b1;
                @(posedge clk); #1; i_start = 1'b0;
                n = 0;
                while (!p_upd && n < 100000) begin @(posedge clk); #1; n = n + 1; end
                if (!p_upd) begin
                    $display("LETTER %c CLASS TIMEOUT area=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                             lch, sel_area, sel_bx0, sel_by0, sel_bx1, sel_by1);
                    errs = errs + 1;
                end else begin
                    $display("LETTER %c cls=%0d expected=%0d cov=%0d cyc=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                             lch, p_cls, expected_cls, p_cov, n,
                             sel_bx0, sel_by0, sel_bx1, sel_by1);
                    $display("  shape=%0d", u_polar.shape_cls_r);
                    $display("  edg T=%0d/%0d B=%0d/%0d L=%0d/%0d R=%0d/%0d c=%b%b cost=%0d",
                             u_polar.edg_runs_t, u_polar.edg_q_t,
                             u_polar.edg_runs_b, u_polar.edg_q_b,
                             u_polar.edg_runs_l, u_polar.edg_q_l,
                             u_polar.edg_runs_r, u_polar.edg_q_r,
                             u_polar.edg_c_q1, u_polar.edg_c_q3,
                             u_polar.edg_cost);
                    $display("  ring_best=%0d idx=%0d second=%0d sidx=%0d bad=%0d/%0d fill=%0d/%0d solid=%0d",
                             u_polar.rng_best, u_polar.rng_best_idx,
                             u_polar.rng_second, u_polar.rng_second_idx,
                             u_polar.rng_best_bad, u_polar.rng_second_bad,
                             u_polar.ltr_fill, u_polar.ltr_scan,
                             u_polar.pro_solid_cnt);
                    $write("RING %c", lch);
                    for (j = 0; j < 16; j = j + 1)
                        $write(" %0d", u_polar.ring_ink[j]);
                    $write("\n");
                    $display("  tight2=(%0d,%0d)-(%0d,%0d) span2=%0d",
                             u_polar.ltr_bx0_b, u_polar.ltr_by0_b,
                             u_polar.ltr_bx1_b, u_polar.ltr_by1_b, u_polar.ltr_span);
                    $display("  tight=(%0d,%0d)-(%0d,%0d) span=%0d",
                             u_polar.ltr_bx0_b, u_polar.ltr_by0_b,
                             u_polar.ltr_bx1_b, u_polar.ltr_by1_b, u_polar.ltr_span);
                    if ($test$plusargs("dumpbm")) begin
                        for (j = 16; j < 44; j = j + 1) begin
                            $write("BM %0d ", j);
                            for (k = 64; k < 96; k = k + 1)
                                $write("%b", u_polar.bm[j*(HP/2)+k]);
                            $write("\n");
                        end
                    end
                    if (p_cls !== expected_cls[4:0]) begin
                        $display("  FAIL");
                        errs = errs + 1;
                    end
                end
            end
            repeat (8) @(negedge clk);
        end
    endtask

    initial begin
        errs = 0; i_start = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        $readmemh("sim/letter_all.hex", img_all);
        for (idx = 0; idx < 26; idx = idx + 1)
            run_letter(idx, 6 + idx, 8'd65 + idx);
        $display("LETTER RING-ONLY RESULT: %0d ERROR(S)", errs);
        $finish;
    end

    initial begin
        #200000000;
        $display("LETTER F36 GLOBAL TIMEOUT");
        $finish;
    end

endmodule
