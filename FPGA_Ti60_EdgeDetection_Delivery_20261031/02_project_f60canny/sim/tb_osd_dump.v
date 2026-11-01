`timescale 1ns/1ps
module tb_osd_dump;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_vs = 1'b0;
    reg [10:0] i_x = 11'd0;
    reg [11:0] i_y = 12'd0;
    wire [7:0] o_r, o_g, o_b;
    wire o_on;
    reg [43:0] bx0, bx1, by0, by1;
    reg [19:0] cls;

    shape_multi_osd_v2 dut (
        .clk(clk), .rst_n(rst_n), .i_vs(i_vs),
        .i_x(i_x), .i_y(i_y),
        .i_valid(4'b0001), .i_cls(cls),
        .i_bx0(bx0), .i_bx1(bx1), .i_by0(by0), .i_by1(by1),
        .i_xoff(6'd0), .i_yoff(5'd0),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_on(o_on)
    );

    integer x, y;
    reg [8*40-1:0] line;
    initial begin
        bx0 = {33'd0, 11'd500};
        bx1 = {33'd0, 11'd700};
        by0 = {33'd0, 11'd100};
        by1 = {33'd0, 11'd300};
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        cls = {15'd0, 5'd6};
        i_vs = 1'b1; repeat (2) @(negedge clk); i_vs = 1'b0;
        for (y = 100; y < 140; y = y + 1) begin
            line = 0;
            for (x = 182; x < 226; x = x + 1) begin
                i_x = x[10:0]; i_y = y[11:0];
                #1;
                if (!o_on)                       line = {line[8*40-9:0], 8'h2E};
                else if (o_r==8'h10 && o_g==8'h10 && o_b==8'h10)
                                                 line = {line[8*40-9:0], 8'h23};
                else                             line = {line[8*40-9:0], 8'h40};
            end
            $display("%0d %0s", y, line);
        end
        $finish;
    end
endmodule
