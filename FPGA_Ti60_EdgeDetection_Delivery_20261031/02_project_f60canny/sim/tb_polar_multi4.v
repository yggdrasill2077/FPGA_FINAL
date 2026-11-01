`timescale 1ns/1ps
module tb_polar_multi4;
    localparam integer HP = 160;      // 320 px
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

    reg [1:0] csel;
    reg [15:0] sel_area;
    reg [26:0] sel_sx, sel_sy;
    reg [10:0] sel_bx0, sel_bx1, sel_by0, sel_by1;
    always @* begin
        case (csel)
        2'd0: begin sel_area=g_area[15:0];   sel_sx=g_sx[26:0];   sel_sy=g_sy[26:0];   sel_bx0=g_bx0[10:0];  sel_bx1=g_bx1[10:0];  sel_by0=g_by0[10:0];  sel_by1=g_by1[10:0];  end
        2'd1: begin sel_area=g_area[31:16];  sel_sx=g_sx[53:27];  sel_sy=g_sy[53:27];  sel_bx0=g_bx0[21:11]; sel_bx1=g_bx1[21:11]; sel_by0=g_by0[21:11]; sel_by1=g_by1[21:11]; end
        2'd2: begin sel_area=g_area[47:32];  sel_sx=g_sx[80:54];  sel_sy=g_sy[80:54];  sel_bx0=g_bx0[32:22]; sel_bx1=g_bx1[32:22]; sel_by0=g_by0[32:22]; sel_by1=g_by1[32:22]; end
        default: begin sel_area=g_area[63:48]; sel_sx=g_sx[107:81]; sel_sy=g_sy[107:81]; sel_bx0=g_bx0[43:33]; sel_bx1=g_bx1[43:33]; sel_by0=g_by0[43:33]; sel_by1=g_by1[43:33]; end
        endcase
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
    function scene_fg(input integer x, input integer y);
        begin scene_fg = in_circle(x,y)||in_square(x,y)||in_triangle(x,y)||in_rect(x,y); end
    endfunction

    integer r,c,k,n,errs;
    integer ncls;
    integer rr,cc;
    reg [86:0] rec;
    reg got1,got2,got3,got5;

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

    task classify(input integer idx);
        begin
            csel = idx[1:0];
            repeat(2) @(negedge clk);
            i_start=1'b1;
            @(posedge clk); #1;
            i_start=1'b0;
            n=0;
            while (!p_upd && n<50000) begin @(posedge clk); #1; n=n+1; end
            if (!p_upd) begin
                $display("CAND %0d TIMEOUT area=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                         idx, sel_area, sel_bx0, sel_by0, sel_bx1, sel_by1);
                errs=errs+1;
            end else begin
                $display("CAND %0d cls=%0d cov=%0d cyc=%0d area=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                         idx, p_cls, p_cov, n, sel_area,
                         sel_bx0, sel_by0, sel_bx1, sel_by1);
                if (p_cls==1) got1=1;
                if (p_cls==2) got2=1;
                if (p_cls==3) got3=1;
                if (p_cls==5) got5=1;
                if (p_cls!=0) ncls=ncls+1;
            end
            repeat(8) @(negedge clk);
        end
    endtask

    initial begin
        errs=0; ncls=0; got1=0; got2=0; got3=0; got5=0;
        csel=0;
        repeat(10) @(negedge clk);
        rst_n=1'b1;
        repeat(10) @(negedge clk);
        send_frame();
        n=0;
        while (!g_done && n<20000) begin @(posedge clk); #1; n=n+1; end
        if (!g_done) begin
            $display("GRID TIMEOUT");
            errs=errs+1;
        end else begin
            $display("MULTI FRAME num=%0d valid=%b", g_num, g_valid);
            for (rr=0; rr<6; rr=rr+1) begin
                for (cc=0; cc<8; cc=cc+1) begin
                    rec = u_grid.cell_ram[rr*8+cc];
                    if (rec[86:75] != 0)
                        $display("CELL r%0d c%0d cnt=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                                 rr, cc, rec[86:75], rec[35:27], rec[17:9], rec[26:18], rec[8:0]);
                end
            end
            for (k=0;k<4;k=k+1)
                if (g_valid[k]) classify(k);
            $display("CLASS FLAGS circle=%0d square=%0d triangle=%0d rect=%0d ncls=%0d",
                     got1,got2,got3,got5,ncls);
            if (!(got1&&got2&&got3&&got5&&ncls==4)) begin
                $display("MULTI CLASS SET FAIL");
                errs=errs+1;
            end
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end

    initial begin
        #20000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end
endmodule
