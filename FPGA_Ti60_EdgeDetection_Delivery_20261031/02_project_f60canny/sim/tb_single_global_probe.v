`timescale 1ns/1ps
// Force the strict CCL path to produce no seeds.  Only the F29-compatible
// central-ROI global candidate may drive the polar classifier.
module tb_single_global_probe;
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
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(0), .PAPER_GATE_EN(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170), .i_lfg0(1'b0), .i_lfg1(1'b0),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    function in_circle(input integer x, input integer y);
        begin in_circle = ((x-50)*(x-50)+(y-60)*(y-60) <= 22*22); end
    endfunction
    function in_square(input integer x, input integer y);
        begin in_square = (x>=92)&&(x<=132)&&(y>=30)&&(y<=70); end
    endfunction
    function in_triangle(input integer x, input integer y);
        integer half;
        begin
            half = (y-25)*45/60;
            in_triangle = (y>=25)&&(y<=85)&&(x>=(230-half))&&(x<=(230+half));
        end
    endfunction
    function in_rect(input integer x, input integer y);
        begin in_rect = (x>=30)&&(x<=120)&&(y>=150)&&(y<=195); end
    endfunction

    integer which;
    function scene_fg(input integer x, input integer y);
        begin
            case (which)
            0: scene_fg = in_circle(x,y);
            1: scene_fg = in_square(x,y);
            2: scene_fg = in_triangle(x,y);
            default: scene_fg = in_rect(x,y);
            endcase
        end
    endfunction

    integer r, c, n, errs;
    reg [2:0] expect_cls;

    task send_frame;
        begin
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1;
                    i_g0 = scene_fg(2*c,   r) ? 8'd0 : 8'd255;
                    i_g1 = scene_fg(2*c+1, r) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0; i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            repeat (5) @(negedge clk);
        end
    endtask

    initial begin
        errs = 0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        for (which=0; which<4; which=which+1) begin
            case (which)
            0: expect_cls = 3'd1;
            1: expect_cls = 3'd2;
            2: expect_cls = 3'd3;
            default: expect_cls = 3'd5;
            endcase
            send_frame();
            n = 0;
            while (!w_done && n < 200000) begin @(posedge clk); #1; n = n + 1; end
            $display("GLOBAL %0d num=%0d valid=%b cls=%03x expect=%0d cycles=%0d",
                     which, w_num, w_valid, w_cls, expect_cls, n);
            $display("  dbg g_cnt=%0d bbox=(%0d,%0d)-(%0d,%0d) bw=%0d bh=%0d ok=%b strict0=%0d",
                     dut.u_grid.gs_cnt,
                     dut.u_grid.gs_minx, dut.u_grid.gs_miny,
                     dut.u_grid.gs_maxx, dut.u_grid.gs_maxy,
                     dut.u_grid.g_bw, dut.u_grid.g_bh,
                     dut.u_grid.global_ok, dut.u_grid.c_cnt[0]);
            if (!w_done || (w_num != 3'd1) || !w_valid[0] ||
                (w_cls[2:0] != expect_cls)) begin
                $display("GLOBAL %0d FAIL", which);
                errs = errs + 1;
            end
            repeat (10) @(negedge clk);
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
