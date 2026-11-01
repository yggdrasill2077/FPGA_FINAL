//==============================================================================
// tb_p0_window.v —— P0-1 连带修复验证：右/下目标能否进入 R9 统计窗口
//
//   场景：960x540 帧，80x80 实心方块放在 x=800..879, y=450..529
//         （初始 best_idx=0 → R9 窗口 x 0..719 / y 0..404，目标在窗口外）
//
//   改前：gcnt 每拍清零 → best_idx 永远=0 → 窗口永远锁在 cell0
//         → 第 1 帧 A=0；第 2 帧仍 A=0 → o_cls 恒 0（右/下目标永久失明）
//   改后：第 1 帧 gcnt 统计到 cell5（gcy=1,gcx=1）→ best_idx=5
//         → 第 2 帧窗口移到 x 240..1199 / y 135..674 → A=400, o_cls=2
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -s tb_p0_window -o sim/tb_p0_window.vvp \
//              sim/tb_p0_window.v rtl/edge/shape_recog.v
//     vvp sim/tb_p0_window.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_p0_window;

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
            px = (x >= 800 && x <= 879 && y >= 450 && y <= 529) ? 8'd0 : 8'd255;
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
    integer a1, c1;
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (10) begin @(posedge clk); #1; end

        $display("");
        $display("======================================================================");
        $display(" P0-1 window hand-off: 80x80 target at (800,450) in 960x540 frame");
        $display("======================================================================");

        // 第 1 帧：目标在初始窗口外，但 gcnt（不受窗口门控）应统计到 cell5
        send_frame();
        $display(" frame1 end : gcnt[0]=%0d gcnt[5]=%0d", dut.gcnt[0], dut.gcnt[5]);
        send_vs();
        wait_upd();
        $display(" frame1     : best_idx=%0d best_cnt=%0d A=%0d o_cls=%0d",
                 o_best_idx, o_best_cnt, dut.s_area, o_cls);
        if (o_best_idx !== 4'd5) begin
            $display("  FAIL: best_idx=%0d, expected 5 (cell gcy=1,gcx=1)", o_best_idx); errs = errs + 1;
        end
        if (dut.s_area !== 16'd0) begin
            $display("  WARN: frame1 A=%0d (expected 0 while target outside window)", dut.s_area);
        end
        a1 = dut.s_area;
        c1 = o_cls;

        // 第 2 帧：best_idx=5 → 窗口 x240..1199 / y135..674 → 目标进入统计
        send_frame();
        $display(" frame2 end : gcnt[5]=%0d", dut.gcnt[5]);
        send_vs();
        wait_upd();
        $display(" frame2     : best_idx=%0d best_cnt=%0d s_area=%0d bbox=(%0d,%0d)-(%0d,%0d) o_cls=%0d o_box_en=%b",
                 o_best_idx, o_best_cnt, dut.s_area, o_bx0, o_by0, o_bx1, o_by1, o_cls, o_box_en);
        $display("              fill_ok=%b cell_ok=%b asp_ok=%b", dut.fill_ok_r, dut.cell_ok, dut.asp_ok);

        if (dut.s_area !== 16'd400) begin
            $display("  FAIL: frame2 A=%0d, expected 400 (target must enter moved window)", dut.s_area); errs = errs + 1;
        end
        if (o_best_cnt !== 14'd400) begin
            $display("  FAIL: frame2 best_cnt=%0d, expected 400", o_best_cnt); errs = errs + 1;
        end
        if (o_cls !== 2'd2) begin
            $display("  FAIL: frame2 o_cls=%0d, expected 2", o_cls); errs = errs + 1;
        end

        $display("----------------------------------------------------------------------");
        $display(" frame1 (before window moves): A=%0d cls=%0d", a1, c1);
        $display(" frame2 (window moved to cell5): A=%0d cls=%0d", dut.s_area, o_cls);
        if (errs == 0) $display(" P0-1 WINDOW RESULT: PASS  (frame2 A=400, o_cls=2)");
        else           $display(" P0-1 WINDOW RESULT: FAIL  (%0d error(s))", errs);
        $display("======================================================================");
        $finish;
    end

    initial begin
        #30_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
