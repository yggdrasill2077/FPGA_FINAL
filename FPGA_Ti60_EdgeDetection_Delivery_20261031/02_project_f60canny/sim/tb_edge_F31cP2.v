`timescale 1ns/1ps
module tb_edge_F31cP2;
    localparam integer HP = 160;
    localparam integer VL = 240;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] edge_g0 = 8'd255;
    reg [7:0] edge_g1 = 8'd255;
    reg [7:0] ref_g0  = 8'd60;
    reg [7:0] ref_g1  = 8'd60;

    wire [2:0]  w_num;
    wire [3:0]  w_valid;
    wire [3:0]  w_show;
    wire [11:0] w_cls;
    wire [63:0] w_area;
    wire [107:0] w_sx, w_sy;
    wire [43:0] w_bx0, w_bx1, w_by0, w_by1;
    wire w_done;

    shape_multi_recog #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(8), .GRID_Y(6),
        .CELL_SEED_MIN(3), .CELL_MERGE_MIN(1),
        .MIN_AREA(16), .MIN_BBOX(8), .FILL_MIN(8), .MERGE_GAP(2),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(4), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(1),
        .TY_MARGIN(8'd20), .TY_CAP(8'd110), .TY_FLOOR(8'd24),
        .PAPER_GATE_EN(1), .PAPER_MIN_LEVEL(8'd90), .PAPER_ERODE(8),
        .PAPER_MIN_SAMPLES(32), .PAPER_MIN_SIZE(32), .PAPER_FILL_MIN(64)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(edge_g0), .i_g1(edge_g1), .i_ty(8'd1),
        .i_ref_de(i_de), .i_ref_vs(i_vs), .i_ref_g0(ref_g0), .i_ref_g1(ref_g1),
        .o_num(w_num), .o_valid(w_valid), .o_show(w_show), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    integer scene;
    integer r, c, n;

    function paper_px;
        input integer x;
        input integer y;
        begin
            paper_px = (x>=50)&&(x<=269)&&(y>=30)&&(y<=209);
        end
    endfunction

    function edge_px;
        input integer x;
        input integer y;
        integer dx, dy, d2;
        begin
            edge_px = 1'b0;
            if (scene == 0) begin
                edge_px = (x>=120)&&(x<=200)&&(y>=80)&&(y<=160) &&
                          ((x<124)||(x>196)||(y<84)||(y>156));
            end else if (scene == 1) begin
                dx = x - 160;
                dy = y - 120;
                d2 = dx*dx + dy*dy;
                edge_px = (d2 >= 37*37) && (d2 <= 43*43);
            end
        end
    endfunction

    function [7:0] ref_pixel;
        input integer x;
        input integer y;
        begin
            ref_pixel = paper_px(x,y) ? 8'd140 : 8'd55;
        end
    endfunction

    task send_frame;
        begin
            i_vs = 1'b0; repeat (3) @(negedge clk);
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1;
                    edge_g0 = edge_px(2*c,   r) ? 8'd0 : 8'd255;
                    edge_g1 = edge_px(2*c+1, r) ? 8'd0 : 8'd255;
                    ref_g0  = ref_pixel(2*c,   r);
                    ref_g1  = ref_pixel(2*c+1, r);
                    @(negedge clk);
                end
                i_de = 1'b0;
                repeat (20) @(negedge clk);
            end
        end
    endtask

    task check_scene(input integer sc, input [2:0] exp_num, input [2:0] exp_cls);
        begin
            scene = sc;
            repeat (6) send_frame();
            n = 0;
            while (!w_done && n < 200000) begin @(posedge clk); #1; n=n+1; end
            #1000;
            $display("EDGE SCENE %0d num=%0d valid=%b show=%b cls=%03x bbox=(%0d,%0d)-(%0d,%0d)",
                     sc, w_num, w_valid, w_show, w_cls,
                     w_bx0[10:0], w_by0[10:0], w_bx1[10:0], w_by1[10:0]);
            if (w_num !== exp_num) $display("EDGE SCENE %0d NUM FAIL exp=%0d", sc, exp_num);
            if ((exp_num == 0) && (w_show !== 4'b0000))
                $display("EDGE SCENE %0d SHOW FAIL expected empty", sc);
            if ((exp_num != 0) && (w_show[0] !== 1'b1))
                $display("EDGE SCENE %0d SHOW FAIL expected candidate 0 visible", sc);
            if ((w_show & ~w_valid) !== 4'b0000)
                $display("EDGE SCENE %0d SHOW FAIL mask escaped valid candidates", sc);
            if ((exp_num != 0) && (w_cls[2:0] !== exp_cls))
                $display("EDGE SCENE %0d CLS FAIL exp=%0d got=%0d", sc, exp_cls, w_cls[2:0]);
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        check_scene(0, 3'd1, 3'd2);
        check_scene(1, 3'd1, 3'd1);
        check_scene(2, 3'd0, 3'd0);
        $display("EDGE CONTOUR F31CP2 TEST DONE");
        $finish;
    end
endmodule
