`timescale 1ns/1ps
module tb_merge;
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    reg i_de = 1'b0, i_vs = 1'b0, i_hs = 1'b0;
    reg [23:0] i_px = 24'd0;
    wire o_de, o_vs, o_hs;
    wire [47:0] o_px;
    integer x, errs = 0, pairs = 0;
    reg [23:0] base; reg first = 1'b0;

    merge_1to2 u_dut (.clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_hs(i_hs), .i_px(i_px),
        .o_de(o_de), .o_vs(o_vs), .o_hs(o_hs), .o_px(o_px));

    // 检查配对
    always @(posedge clk) begin
        if (o_de) begin
            if (!first) begin base = o_px[23:0]; first = 1'b1; end
            if (o_px[23:0] !== (base + pairs*2) || o_px[47:24] !== (base + pairs*2 + 1)) begin
                $display("  [错] 第%0d对: lo=%h(期望%h) hi=%h(期望%h)", pairs, o_px[23:0], base+pairs*2, o_px[47:24], base+pairs*2+1);
                errs = errs + 1;
            end
            pairs = pairs + 1;
        end
    end

    initial begin
        #100; rst_n = 1'b1; #100;
        // 行同步
        i_hs <= 1'b1; @(posedge clk); @(posedge clk); i_hs <= 1'b0;
        repeat (4) @(posedge clk);
        // 64 个递增像素
        for (x = 0; x < 64; x = x + 1) begin
            i_de = 1'b1; i_px <= x[23:0];
            @(posedge clk);
        end
        i_de = 1'b0; @(posedge clk);
        repeat (20) @(posedge clk);
        $display("==== 结束: 输出对=%0d 错误=%0d ====", pairs, errs);
        if (pairs == 32 && errs == 0) $display("结果: 通过 (32 对全部正确)");
        else $display("结果: 失败");
        $finish;
    end

    // 前 16 拍打印
    integer d = 0;
    always @(posedge clk) begin
        if (rst_n && d < 16) begin
            $display("t=%0t de=%b px=%h | ode=%b opx=%h lo=%h hi=%h", $time, i_de, i_px, o_de, o_px, o_px[23:0], o_px[47:24]);
            d = d + 1;
        end
    end
endmodule