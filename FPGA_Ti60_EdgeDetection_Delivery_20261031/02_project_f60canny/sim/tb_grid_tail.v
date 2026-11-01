`timescale 1ns/1ps
module tb_grid_tail;
    localparam integer HP = 160;   // 320 px, 80 blocks
    localparam integer VL = 240;   // 60 blocks

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;

    wire [2:0] num;
    wire [3:0] valid;
    wire [43:0] bx0, bx1, by0, by1;
    wire [107:0] sx, sy;
    wire [63:0] area;
    wire done;

    shape_grid_multi_v2 #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(7), .GRID_Y(7),
        .CELL_SEED_MIN(2), .CELL_MERGE_MIN(1),
        .MIN_AREA(8), .MIN_BBOX(4), .FILL_MIN(2), .MERGE_GAP(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170),
        .i_gate_en(1'b0), .i_gx0(11'd0), .i_gx1(11'd0),
        .i_gy0(11'd0), .i_gy1(11'd0),
        .o_num(num), .o_valid(valid),
        .o_bx0(bx0), .o_bx1(bx1), .o_by0(by0), .o_by1(by1),
        .o_sx(sx), .o_sy(sy), .o_area(area), .o_done(done)
    );

    function in_tail(input integer x, input integer y);
        begin in_tail = (x >= 280) && (x <= 319) && (y >= 200) && (y <= 239); end
    endfunction

    integer r, c, n, errs;
    initial begin
        errs = 0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        for (r=0; r<VL; r=r+1) begin
            for (c=0; c<HP; c=c+1) begin
                i_de = 1'b1;
                i_g0 = in_tail(2*c,   r) ? 8'd0 : 8'd255;
                i_g1 = in_tail(2*c+1, r) ? 8'd0 : 8'd255;
                @(negedge clk);
            end
            i_de = 1'b0; i_g0 = 8'd255; i_g1 = 8'd255;
            repeat (40) @(negedge clk);
        end
        i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
        n = 0;
        while (!done && n < 20000) begin @(posedge clk); #1; n = n + 1; end
        $display("TAIL num=%0d valid=%b bbox=(%0d,%0d)-(%0d,%0d) area=%0d",
                 num, valid, bx0[10:0], by0[10:0], bx1[10:0], by1[10:0], area[15:0]);
        if (!done || (num != 1) || (bx1[10:0] != 319) || (by1[10:0] != 239)) begin
            $display("TAIL GRID FAIL");
            errs = errs + 1;
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
