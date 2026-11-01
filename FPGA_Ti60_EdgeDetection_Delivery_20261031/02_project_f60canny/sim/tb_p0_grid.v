//==============================================================================
// tb_p0_grid.v —— P0-1 定向复现：80×80 实心方块（白底黑目标）
//
//   240×160 小帧（H_PAIRS=120 / V_LINES=160），方块 x=80..159, y=40..119
//   1/16 采样（row%4==0 且 x0%4==0）→ A = 20×20 = 400 样本
//   期望：gcnt[0] = 400, best_cnt = 400 (>150 → cell_ok=1), o_cls = 2 (矩形)
//
//   改前（scan_k==17 每拍清零）：gcnt[0]=0 → best_cnt=0 → cell_ok=0 → o_cls=0
//   改后（scan_clear_pulse 单拍）：gcnt[0]=400 → best_cnt=400 → o_cls=2
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -s tb_p0_grid -o sim/tb_p0_grid.vvp \
//              sim/tb_p0_grid.v rtl/edge/shape_recog.v
//     vvp sim/tb_p0_grid.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_p0_grid;

    localparam integer HP = 120;          // 行内像素对数（240 像素/行）
    localparam integer VL = 160;

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
        .H_PAIRS (HP),
        .V_LINES (VL)
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

    // 白底 255 / 黑方块 0；fg = (gray < 170)
    function [7:0] px;
        input integer x;
        input integer y;
        begin
            px = (x >= 80 && x <= 159 && y >= 40 && y <= 119) ? 8'd0 : 8'd255;
        end
    endfunction

    task send_vs;
        begin
            i_de = 1'b0;
            i_vs = 1'b1;
            repeat (3) begin @(posedge clk); #1; end
            i_vs = 1'b0;
            repeat (3) begin @(posedge clk); #1; end
        end
    endtask

    task send_frame;
        integer r, c;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = px(2*c,     r);
                    i_g1 = px(2*c + 1, r);
                    @(posedge clk); #1;
                end
                i_de = 1'b0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (2) begin @(posedge clk); #1; end
            end
            repeat (8) begin @(posedge clk); #1; end
        end
    endtask

    task wait_upd;
        integer n;
        begin
            n = 0;
            while (!o_upd && n < 20000) begin
                @(negedge clk);
                n = n + 1;
            end
            if (!o_upd) begin
                $display("  ERROR: timeout waiting o_upd (n=%0d)", n);
                $finish;
            end
        end
    endtask

    integer errs = 0;
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (10) begin @(posedge clk); #1; end

        $display("");
        $display("======================================================================");
        $display(" P0-1  grid objectness: 80x80 solid square in %0dx%0d frame", HP*2, VL);
        $display("======================================================================");

        // 先跑一个空帧，让 best_idx 初始化
        send_vs();
        wait_upd();
        $display(" empty-frame settle : best_cnt=%0d best_idx=%0d o_cls=%0d",
                 o_best_cnt, o_best_idx, o_cls);

        send_frame();
        $display(" end of frame      : gcnt[0]=%0d gcnt[1]=%0d s_area=%0d",
                 dut.gcnt[0], dut.gcnt[1], dut.s_area);

        send_vs();
        wait_upd();

        $display("----------------------------------------------------------------------");
        $display(" P0-1 after vs      : gcnt[0]=%0d best_idx=%0d best_cnt=%0d",
                 dut.gcnt[0], o_best_idx, o_best_cnt);
        $display("                      s_area=%0d bbox=(%0d,%0d)-(%0d,%0d) bw=%0d bh=%0d",
                 dut.s_area, o_bx0, o_by0, o_bx1, o_by1, dut.bw, dut.bh);
        $display("                      fill_ok=%b cell_ok=%b asp_ok=%b rej_all=%b",
                 dut.fill_ok_r, dut.cell_ok, dut.asp_ok, dut.rej_all);
        $display("                      o_cls=%0d o_box_en=%b o_best_cnt=%0d",
                 o_cls, o_box_en, o_best_cnt);

        if (o_best_cnt !== 14'd400) begin
            $display("  FAIL: o_best_cnt=%0d, expected 400", o_best_cnt); errs = errs + 1;
        end
        if (o_cls !== 2'd2) begin
            $display("  FAIL: o_cls=%0d, expected 2 (rectangle)", o_cls); errs = errs + 1;
        end
        if (o_box_en !== 1'b1) begin
            $display("  FAIL: o_box_en=%b, expected 1", o_box_en); errs = errs + 1;
        end
        if (dut.s_area !== 16'd400) begin
            $display("  FAIL: s_area=%0d, expected 400", dut.s_area); errs = errs + 1;
        end
        if (dut.fill_ok_r !== 1'b1) begin
            $display("  FAIL: fill_ok_r=%b, expected 1 (fill=16*400/(79*80)=1.013)", dut.fill_ok_r); errs = errs + 1;
        end

        $display("----------------------------------------------------------------------");
        if (errs == 0) $display(" P0-1 RESULT: PASS  (best_cnt=400, o_cls=2)");
        else           $display(" P0-1 RESULT: FAIL  (%0d error(s))", errs);

        // 第二帧同一目标：验证 gcnt 清零是「每帧一次」——不能累积成 800，
        // 也不能因为 scan_k 停在 17 而把下一帧的计数再次清掉。
        send_frame();
        $display(" frame #2 end      : gcnt[0]=%0d (expect 400, not 800)", dut.gcnt[0]);
        send_vs();
        wait_upd();
        $display(" frame #2 after vs : best_cnt=%0d o_cls=%0d o_box_en=%b",
                 o_best_cnt, o_cls, o_box_en);
        if (o_best_cnt !== 14'd400) begin
            $display("  FAIL(frame2): o_best_cnt=%0d, expected 400 (one clear per frame)", o_best_cnt); errs = errs + 1;
        end
        if (o_cls !== 2'd2) begin
            $display("  FAIL(frame2): o_cls=%0d, expected 2", o_cls); errs = errs + 1;
        end
        $display("----------------------------------------------------------------------");
        if (errs == 0) $display(" P0-1 TWO-FRAME RESULT: PASS  (400/400, no accumulation)");
        else           $display(" P0-1 TWO-FRAME RESULT: FAIL  (%0d error(s))", errs);
        $display("======================================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
