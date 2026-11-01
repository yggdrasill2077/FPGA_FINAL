`timescale 1ns/1ps
module tb_single_large_probe;
    localparam integer HP = 640;
    localparam integer VL = 1000;
    localparam integer TIMEOUT = 60000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;

    wire [2:0] w_num;
    wire [3:0] w_valid;
    wire [11:0] w_cls;
    wire [63:0] w_area;
    wire [107:0] w_sx, w_sy;
    wire [43:0] w_bx0, w_bx1, w_by0, w_by1;
    wire w_done;

    shape_multi_recog #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(16), .GRID_Y(12),
        .CELL_SEED_MIN(4), .CELL_MERGE_MIN(1),
        .MIN_AREA(16), .MIN_BBOX(8), .FILL_MIN(4), .MERGE_GAP(1),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(TIMEOUT), .AUTO_TY(0), .PAPER_GATE_EN(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170), .i_lfg0(1'b0), .i_lfg1(1'b0),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    function in_square(input integer x, input integer y);
        begin in_square = (x>=160)&&(x<=919)&&(y>=100)&&(y<=859); end
    endfunction

    integer r, c, n, k;
    task send_frame;
        begin
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1;
                    i_g0 = in_square(2*c,   r) ? 8'd0 : 8'd255;
                    i_g1 = in_square(2*c+1, r) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0; i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (20) @(negedge clk);
            end
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            repeat (5) @(negedge clk);
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        send_frame();
        n = 0;
        while (!w_done && n < 300000) begin @(posedge clk); #1; n = n+1; end
        $display("LARGE timeout_param=%0d done=%b num=%0d valid=%b cls=%03x cycles=%0d",
                 TIMEOUT, w_done, w_num, w_valid, w_cls, n);
        for (k=0;k<4;k=k+1)
            if (w_valid[k])
                $display("  cand%0d cls=%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d",
                         k, w_cls[3*k +: 3],
                         w_bx0[11*k +: 11], w_by0[11*k +: 11],
                         w_bx1[11*k +: 11], w_by1[11*k +: 11],
                         w_area[16*k +: 16]);
        $finish;
    end
endmodule
