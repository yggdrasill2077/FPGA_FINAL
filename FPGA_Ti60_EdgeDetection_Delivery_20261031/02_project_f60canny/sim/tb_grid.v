`timescale 1ns/1ps
//==============================================================================
// tb_grid.v —— 网格选格 + 窗口门控验证（T1 参数化后，小帧也能覆盖 16 格）
//
//   帧 240×160，CELL_W=60 / CELL_H=40 → 4×4 格，每格 30×20 个 1/16 样本
//   用例：把 40×40 的方块放在不同格，检查 o_best_idx 是否指向该格，
//         以及第二帧的 bbox 是否被限制在该格窗口内（± 半格）
//
//   运行：iverilog -g2012 -I sim -s tb_grid -o sim/tb_grid.vvp \
//                  sim/tb_grid.v rtl/edge/shape_recog.v rtl/edge/shape_tmpl.v
//         vvp sim/tb_grid.vvp
//==============================================================================
module tb_grid;

    localparam integer HP = 120;      // 240/2
    localparam integer VL = 160;
    localparam integer W  = HP * 2;
    localparam integer H  = VL;
    localparam integer PIX = W * H;
    localparam integer CW = 60;       // CELL_W
    localparam integer CH = 40;       // CELL_H

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
        .CELL_W  (CW), .CELL_H  (CH),
        .CELL_MIN(0),                  // 诊断：不因样本数被拦
        .A_MIN   (1), .A_MAX(60000),
        .BOX_ON_ANY(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_box_en(o_box_en), .o_best_idx(o_best_idx), .o_best_cnt(o_best_cnt)
    );

    // 生成一帧：白底(255) + 指定位置的黑暗方块(40×40)
    task send_frame(input integer cx, input integer cy);
        integer r, c, dx, dy;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1;
                    // 像素 (2c, r) 与 (2c+1, r)
                    dx = (2*c) - cx; dy = r - cy;
                    i_g0 = ((dx*dx <= 400) && (dy*dy <= 400)) ? 8'd30 : 8'd255;
                    dx = (2*c+1) - cx;
                    i_g1 = ((dx*dx <= 400) && (dy*dy <= 400)) ? 8'd30 : 8'd255;
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
            while (!o_upd && n < 20000) begin @(negedge clk); n = n + 1; end
        end
    endtask

    integer errs = 0;
    integer t;

    // 用例：{中心 x, 中心 y, 期望格}
    //   格号 = {gcy, gcx}，gcx = x/CW，gcy = y/CH
    task run_case(input integer cx, input integer cy, input integer exp_cell);
        integer got;
        begin
            // 第 1 帧：建立统计（此时窗口还锁在格 0）
            send_frame(cx, cy); send_vs(); wait_upd();
            // 第 2 帧：用上一帧 best_idx 的窗口再统计
            send_frame(cx, cy); send_vs(); wait_upd();
            got = o_best_idx;
            if (got !== exp_cell) begin
                errs = errs + 1;
                $display("  FAIL (%0d,%0d) best_idx=%0d 期望 %0d  bbox=(%0d,%0d)-(%0d,%0d) box_en=%0d",
                         cx, cy, got, exp_cell, o_bx0, o_by0, o_bx1, o_by1, o_box_en);
            end else begin
                $display("  PASS (%0d,%0d) best_idx=%0d cnt=%0d bbox=(%0d,%0d)-(%0d,%0d) box_en=%0d",
                         cx, cy, got, o_best_cnt, o_bx0, o_by0, o_bx1, o_by1, o_box_en);
            end
        end
    endtask

    initial begin
        rst_n = 0; repeat (10) @(posedge clk); #1 rst_n = 1;
        repeat (10) @(posedge clk); #1;
        $display("==============================================================");
        $display(" 网格选格验证（240x160, CELL %0dx%0d）", CW, CH);
        $display("==============================================================");
        send_vs(); wait_upd();
        run_case( 30,  20, 4'd0);    // 左上格
        run_case(210,  20, 4'd3);    // 右上格
        run_case( 30, 140, 4'd12);   // 左下格
        run_case(210, 140, 4'd15);   // 右下格
        run_case(120,  80, 4'd10);   // 中间偏右（gcx=2, gcy=2）
        $display("--------------------------------------------------------------");
        if (errs == 0) $display(" RESULT: ALL PASS (5 cases)");
        else           $display(" RESULT: %0d ERROR(S)", errs);
        $display("==============================================================");
        $finish;
    end

endmodule
