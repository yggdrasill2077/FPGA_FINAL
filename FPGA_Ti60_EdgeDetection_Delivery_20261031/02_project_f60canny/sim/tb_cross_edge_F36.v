`timescale 1ns/1ps
// Paper-carrier regression: distant sheet, tabletop background, empty paper,
// and no-paper scenes.  Frames are continuous, matching a live camera stream.
module tb_cross_edge_F36;
    localparam integer HP = 160;      // 320 px
    localparam integer VL = 240;

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
        .GRID_X(8), .GRID_Y(6),
        .CELL_SEED_MIN(1000), .CELL_MERGE_MIN(1),
        .MIN_AREA(8), .MIN_BBOX(4), .FILL_MIN(2), .MERGE_GAP(1),
        .GLOBAL_ROI_PCT(8), .GLOBAL_MIN_BLOCKS(8),
        .GLOBAL_MIN_BBOX(8), .GLOBAL_FILL_MIN(24),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(72), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(1),
        .TY_MARGIN(8'd20), .TY_CAP(8'd110), .TY_FLOOR(8'd24),
        .LOCAL_FG_EN(0), .PAPER_GATE_EN(1), .PAPER_ERODE(8), .EDGE_CAND_EN(1), .EDGE_PIX_TH(24), .EDGE_BLOCK_MIN(2), .KEEP_UNKNOWN(0),
        .PAPER_MIN_SAMPLES(32), .PAPER_MIN_SIZE(32), .PAPER_FILL_MIN(64)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1),
        .i_ty(8'd170), .i_lfg0(1'b0), .i_lfg1(1'b0),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    integer scene;
    integer px, py;

    function paper_px;
        input integer x;
        input integer y;
        begin
            case (scene)
            0, 1: paper_px = (x>=60)&&(x<=259)&&(y>=40)&&(y<=199); // 200x160
            2:    paper_px = (x>=100)&&(x<=219)&&(y>=75)&&(y<=164); // 120x90, distant
            3:    paper_px = (x>=60)&&(x<=259)&&(y>=40)&&(y<=199); // empty sheet
            4, 5: paper_px = 1'b0;                                // no sheet
            default: paper_px = 1'b0;
            endcase
        end
    endfunction

    function ink_px;
        input integer x;
        input integer y;
        begin
            case (scene)
            0: ink_px = (((x>=125)&&(x<=195)&&(y>=105)&&(y<=135)) || ((x>=145)&&(x<=175)&&(y>=85)&&(y<=155)));
            1: ink_px = (x>=125)&&(x<=195)&&(y>=85)&&(y<=155);
            2: ink_px = ((x-160)*(x-160)+(y-120)*(y-120) <= 28*28);
            3: ink_px = 1'b0;
            4: ink_px = (x>=80)&&(x<=239)&&(y>=70)&&(y<=180); // large dark tabletop shadow
            5: ink_px = 1'b0;
            default: ink_px = 1'b0;
            endcase
        end
    endfunction

    function [7:0] pixel_g;
        input integer x;
        input integer y;
        begin
            if (paper_px(x,y))      pixel_g = ink_px(x,y) ? 8'd45 : 8'd125;
            else if (scene==4)      pixel_g = ink_px(x,y) ? 8'd30 : 8'd75;
            else                    pixel_g = 8'd60;
        end
    endfunction

    integer r, c, n;
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
                i_de = 1'b0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (20) @(negedge clk);
            end
        end
    endtask

    task check_scene(input integer sc, input [2:0] exp_num, input [2:0] exp_cls);
        begin
            scene = sc;
            repeat (3) send_frame();
            n = 0;
            while (!w_done && n < 200000) begin @(posedge clk); #1; n = n + 1; end
            #1000;
            $display("  POLAR cov=%0d rmin=%0d s=%0d e2=%0d e3=%0d e4=%0d sq=%0d fill=%0d", dut.u_polar.cov, dut.u_polar.rmin, dut.u_polar.s_total, dut.u_polar.e2, dut.u_polar.e3, dut.u_polar.e4, dut.u_polar.sq_s, dut.u_polar.fill_cnt);
            $display("SCENE %0d num=%0d valid=%b cls=%03x bbox=(%0d,%0d)-(%0d,%0d) paper=%b pbox=(%0d,%0d)-(%0d,%0d)",
                     sc, w_num, w_valid, w_cls,
                     w_bx0[10:0], w_by0[10:0], w_bx1[10:0], w_by1[10:0],
                     dut.paper_valid,
                     dut.paper_bx0, dut.paper_by0, dut.paper_bx1, dut.paper_by1);
            $display("  gate cnt=%0d min=(%0d,%0d) max=(%0d,%0d) ty=%0d max_l=%0d",
                     dut.u_paper_gate.cnt,
                     dut.u_paper_gate.minx, dut.u_paper_gate.miny,
                     dut.u_paper_gate.maxx, dut.u_paper_gate.maxy,
                     dut.ty_eff, dut.max_y_l);
            $display("  gs cnt=%0d bbox=(%0d,%0d)-(%0d,%0d) raw=(%0d,%0d)-(%0d,%0d) c0=%0d",
                     dut.u_grid.gs_cnt,
                     dut.u_grid.gs_minx, dut.u_grid.gs_miny,
                     dut.u_grid.gs_maxx, dut.u_grid.gs_maxy,
                     dut.u_grid.g_minx, dut.u_grid.g_miny,
                     dut.u_grid.g_maxx, dut.u_grid.g_maxy,
                     dut.u_grid.c_cnt[0]);
            if ((w_num != exp_num) || (w_valid[0] != (exp_num != 0)) ||
                ((exp_num != 0) && (w_cls[2:0] != exp_cls))) begin
                $display("SCENE %0d FAIL", sc);
            end
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        check_scene(0, 3'd1, 3'd4); // large paper + cross
        $display("CROSS EDGE F36 TEST DONE");
        $finish;
    end
endmodule




