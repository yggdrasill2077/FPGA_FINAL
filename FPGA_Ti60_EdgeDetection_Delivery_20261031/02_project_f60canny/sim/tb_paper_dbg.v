`timescale 1ns/1ps
// End-to-end shape pipeline probe: paper carrier, dim light, lamp, clutter.
module tb_paper_dbg;
    localparam integer HP = 320;   // 640 px
    localparam integer VL = 360;

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
        .GRID_X(32), .GRID_Y(18),
        .CELL_SEED_MIN(4), .CELL_MERGE_MIN(1),
        .MIN_AREA(16), .MIN_BBOX(8), .FILL_MIN(8), .MERGE_GAP(1),
        .MAX_BBOX_W(1800), .MAX_BBOX_H(1000),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(96), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(1),
        .TY_MARGIN(8'd20), .TY_CAP(8'd110), .TY_FLOOR(8'd24),
        .PAPER_GATE_EN(1), .PAPER_MIN_LEVEL(8'd90), .PAPER_ERODE(8),
        .PAPER_MIN_SAMPLES(32), .PAPER_MIN_SIZE(32), .PAPER_FILL_MIN(64)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    integer scene;
    integer paper_g, ink_g, bg_g;
    integer px, py, r, c, n, k;

    function paper_px(input integer x, input integer y);
        begin
            case (scene)
            0, 1, 2, 3, 5: paper_px = (x>=80)&&(x<=560)&&(y>=40)&&(y<=320);
            default:       paper_px = 1'b0;
            endcase
        end
    endfunction

    function ink_px(input integer x, input integer y);
        begin
            case (scene)
            0, 1, 2, 3:
                ink_px = (((x-170)*(x-170)+(y-120)*(y-120) <= 45*45) ||
                          ((x>=260)&&(x<=340)&&(y>=70)&&(y<=150)) ||
                          ((y>=60)&&(y<=160)&&(x>=(430-(y-60)*55/100))&&(x<=(430+(y-60)*55/100))) ||
                          ((x>=120)&&(x<=240)&&(y>=230)&&(y<=290)));
            5:
                ink_px = ((((x-170)*(x-170)+(y-120)*(y-120) <= 45*45) &&
                           ((x-170)*(x-170)+(y-120)*(y-120) >= 37*37)) ||
                          ((x>=260)&&(x<=340)&&(y>=70)&&(y<=150) &&
                           ((x<268)||(x>332)||(y<78)||(y>142))) ||
                          ((y>=60)&&(y<=160)&&(x>=(430-(y-60)*55/100))&&(x<=(430+(y-60)*55/100)) &&
                           ((y<68)||(x<(430-(y-68)*47/92))||(x>(430+(y-68)*47/92)))) ||
                          ((x>=120)&&(x<=240)&&(y>=230)&&(y<=290) &&
                           ((x<128)||(x>232)||(y<238)||(y>282))));
            default: ink_px = 1'b0;
            endcase
        end
    endfunction

    function clutter_px(input integer x, input integer y);
        begin
            clutter_px = ((x>=10)&&(x<=60)&&(y>=10)&&(y<=60)) ||
                         ((x>=580)&&(x<=630)&&(y>=300)&&(y<=350)) ||
                         ((x>=10)&&(x<=40)&&(y>=300)&&(y<=350));
        end
    endfunction

    function [7:0] pixel_g(input integer x, input integer y);
        begin
            if (paper_px(x,y)) begin
                pixel_g = ink_px(x,y) ? ink_g[7:0] : paper_g[7:0];
            end else if ((scene==3) && (x>=560)&&(x<=620)&&(y>=0)&&(y<=50)) begin
                pixel_g = 8'd255;
            end else if (clutter_px(x,y)) begin
                pixel_g = (bg_g > 30) ? (bg_g-25) : 8'd5;
            end else begin
                pixel_g = bg_g[7:0];
            end
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

    task show_result(input integer sc, input integer exp_n);
        integer cnt;
        begin
            n = 0;
            while (!w_done && n < 400000) begin @(posedge clk); #1; n=n+1; end
            #2000;
            cnt = 0;
            for (k=0;k<4;k=k+1) if (w_valid[k]) cnt=cnt+1;
            $display("SCENE %0d num=%0d valid=%b cls=%03x boxes=%0d ty=%0d max=%0d paper_v=%b paper=(%0d,%0d)-(%0d,%0d)",
                     sc, w_num, w_valid, w_cls, cnt, dut.ty_eff, dut.max_y_l,
                     dut.u_paper_gate.o_valid, dut.u_paper_gate.o_bx0, dut.u_paper_gate.o_by0,
                     dut.u_paper_gate.o_bx1, dut.u_paper_gate.o_by1);
            for (k=0;k<4;k=k+1)
                if (w_valid[k])
                    $display("  BOX%0d cls=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                             k, w_cls[3*k +: 3], w_bx0[11*k +: 11], w_by0[11*k +: 11],
                             w_bx1[11*k +: 11], w_by1[11*k +: 11]);
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        scene=0; paper_g=190; ink_g=45; bg_g=55;
        repeat(5) send_frame(); show_result(0,4);

        scene=1; paper_g=92; ink_g=50; bg_g=30;
        repeat(5) send_frame(); show_result(1,4);

        scene=2; paper_g=78; ink_g=45; bg_g=25;
        repeat(5) send_frame(); show_result(2,4);

        $display("PAPER E2E DONE");
        $finish;
    end
    always @(posedge clk) begin
        if (w_done)
            $display("  FRAME scene=%0d ty=%0d max_l=%0d num=%0d valid=%b paper_v=%b",
                     scene, dut.ty_eff, dut.max_y_l, w_num, w_valid, dut.u_paper_gate.o_valid);
    end
    initial begin
        #200000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end
endmodule
