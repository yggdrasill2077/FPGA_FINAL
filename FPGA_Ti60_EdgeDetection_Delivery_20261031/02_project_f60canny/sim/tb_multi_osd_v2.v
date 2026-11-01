`timescale 1ns/1ps
module tb_multi_osd_v2;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_vs = 1'b0;
    reg [10:0] i_x = 11'd0;
    reg [11:0] i_y = 12'd0;
    wire [7:0] o_r, o_g, o_b;
    wire o_on;

    reg [43:0] bx0, bx1, by0, by1;
    initial begin
        // candidate 0: triangle, candidate 1: circle, candidate 2: unknown
        bx0 = {11'd0, 11'd0, 11'd800, 11'd500};
        bx1 = {11'd0, 11'd0, 11'd1000, 11'd700};
        by0 = {11'd0, 11'd0, 11'd400, 11'd100};
        by1 = {11'd0, 11'd0, 11'd600, 11'd300};
    end

    shape_multi_osd_v2 dut (
        .clk(clk), .rst_n(rst_n), .i_vs(i_vs),
        .i_x(i_x), .i_y(i_y),
        .i_valid(4'b0011), .i_cls({3'd0, 3'd0, 3'd1, 3'd3}),
        .i_bx0(bx0), .i_bx1(bx1), .i_by0(by0), .i_by1(by1),
        .i_xoff(6'd0), .i_yoff(5'd0),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_on(o_on)
    );

    integer x, y, n, n_tri, n_circle, n_dark;
    initial begin
        n = 0; n_tri = 0; n_circle = 0; n_dark = 0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        i_vs = 1'b1; repeat (2) @(negedge clk); i_vs = 1'b0;
        for (y = 0; y < 720; y = y + 1) begin
            for (x = 0; x < 960; x = x + 1) begin
                i_x = x[10:0]; i_y = y[11:0];
                #1;
                if (o_on) n = n + 1;
                if (o_on && (o_r == 8'hFF) && (o_g == 8'hFF) && (o_b == 8'h00)) n_tri = n_tri + 1;
                if (o_on && (o_r == 8'hFF) && (o_g == 8'hFF) && (o_b == 8'hFF)) n_circle = n_circle + 1;
                if (o_on && (o_r == 8'h10) && (o_g == 8'h10) && (o_b == 8'h10)) n_dark = n_dark + 1;
            end
        end
        $display("OSD on=%0d triangle=%0d circle=%0d badge_dark=%0d", n, n_tri, n_circle, n_dark);
        if ((n_tri < 20) || (n_circle < 20) || (n_dark < 100)) begin
            $display("PER-BOX BADGE FAIL");
            $finish;
        end
        $display("RESULT: 0 ERROR(S)");
        $finish;
    end
endmodule
