`timescale 1ns/1ps
//==============================================================================
// tb_off.v —— 测 shape_recog 的 o_bx0 / o_by0 相对真实物体位置的偏移
//   基线：sim/tb_full.v（1920×1080，2ppc，白底暗块）
//   物体用**输入像素坐标**直接给出，不再用中心/半宽：
//       A: x∈[400,600], y∈[300,500]
//       B: x∈[800,1000], y∈[300,500]
//       C: x∈[400,600], y∈[600,800]
//   每个位置跑 2 帧（bbox 为上一帧锁存），打印两帧的 o_bx0/o_bx1/o_by0/o_by1，
//   并算 dx = o_bx0 - x_in0, dy = o_by0 - y_in0。
//
//   运行：
//     iverilog -g2012 -I sim -s tb_off -o sim/tb_off.vvp \
//              sim/tb_off.v rtl/edge/shape_recog.v rtl/edge/shape_tmpl.v
//     vvp sim/tb_off.vvp
//==============================================================================
module tb_off;

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
        .BOX_ON_ANY(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_box_en(o_box_en), .o_best_idx(o_best_idx), .o_best_cnt(o_best_cnt)
    );

    // 白底 + 矩形 [x0..x1]×[y0..y1] 的暗块（输入像素坐标，闭区间）
    task send_frame(input integer x0i, input integer x1i,
                    input integer y0i, input integer y1i);
        integer r, c, px;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1;
                    px = 2*c;
                    i_g0 = ((px >= x0i) && (px <= x1i) &&
                            (r  >= y0i) && (r  <= y1i)) ? 8'd30 : 8'd255;
                    px = 2*c + 1;
                    i_g1 = ((px >= x0i) && (px <= x1i) &&
                            (r  >= y0i) && (r  <= y1i)) ? 8'd30 : 8'd255;
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
            repeat (20) @(posedge clk); #1;      // 等 bbox 快照稳定
        end
    endtask

    integer dx, dy;

    task run_case(input integer x0i, input integer x1i,
                  input integer y0i, input integer y1i);
        begin
            $display("----------------------------------------------------------------------");
            $display(" 输入 x[%0d..%0d] y[%0d..%0d]  (%0dx%0d)",
                     x0i, x1i, y0i, y1i, x1i - x0i + 1, y1i - y0i + 1);

            // 第 1 帧
            send_frame(x0i, x1i, y0i, y1i); send_vs(); wait_upd();
            dx = o_bx0 - x0i;  dy = o_by0 - y0i;
            $display("   F1: out (%0d,%0d)-(%0d,%0d)  cls=%0d box_en=%0d  dx=%0d dy=%0d",
                     o_bx0, o_by0, o_bx1, o_by1, o_cls, o_box_en, dx, dy);

            // 第 2 帧（与第 1 帧完全相同；bbox 为上一帧锁存）
            send_frame(x0i, x1i, y0i, y1i); send_vs(); wait_upd();
            dx = o_bx0 - x0i;  dy = o_by0 - y0i;
            $display("   F2: out (%0d,%0d)-(%0d,%0d)  cls=%0d box_en=%0d  dx=%0d dy=%0d",
                     o_bx0, o_by0, o_bx1, o_by1, o_cls, o_box_en, dx, dy);
        end
    endtask

    initial begin
        rst_n = 0; repeat (10) @(posedge clk); #1 rst_n = 1;
        repeat (10) @(posedge clk); #1;
        $display("======================================================================");
        $display(" shape_recog bbox 偏移测试（1920x1080，BOX_ON_ANY=1，白底暗块）");
        $display(" o_bx0/o_by0 是「上一帧锁存」，故每位置跑 2 帧");
        $display("======================================================================");
        send_vs(); wait_upd();          // 丢弃上电后的空帧

        run_case(400, 600, 300, 500);   // A
        run_case(800, 1000, 300, 500);  // B
        run_case(400, 600, 600, 800);   // C

        $display("======================================================================");
        $finish;
    end

endmodule
