//==============================================================================
// tb_p0_fill.v —— P0-2 定向复现/证明：fill_ok 位宽
//
//   直接驱动 fill 比较器的两个输入寄存器（s_area, bwbh_r），逐点对拍
//   精确大整数真值：   fill_ok  ==  ( 16*A*1024 >= 297*bw*bh )
//                     即 16384*s_area >= 297*bwbh_r
//
//   case 1: bbox 边 n = 300..1400（正方形），A = min(n*n/16, 65530)（实心填充）
//   case 2: 同样的 bbox，A 取临界值附近（floor(297*bwbh/16384) 与 +1）
//   case 3: 若干大 bbox 矩形（1800x1000 / 1400x1080 / 1920x1080）
//
//   改前（27bit 左移）：n=363..429 左右两边回绕点不同 → 400x400 得 0
//   改后（34bit 扩展）  ：全部与真值一致
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -s tb_p0_fill -o sim/tb_p0_fill.vvp \
//              sim/tb_p0_fill.v rtl/edge/shape_recog.v
//     vvp sim/tb_p0_fill.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_p0_fill;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        i_de = 1'b0;
    reg        i_vs = 1'b0;
    reg  [7:0] i_g0 = 8'd0;
    reg  [7:0] i_g1 = 8'd0;

    wire [1:0]  o_cls;
    wire        o_upd;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire        o_box_en;
    wire [3:0]  o_best_idx;
    wire [13:0] o_best_cnt;

    shape_recog #(
        .H_PAIRS (4),
        .V_LINES (4)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_de       (i_de),
        .i_vs       (i_vs),
        .i_g0       (i_g0),
        .i_g1       (i_g1),
        .o_cls      (o_cls),
        .o_upd      (o_upd),
        .o_bx0      (o_bx0),
        .o_bx1      (o_bx1),
        .o_by0      (o_by0),
        .o_by1      (o_by1),
        .o_box_en   (o_box_en),
        .o_best_idx (o_best_idx),
        .o_best_cnt (o_best_cnt)
    );

    integer cases = 0;
    integer errs  = 0;
    integer old_mismatch = 0;      // 27bit 旧表达式的失配数（仅用于报告）
    integer n;
    longint aa, bb, lhs, rhs, a_lo, a_hi, prod;
    longint old_l, old_r;
    reg     exp_fill;

    // 打一拍后检查 fill_ok_r 是否等于精确真值
    task probe;
        input longint a_in;
        input longint bwbh_in;
        begin
            force dut.s_area = a_in[15:0];
            force dut.bwbh_r = bwbh_in[23:0];
            @(posedge clk); #1;
            lhs = 64'd16384 * a_in;
            rhs = 64'd297   * bwbh_in;
            exp_fill = (lhs >= rhs);
            cases = cases + 1;

            // 旧 27bit 表达式（左移/移位加后各自按 27bit 回绕）
            old_l = ((64'd16384 * a_in) & 64'h7FFFFFF);
            old_r = ((64'd297   * bwbh_in) & 64'h7FFFFFF);
            if ((old_l >= old_r) !== exp_fill) old_mismatch = old_mismatch + 1;

            if (dut.fill_ok_r !== exp_fill) begin
                errs = errs + 1;
                if (errs <= 10)
                    $display("  MISMATCH a=%0d bwbh=%0d  got=%b exp=%b  (lhs=%0d rhs=%0d)",
                             a_in, bwbh_in, dut.fill_ok_r, exp_fill, lhs, rhs);
            end
            release dut.s_area;
            release dut.bwbh_r;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (3) begin @(posedge clk); #1; end

        $display("");
        $display("======================================================================");
        $display(" P0-2  fill_ok arithmetic sweep (exact 64-bit golden)");
        $display("======================================================================");

        // ---- case 1: bbox 边 300..1400，实心填充 A = min(n^2/16, 65530) ----
        $display(" [1] bbox edge 300..1400, solid fill A=min(n*n/16,65530)");
        for (n = 300; n <= 1400; n = n + 1) begin
            bb = n * n;
            aa = bb >> 4;
            if (aa > 65530) aa = 65530;
            probe(aa, bb);
        end
        $display("     done: cases=%0d errors=%0d legacy27_mismatch=%0d", cases, errs, old_mismatch);

        // 400x400 细节（用户报告的那一点）
        aa = (400*400) >> 4;   // 10000
        bb = 400*400;          // 160000
        probe(aa, bb);
        $display("     400x400: A=%0d bw*bh=%0d  lhs=16384*A=%0d rhs=297*bw*bh=%0d  fill_ok=%b",
                 aa, bb, 64'd16384*aa, 64'd297*bb, dut.fill_ok_r);
        $display("               legacy27: lhs27=%0d rhs27=%0d -> %b (true=1)",
                 ((64'd16384*aa) & 64'h7FFFFFF), ((64'd297*bb) & 64'h7FFFFFF),
                 ((((64'd16384*aa) & 64'h7FFFFFF) >= ((64'd297*bb) & 64'h7FFFFFF))));

        // ---- case 2: 临界点附近（A_lo = floor(297*bwbh/16384)，A_lo/A_lo+1） ----
        $display(" [2] same bbox, A around threshold floor(297*bwbh/16384) and +1");
        for (n = 300; n <= 1400; n = n + 1) begin
            bb = n * n;
            prod = 64'd297 * bb;
            a_lo = prod / 64'd16384;
            a_hi = a_lo + 1;
            if (a_lo <= 65535) probe(a_lo, bb);
            if (a_hi <= 65535) probe(a_hi, bb);
        end
        $display("     done: cases=%0d errors=%0d legacy27_mismatch=%0d", cases, errs, old_mismatch);

        // ---- case 3: 大 bbox 矩形（rhs 接近最大值） ----
        $display(" [3] large rectangles");
        probe(65530, 1800*1000);
        probe(65530, 1400*1080);
        probe(65530, 1920*1080);
        probe(1,     1920*1080);
        probe(0,     1920*1080);
        $display("     done: cases=%0d errors=%0d legacy27_mismatch=%0d", cases, errs, old_mismatch);

        $display("----------------------------------------------------------------------");
        $display(" P0-2 summary: cases=%0d  mismatches=%0d  (legacy 27bit would mismatch %0d)",
                 cases, errs, old_mismatch);
        if (errs == 0) $display(" P0-2 RESULT: PASS");
        else           $display(" P0-2 RESULT: FAIL");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
