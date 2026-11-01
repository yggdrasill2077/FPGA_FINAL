`timescale 1ns/1ps
module tb_paper_F31cP;
    localparam integer HP = 160;
    localparam integer VL = 240;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd60;
    reg [7:0] i_g1 = 8'd60;

    wire [2:0] w_num;
    wire [3:0] w_valid;
    wire [11:0] w_cls;
    wire [63:0] w_area;
    wire [107:0] w_sx, w_sy;
    wire [43:0] w_bx0, w_bx1, w_by0, w_by1;
    wire w_done;

    shape_multi_recog #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(8), .GRID_Y(6),
        .CELL_SEED_MIN(4), .CELL_MERGE_MIN(1),
        .MIN_AREA(16), .MIN_BBOX(8), .FILL_MIN(8), .MERGE_GAP(1),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(1),
        .TY_MARGIN(8'd20), .TY_CAP(8'd110), .TY_FLOOR(8'd24),
        .PAPER_GATE_EN(1), .PAPER_MIN_LEVEL(8'd90), .PAPER_ERODE(8),
        .PAPER_MIN_SAMPLES(32), .PAPER_MIN_SIZE(32), .PAPER_FILL_MIN(64)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170),
        .i_ref_de(i_de), .i_ref_vs(i_vs), .i_ref_g0(i_g0), .i_ref_g1(i_g1),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    integer scene;
    integer px, py, r, c, n;

    function paper_px;
        input integer x;
        input integer y;
        begin
            case (scene)
            0, 1, 4, 5: paper_px = (x>=60)&&(x<=259)&&(y>=40)&&(y<=199);
            2:    paper_px = (x>=100)&&(x<=219)&&(y>=75)&&(y<=164);
            3:    paper_px = (x>=60)&&(x<=259)&&(y>=40)&&(y<=199);
            default: paper_px = 1'b0;
            endcase
        end
    endfunction

    function ink_px;
        input integer x;
        input integer y;
        begin
            case (scene)
            0, 4, 5: ink_px = ((x-160)*(x-160)+(y-120)*(y-120) <= 35*35);
            1: ink_px = (x>=125)&&(x<=195)&&(y>=85)&&(y<=155);
            2: ink_px = ((x-160)*(x-160)+(y-120)*(y-120) <= 28*28);
            3: ink_px = 1'b0;
            default: ink_px = 1'b0;
            endcase
        end
    endfunction

    function [7:0] pixel_g;
        input integer x;
        input integer y;
        begin
            if (paper_px(x,y)) begin
                if (scene == 5)      pixel_g = ink_px(x,y) ? 8'd40 : 8'd95;
                else if (scene == 4) pixel_g = ink_px(x,y) ? 8'd95 : 8'd125;
                else                 pixel_g = ink_px(x,y) ? 8'd45 : 8'd125;
            end
            else               pixel_g = 8'd60;
        end
    endfunction

    task send_frame;
        begin
            i_vs = 1'b0; repeat (3) @(negedge clk);
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1;
                    i_g0 = pixel_g(2*c,   r);
                    i_g1 = pixel_g(2*c+1, r);
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
            repeat (5) send_frame();
            n = 0;
            while (!w_done && n < 200000) begin @(posedge clk); #1; n=n+1; end
            #1000;
            $display("SCENE %0d num=%0d valid=%b cls=%03x bbox=(%0d,%0d)-(%0d,%0d) paper=%b", 
                     sc, w_num, w_valid, w_cls,
                     w_bx0[10:0], w_by0[10:0], w_bx1[10:0], w_by1[10:0],
                     dut.u_paper_gate.o_valid);
            $display("  ty=%0d paper_bbox=(%0d,%0d)-(%0d,%0d) max_l=%0d max=%0d inside0=%b",
                     dut.ty_eff, dut.u_paper_gate.o_bx0, dut.u_paper_gate.o_by0,
                     dut.u_paper_gate.o_bx1, dut.u_paper_gate.o_by1,
                     dut.max_y_l, dut.max_y, dut.paper_inside);
            if (w_num !== exp_num) $display("SCENE %0d NUM FAIL exp=%0d", sc, exp_num);
            if ((exp_num != 0) && (w_cls[2:0] !== exp_cls))
                $display("SCENE %0d CLS FAIL exp=%0d got=%0d", sc, exp_cls, w_cls[2:0]);
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        check_scene(0, 3'd1, 3'd1);
        check_scene(1, 3'd1, 3'd2);
        check_scene(2, 3'd1, 3'd1);
        check_scene(3, 3'd0, 3'd0);
        check_scene(4, 3'd1, 3'd1);
        check_scene(5, 3'd1, 3'd1);
        check_scene(6, 3'd0, 3'd0);
        $display("PAPER F31CP TEST DONE");
        $finish;
    end
endmodule
