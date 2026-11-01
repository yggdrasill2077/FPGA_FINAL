`timescale 1ns/1ps
// tb_g9.v -- 9x9 高斯脉冲测试（简化版：统计非零输出与其位置/数值）
module tb_g9;
    localparam integer HP = 40;      // 像素对/行 = 80 像素
    localparam integer VL = 30;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         i_de = 0, i_vs = 0;
    reg  [15:0] i_pair = 0;
    wire        o_de;
    wire [15:0] o_pair;

    gauss9x9_2px #(.H_PAIRS(HP), .ADDR_W(6)) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_pair(i_pair), .o_de(o_de), .o_pair(o_pair)
    );

    // 输出统计
    integer ocnt = 0;        // 非零像素个数
    integer osum = 0;        // 非零像素总和
    integer omax = 0;        // 最大值
    integer oidx = 0;        // 输出线性索引（像素）
    integer nz_rows = 0, nz_cols = 0;
    integer rmin = 99999, rmax = -1, cmin = 99999, cmax = -1;
    integer cur_row = 0, cur_col = 0;
    reg     prev_de = 0;

    always @(posedge clk) begin
        if (o_de) begin
            // 每拍输出 2 个像素
            if (o_pair[7:0] != 0) begin
                ocnt = ocnt + 1; osum = osum + o_pair[7:0];
                if (o_pair[7:0] > omax) omax = o_pair[7:0];
                if (cur_row < rmin) rmin = cur_row;
                if (cur_row > rmax) rmax = cur_row;
                if (cur_col < cmin) cmin = cur_col;
                if (cur_col > cmax) cmax = cur_col;
            end
        end
        if (!i_de) begin cur_row = 0; cur_col = 0; end
        else begin
            cur_col = cur_col + 2;
            if (cur_col >= HP*2) begin cur_col = 0; cur_row = cur_row + 1; end
        end
    end

    integer r, c;
    initial begin
        repeat (5) @(posedge clk); #1;
        rst_n = 1;
        repeat (3) @(posedge clk); #1;
        i_vs = 1; repeat (2) @(posedge clk); #1; i_vs = 0;

        for (r = 0; r < VL; r = r + 1) begin
            for (c = 0; c < HP; c = c + 1) begin
                i_de = 1;
                i_pair = (r == 15 && c == 20) ? 16'h00FF : 16'h0000;  // 亮点在像素 40
                @(posedge clk); #1;
            end
            i_de = 0; i_pair = 0;
            repeat (2) @(posedge clk); #1;
        end
        repeat (30) @(posedge clk); #1;

        $display("=====================================================");
        $display(" 9x9 impulse test: single pixel=255 at (40,15) in 80x30");
        $display(" nonzero px = %0d   sum = %0d   max = %0d", ocnt, osum, omax);
        $display(" nonzero bbox: rows %0d..%0d  cols %0d..%0d", rmin, rmax, cmin, cmax);
        $display(" expected   : ~81 px, sum ~255, max ~70, bbox 9x9");
        $display("=====================================================");
        $finish;
    end
endmodule
