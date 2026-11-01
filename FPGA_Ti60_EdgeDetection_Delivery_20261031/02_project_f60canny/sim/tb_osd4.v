`timescale 1ns/1ps
// tb_osd4.v —— shape_osd 四类符号冒烟测试：统计窗口内亮像素数
module tb_osd4;
    localparam integer W = 1920, H = 1080;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        i_vs = 0;
    reg  [10:0] i_x = 0;
    reg  [11:0] i_y = 0;
    reg  [2:0]  i_cls = 0;
    wire [7:0]  o_px, o_grid;

    shape_osd u_osd (
        .clk(clk), .rst_n(rst_n), .i_vs(i_vs),
        .i_x(i_x), .i_y(i_y),
        .i_cls(i_cls),
        .i_bx0(11'd0), .i_bx1(11'd0), .i_by0(11'd0), .i_by1(11'd0),
        .i_box_en(1'b0),
        .i_best_idx(4'd0), .i_best_cnt(14'd0),
        .o_px(o_px), .o_grid(o_grid)
    );

    integer cnt, c;
    initial begin
        rst_n = 0; repeat (5) @(posedge clk);
        #1 rst_n = 1;
        for (c = 0; c <= 4; c = c + 1) begin
            i_cls = c[2:0];
            i_vs = 1; @(posedge clk); #1 i_vs = 0;   // 锁存类别
            @(posedge clk); #1;
            cnt = 0;
            for (i_y = 0; i_y < 64; i_y = i_y + 1)   // 只扫符号窗口所在的上部
                for (i_x = 0; i_x < 320; i_x = i_x + 1) begin
                    @(posedge clk); #1;
                    if (o_px != 0) cnt = cnt + 1;
                end
            $display("cls=%0d  symbol_pixels=%0d", c, cnt);
        end
        $finish;
    end
endmodule
