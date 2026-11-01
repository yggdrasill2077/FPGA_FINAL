`timescale 1ns/1ps
//==============================================================================
// tb_full.v —— 1920×1080 真实帧尺寸下的 shape_recog 验证
//   背景：之前所有 TB 都是 240×160，从未在真实帧尺寸下验证过
//   输出：面积 / bbox / best_idx / best_cnt / box_en / 类别
//   运行：iverilog -g2012 -I sim -s tb_full -o sim/tb_full.vvp \
//                  sim/tb_full.v rtl/edge/shape_recog.v rtl/edge/shape_tmpl.v
//         vvp sim/tb_full.vvp
//==============================================================================
module tb_full;

    localparam integer HP  = 960;         // 1920/2
    localparam integer VL  = 1080;
    localparam integer W   = HP * 2;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        i_de = 0, i_vs = 0;
    reg  [7:0] i_g0 = 0, i_g1 = 0;

    wire [2:0]  o_cls;
    wire        o_upd, o_box_en;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire [3:0]  o_best_idx;
    wire [13:0] o_best_cnt;

    shape_recog #(
        .H_PAIRS (HP), .V_LINES (VL),
        .BOX_ON_ANY(1)                 // 诊断：有前景就画框
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_box_en(o_box_en), .o_best_idx(o_best_idx), .o_best_cnt(o_best_cnt)
    );

    // 白底 + 中心 (cx,cy) 半宽 hw/半高 hh 的暗块
    task send_frame(input integer cx, input integer cy,
                    input integer hw, input integer hh);
        integer r, c, dx, dy;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1;
                    dx = (2*c) - cx;     dy = r - cy;
                    i_g0 = ((dx >= -hw) && (dx <= hw) && (dy >= -hh) && (dy <= hh)) ? 8'd30 : 8'd255;
                    dx = (2*c+1) - cx;
                    i_g1 = ((dx >= -hw) && (dx <= hw) && (dy >= -hh) && (dy <= hh)) ? 8'd30 : 8'd255;
                    @(posedge clk); #1;
                end
                i_de = 0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (2) @(posedge clk); #1;
            end
            repeat (8) @(posedge clk); #1;
        end
    endtask

    task send_vs;
        begin
            i_de = 0; i_vs = 1;
            repeat (3) @(posedge clk); #1;
            i_vs = 0;
            repeat (3) @(posedge clk); #1;
        end
    endtask

    task wait_upd;
        integer n;
        begin
            n = 0;
            while (!o_upd && n < 40000) begin @(negedge clk); n = n + 1; end
        end
    endtask

    integer errs = 0;
    task run_case(input integer cx, input integer cy,
                  input integer hw, input integer hh,
                  input integer exp_bx0, input integer exp_bx1,
                  input integer exp_by0, input integer exp_by1);
        begin
            send_frame(cx, cy, hw, hh); send_vs(); wait_upd();
            send_frame(cx, cy, hw, hh); send_vs(); wait_upd();
            $write("  (%0d,%0d) %0dx%0d → A=%0d best_idx=%0d cnt=%0d bbox=(%0d,%0d)-(%0d,%0d) box_en=%0d",
                   cx, cy, hw*2, hh*2, dut.s_area, o_best_idx, o_best_cnt,
                   o_bx0, o_by0, o_bx1, o_by1, o_box_en);
            if (o_bx0 > o_bx1) begin
                $display("  【无前景】");
            end else if ((o_bx0 > exp_bx0+6) || (o_bx1 + 6 < exp_bx1) ||
                         (o_by0 > exp_by0+6) || (o_by1 + 6 < exp_by1)) begin
                errs = errs + 1;
                $display("  FAIL 期望 bbox=(%0d,%0d)-(%0d,%0d)", exp_bx0, exp_by0, exp_bx1, exp_by1);
            end else begin
                $display("  PASS");
            end
        end
    endtask

    initial begin
        rst_n = 0; repeat (10) @(posedge clk); #1 rst_n = 1;
        repeat (10) @(posedge clk); #1;
        $display("======================================================================");
        $display(" 1920x1080 真实帧尺寸验证（BOX_ON_ANY=1）");
        $display("======================================================================");
        send_vs(); wait_upd();
        // 600x400 居中：预期 bbox ≈ (660,340)-(1260,740)
        run_case(960, 540, 300, 200,  660, 1260, 340, 740);
        // 小目标 200x200 在左上：(200,200) → bbox ≈ (100,100)-(300,300)
        run_case(200, 200, 100, 100,  100, 300,  100, 300);
        // 右下 400x300：(1500,800) → (1300,650)-(1700,950)
        run_case(1500, 800, 200, 150, 1300, 1700, 650, 950);
        $display("----------------------------------------------------------------------");
        if (errs == 0) $display(" RESULT: ALL PASS (3 cases)");
        else           $display(" RESULT: %0d ERROR(S)", errs);
        $display("======================================================================");
        $finish;
    end

endmodule
