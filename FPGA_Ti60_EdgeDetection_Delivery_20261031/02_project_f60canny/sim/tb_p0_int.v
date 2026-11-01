//==============================================================================
// tb_p0_int.v —— P0-1 + P0-2 联合复现：960x540 帧内 400x400 实心方块
//
//   白底 255 / 黑方块 0；方块 x=20..419, y=2..401
//   放在 R9 窗口（x 0..719, y 0..404）内部且不跨 4x4 网格 x=480 边界
//   1/16 采样 → A = 100x100 = 10000 样本；bbox = 397x397（只统计采样点）
//
//   改前：gcnt 每拍清零 → best_cnt=0；且 27bit 左移回绕 → fill_ok=0
//         → o_cls=0, o_box_en=0
//   P0-1 后：best_cnt=6700（cell0），fill_ok 仍 0 → o_cls=0
//   P0-2 后：fill_ok=1 → o_cls=2, o_box_en=1
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -s tb_p0_int -o sim/tb_p0_int.vvp \
//              sim/tb_p0_int.v rtl/edge/shape_recog.v
//     vvp sim/tb_p0_int.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_p0_int;

    localparam integer HP = 480;          // 960 像素/行
    localparam integer VL = 540;

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

    function [7:0] px;
        input integer x;
        input integer y;
        begin
            px = (x >= 20 && x <= 419 && y >= 2 && y <= 401) ? 8'd0 : 8'd255;
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
        $display(" P0-1/P0-2 integration: 400x400 solid square in %0dx%0d frame", HP*2, VL);
        $display("======================================================================");

        send_frame();
        $display(" end of frame : gcnt[0]=%0d gcnt[4]=%0d s_area=%0d",
                 dut.gcnt[0], dut.gcnt[4], dut.s_area);

        send_vs();
        wait_upd();

        $display("----------------------------------------------------------------------");
        $display(" after vs     : best_idx=%0d best_cnt=%0d  bbox=(%0d,%0d)-(%0d,%0d) bw=%0d bh=%0d",
                 o_best_idx, o_best_cnt, o_bx0, o_by0, o_bx1, o_by1, dut.bw, dut.bh);
        $display("                fill_ok=%b cell_ok=%b asp_ok=%b rej_all=%b",
                 dut.fill_ok_r, dut.cell_ok, dut.asp_ok, dut.rej_all);
        $display("                A=%0d  lhs=16384*A=%0d  rhs=297*bw*bh=%0d",
                 dut.s_area, 64'd16384 * dut.s_area, 64'd297 * (dut.bw * dut.bh));
        $display("                o_cls=%0d o_box_en=%b", o_cls, o_box_en);

        // P0-1 判据：best_cnt 必须非 0 且约 6700
        if (o_best_cnt < 14'd150) begin
            $display("  FAIL(P0-1): best_cnt=%0d (<150) -> cell_ok=0", o_best_cnt); errs = errs + 1;
        end
        if (o_best_cnt !== 14'd6700) begin
            $display("  WARN(P0-1): best_cnt=%0d, expected 6700", o_best_cnt);
        end
        // P0-2 判据：400x400 实心填充必须通过
        if (dut.fill_ok_r !== 1'b1) begin
            $display("  FAIL(P0-2): fill_ok_r=0 (400x400 solid, fill=1.0025)"); errs = errs + 1;
        end
        if (o_cls !== 2'd2) begin
            $display("  FAIL: o_cls=%0d, expected 2 (rectangle)", o_cls); errs = errs + 1;
        end
        if (o_box_en !== 1'b1) begin
            $display("  FAIL: o_box_en=%b, expected 1", o_box_en); errs = errs + 1;
        end

        $display("----------------------------------------------------------------------");
        if (errs == 0) $display(" P0 INTEGRATION RESULT: PASS  (best_cnt=6700, fill_ok=1, o_cls=2)");
        else           $display(" P0 INTEGRATION RESULT: FAIL  (%0d error(s))", errs);
        $display("======================================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
