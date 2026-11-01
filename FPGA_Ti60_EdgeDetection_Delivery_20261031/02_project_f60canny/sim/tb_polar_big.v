`timescale 1ns/1ps
// Feature probe for paper-sized filled and outline shapes on a 4px block map.
module tb_polar_big;
    localparam integer HP = 160;   // 320 px
    localparam integer VL = 240;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;
    reg i_start = 1'b0;

    wire [2:0] g_num;
    wire [3:0] g_valid;
    wire [43:0] g_bx0, g_bx1, g_by0, g_by1;
    wire [107:0] g_sx, g_sy;
    wire [63:0] g_area;
    wire g_done;

    wire [2:0] p_cls;
    wire p_upd;
    wire [7:0] p_cov, p_rmin;
    wire [15:0] p_s;

    reg [15:0] sel_area;
    reg [26:0] sel_sx, sel_sy;
    reg [10:0] sel_bx0, sel_bx1, sel_by0, sel_by1;
    always @* begin
        sel_area=g_area[15:0];   sel_sx=g_sx[26:0];   sel_sy=g_sy[26:0];
        sel_bx0=g_bx0[10:0];  sel_bx1=g_bx1[10:0];
        sel_by0=g_by0[10:0];  sel_by1=g_by1[10:0];
    end

    shape_grid_multi_v2 #(
        .H_PAIRS(HP), .V_LINES(VL), .GRID_X(8), .GRID_Y(6),
        .CELL_SEED_MIN(2), .CELL_MERGE_MIN(1), .MIN_AREA(8), .MIN_BBOX(4),
        .FILL_MIN(2), .MERGE_GAP(1)
    ) u_grid (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170),
        .i_gate_en(1'b0), .i_gx0(11'd0), .i_gx1(11'd0),
        .i_gy0(11'd0), .i_gy1(11'd0),
        .o_num(g_num), .o_valid(g_valid),
        .o_bx0(g_bx0), .o_bx1(g_bx1), .o_by0(g_by0), .o_by1(g_by1),
        .o_sx(g_sx), .o_sy(g_sy), .o_area(g_area), .o_done(g_done)
    );

    shape_polar #(
        .H_PAIRS(HP), .V_LINES(VL), .BLK_SHIFT(2), .NRAY(128),
        .GAP_TOL(3), .MIN_AREA(8), .MIN_BBOX(16), .COV_MIN(80),
        .CAND_MODE(1)
    ) u_polar (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_start(i_start), .i_roi(1'b1), .i_g0(i_g0), .i_g1(i_g1),
        .i_ty(8'd170),
        .i_sx(sel_sx), .i_sy(sel_sy), .i_area(sel_area),
        .i_bx0(sel_bx0), .i_bx1(sel_bx1), .i_by0(sel_by0), .i_by1(sel_by1),
        .i_valid(1'b1),
        .o_cls(p_cls), .o_upd(p_upd),
        .o_blk_cov(), .o_blk_bx0(), .o_blk_bx1(), .o_blk_by0(), .o_blk_by1(),
        .o_dbg_cov(p_cov), .o_dbg_rmin(p_rmin), .o_dbg_s(p_s)
    );

    integer scene;
    function in_circle(input integer x, input integer y);
        begin in_circle = ((x-90)*(x-90)+(y-120)*(y-120) <= 70*70); end
    endfunction
    function in_square(input integer x, input integer y);
        begin in_square = (x>=170)&&(x<=300)&&(y>=50)&&(y<=180); end
    endfunction
    function in_triangle(input integer x, input integer y);
        integer half;
        begin
            half = (y-45)*80/150;
            in_triangle = (y>=45)&&(y<=195)&&(x>=(240-half))&&(x<=(240+half));
        end
    endfunction
    function in_rect(input integer x, input integer y);
        begin in_rect = (x>=40)&&(x<=280)&&(y>=170)&&(y<=220); end
    endfunction
    // outline versions: keep a border of 8 px inside the filled footprint
    function rim_circle(input integer x, input integer y);
        integer d2;
        begin d2=(x-90)*(x-90)+(y-120)*(y-120);
            rim_circle = (d2 <= 70*70) && (d2 >= 62*62); end
    endfunction
    function rim_square(input integer x, input integer y);
        begin rim_square = (x>=170)&&(x<=300)&&(y>=50)&&(y<=180) &&
               ((x<178)||(x>292)||(y<58)||(y>172)); end
    endfunction
    function rim_triangle(input integer x, input integer y);
        integer half, halfin;
        begin
            half = (y-45)*80/150;
            halfin = ((y-53)*64/134 > 0) ? ((y-53)*64/134) : 0;
            rim_triangle = (y>=45)&&(y<=195)&&
                (x>=(240-half))&&(x<=(240+half)) &&
                ((y<53)||(x<(240-halfin))||(x>(240+halfin)));
        end
    endfunction
    function rim_rect(input integer x, input integer y);
        begin rim_rect = (x>=40)&&(x<=280)&&(y>=170)&&(y<=220) &&
               ((x<48)||(x>272)||(y<178)||(y>212)); end
    endfunction
    function small_rim_circle(input integer x, input integer y);
        integer d2;
        begin d2=(x-50)*(x-50)+(y-60)*(y-60);
            small_rim_circle = (d2 <= 22*22) && (d2 >= 18*18); end
    endfunction
    function small_rim_square(input integer x, input integer y);
        begin small_rim_square = (x>=90)&&(x<=134)&&(y>=40)&&(y<=84) &&
               ((x<94)||(x>130)||(y<44)||(y>80)); end
    endfunction
    function small_rim_tri(input integer x, input integer y);
        integer half, halfin;
        begin
            half = (y-30)*22/44;
            halfin = ((y-34)*18/36 > 0) ? ((y-34)*18/36) : 0;
            small_rim_tri = (y>=30)&&(y<=74)&&(x>=(240-half))&&(x<=(240+half)) &&
                ((y<34)||(x<(240-halfin))||(x>(240+halfin)));
        end
    endfunction
    function scene_fg(input integer x, input integer y);
        begin
            case (scene)
            0: scene_fg = in_circle(x,y);
            1: scene_fg = in_square(x,y);
            2: scene_fg = in_triangle(x,y);
            3: scene_fg = in_rect(x,y);
            4: scene_fg = rim_circle(x,y);
            5: scene_fg = rim_square(x,y);
            6: scene_fg = rim_triangle(x,y);
            7: scene_fg = rim_rect(x,y);
            8: scene_fg = small_rim_circle(x,y);
            9: scene_fg = small_rim_square(x,y);
            10: scene_fg = small_rim_tri(x,y);
            default: scene_fg = 1'b0;
            endcase
        end
    endfunction

    integer r,c,k,n,errs;
    reg got;

    task send_frame;
        begin
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de=1'b1;
                    i_g0 = scene_fg(2*c,  r) ? 8'd0 : 8'd255;
                    i_g1 = scene_fg(2*c+1,r) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de=1'b0; i_g0=8'd255; i_g1=8'd255;
                repeat(40) @(negedge clk);
            end
            i_vs=1'b1; repeat(5) @(negedge clk); i_vs=1'b0;
            repeat(5) @(negedge clk);
        end
    endtask

    task classify;
        begin
            n=0;
            while (!g_done && n<200000) begin @(posedge clk); #1; n=n+1; end
            if (!g_done || !g_valid[0]) begin
                $display("SCENE %0d NO CAND g_done=%b num=%0d valid=%b", scene, g_done, g_num, g_valid);
                errs=errs+1;
            end else begin
                repeat(2) @(negedge clk);
                i_start=1'b1; @(posedge clk); #1; i_start=1'b0;
                n=0;
                while (!p_upd && n<50000) begin @(posedge clk); #1; n=n+1; end
                $display("SCENE %0d cls=%0d cov=%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d",
                         scene, p_cls, p_cov, sel_bx0, sel_by0, sel_bx1, sel_by1, sel_area);
                $display("  e2=%0d e3=%0d e4=%0d stot=%0d sq=%0d cvn=%0d rmin=%0d bw=%0d bh=%0d mapb=%0d",
                         u_polar.e2, u_polar.e3, u_polar.e4, u_polar.s_total,
                         u_polar.sq_s, u_polar.cv_n, u_polar.rmin,
                         u_polar.bbox_w, u_polar.bbox_h,
                         (u_polar.bbox_w+3)/4*((u_polar.bbox_h+3)/4));
                if (p_cls==0) errs=errs+1;
            end
            repeat(8) @(negedge clk);
        end
    endtask

    initial begin
        errs=0;
        repeat(10) @(negedge clk);
        rst_n=1'b1;
        repeat(10) @(negedge clk);
        for (scene=0; scene<11; scene=scene+1) begin
            send_frame();
            classify();
        end
        $display("BIG SHAPE PROBE DONE errs=%0d", errs);
        $finish;
    end
    initial begin
        #60000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end
endmodule
