//==============================================================================
// tb_adjust.v —— 检测框位置补偿 OSD 的最小自检 TB（iverilog -g2012）
//
//   覆盖两件事：
//     A) shape_adjust_osd：3 组不同 (xoff,yoff)
//          * 文字区域必须有非零像素
//          * 三组图案必须互不相同（签名 / 像素个数比较）
//          * 所有点亮像素必须落在 x<96（不压符号窗口）、y∈[18,61]（不压状态方块）
//          * 默认值 (22,3) 的关键点阵像素逐点核对（'X' '=' '2' 'Y' '3'）
//          * 打印一张 ASCII 点阵图，便于人眼确认字形
//     B) shape_osd：i_xoff / i_yoff 是否真的推动 bbox 检测框
//          * (xoff,yoff)=(22,3) → 框左上沿 x=98..99 / y=97..98
//          * (xoff,yoff)=(24,5) → 框左上沿 x=96..97 / y=95..96
//
//   运行（或直接跑 sim/run_adjust_checks.ps1）：
//     iverilog -g2012 -s tb_adjust -o sim/tb_adjust.vvp sim/tb_adjust.v \
//              rtl/edge/shape_adjust_osd.v rtl/edge/shape_osd.v
//     vvp sim/tb_adjust.vvp
//==============================================================================
`timescale 1ns/1ps

module tb_adjust;

    // 读数版式：第 1 行 y=18（避开 x24..79 / y8..15 的 4 个状态方块），第 2 行 y=42
    localparam [11:0] L1 = 12'd18;
    localparam [11:0] L2 = 12'd42;

    // ---------------- 时钟 / 公共激励 ----------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n = 1'b0;
    reg        de    = 1'b1;
    reg [10:0] x     = 11'd0;
    reg [11:0] y     = 12'd0;

    // ---------------- A) 文字读数 OSD ----------------
    reg  [5:0] xoff = 6'd22;
    reg  [4:0] yoff = 5'd3;
    wire [7:0] adj_px;
    wire       adj_on;

    shape_adjust_osd u_adj_osd (
        .clk    (clk),
        .rst_n  (rst_n),
        .i_de   (de),
        .i_x    (x),
        .i_y    (y),
        .i_xoff (xoff),
        .i_yoff (yoff),
        .o_px   (adj_px),
        .o_on   (adj_on)
    );

    // ---------------- B) shape_osd 检测框 ----------------
    reg        i_vs   = 1'b0;
    reg  [2:0] i_cls  = 3'd0;
    reg [10:0] bx0 = 11'd600, bx1 = 11'd700;
    reg [10:0] by0 = 11'd100, by1 = 11'd200;
    reg        box_en = 1'b1;
    reg  [3:0] bidx = 4'd0;
    reg [13:0] bcnt = 14'd0;
    wire [7:0] so_px, so_box, so_grid;

    shape_osd #(
        .GRID_OSD (0)
    ) u_shape_osd (
        .clk       (clk),
        .rst_n     (rst_n),
        .i_vs      (i_vs),
        .i_x       (x),
        .i_y       (y),
        .i_cls     (i_cls),
        .i_bx0     (bx0),
        .i_bx1     (bx1),
        .i_by0     (by0),
        .i_by1     (by1),
        .i_box_en  (box_en),
        .i_xoff    (xoff),
        .i_yoff    (yoff),
        .i_best_idx(bidx),
        .i_best_cnt(bcnt),
        .o_px      (so_px),
        .o_box     (so_box),
        .o_grid    (so_grid)
    );

    // ---------------- 计分 ----------------
    integer errors = 0;
    integer lit_cnt;
    integer lit_maxx;
    integer lit_miny, lit_maxy;
    reg [63:0] sig;
    reg [63:0] sig_a, sig_b, sig_c;
    integer    cnt_a, cnt_b, cnt_c;

    // 扫描 x=0..159 / y=0..63，统计文字像素
    task text_metrics;
        input  [5:0] xo;
        input  [4:0] yo;
        output integer cnt;
        output integer mxx;
        output integer mny;
        output integer mxy;
        output [63:0] sg;
        integer xx, yy;
        begin
            xoff = xo;
            yoff = yo;
            cnt  = 0;
            mxx  = 0;
            mny  = 4095;
            mxy  = 0;
            sg   = 64'h0;
            for (yy = 0; yy < 64; yy = yy + 1) begin
                for (xx = 0; xx < 160; xx = xx + 1) begin
                    x = xx[10:0];
                    y = yy[11:0];
                    #1;
                    if (adj_px != 8'h00) begin
                        cnt = cnt + 1;
                        if (xx > mxx) mxx = xx;
                        if (yy < mny) mny = yy;
                        if (yy > mxy) mxy = yy;
                        sg = sg * 64'd1099511628211 + {52'd0, xx} * 64'd131 + {52'd0, yy};
                    end
                end
            end
        end
    endtask

    // 单点读文字像素 / 单元标志
    task text_pix;
        input  [10:0] xx;
        input  [11:0] yy;
        output        p;
        output        o;
        begin
            x = xx; y = yy; #1;
            p = (adj_px != 8'h00);
            o = adj_on;
        end
    endtask

    // 单点读 bbox 检测框
    task box_pix;
        input  [10:0] xx;
        input  [11:0] yy;
        output        p;
        begin
            x = xx; y = yy; #1;
            p = (so_box != 8'h00);
        end
    endtask

    // 打印 ASCII 点阵（x 6..73 / y 16..63）
    task show_art;
        integer xx, yy;
        begin
            $display("---- ASCII art: x=6..73, y=16..63 ('#' = lit) ----");
            for (yy = 16; yy < 64; yy = yy + 1) begin
                $write("y=%03d ", yy);
                for (xx = 6; xx < 74; xx = xx + 1) begin
                    x = xx[10:0];
                    y = yy[11:0];
                    #1;
                    $write("%c", (adj_px != 8'h00) ? "#" : ".");
                end
                $write("\n");
            end
        end
    endtask

    reg p, o;
    reg bx;

    initial begin
        $dumpfile("sim/tb_adjust.vcd");
        $dumpvars(0, tb_adjust);

        #20 rst_n = 1'b1;
        #20;

        //======================================================================
        // A) 三组数值 -> 文字点阵
        //======================================================================
        $display("==============================================================");
        $display(" A) shape_adjust_osd : X=nn / Y=nn dot-matrix");
        $display("==============================================================");

        text_metrics(6'd22, 5'd3, cnt_a, lit_maxx, lit_miny, lit_maxy, sig_a);
        $display("case1 (xoff=22,yoff=3) : pixels=%0d  x_max=%0d  y=[%0d..%0d]  sig=%016h",
                 cnt_a, lit_maxx, lit_miny, lit_maxy, sig_a);
        if (cnt_a <= 0) begin
            $display("  FAIL: case1 no lit pixel");
            errors = errors + 1;
        end
        if (lit_maxx >= 96) begin
            $display("  FAIL: case1 lit pixel at x=%0d overlaps symbol window (x>=96)", lit_maxx);
            errors = errors + 1;
        end
        if (lit_miny < L1 || lit_maxy > (L2 + 12'd19)) begin
            $display("  FAIL: case1 y range [%0d..%0d] outside [%0d..%0d]",
                     lit_miny, lit_maxy, L1, L2 + 12'd19);
            errors = errors + 1;
        end

        // 逐点核对默认值 22 / 3 的字符：X = 2 2 (行1) / Y = 3 (行2)
        // 每个点 4x4，字符 3 点宽 12 px、字距 16 px；行高 20 px
        text_pix(11'd8,  L1, p, o);            if (!(p && o)) begin $display("  FAIL: 'X' row0 dot0 (8,L1) not lit");        errors=errors+1; end
        text_pix(11'd12, L1, p, o);            if (p || !o)   begin $display("  FAIL: 'X' row0 dot1 (12,L1) should be blank-in-cell"); errors=errors+1; end
        text_pix(11'd16, L1, p, o);            if (!p)        begin $display("  FAIL: 'X' row0 dot2 (16,L1) not lit");        errors=errors+1; end
        text_pix(11'd12, L1 + 12'd8, p, o);    if (!p)        begin $display("  FAIL: 'X' row2 center (12,L1+8) not lit");    errors=errors+1; end
        text_pix(11'd20, L1, p, o);            if (p || o)    begin $display("  FAIL: gap (20,L1) should be empty");          errors=errors+1; end

        text_pix(11'd24, L1, p, o);            if (p)         begin $display("  FAIL: '=' row0 (24,L1) should be blank");      errors=errors+1; end
        text_pix(11'd24, L1 + 12'd4, p, o);    if (!p)        begin $display("  FAIL: '=' row1 (24,L1+4) not lit");           errors=errors+1; end
        text_pix(11'd24, L1 + 12'd12, p, o);   if (!p)        begin $display("  FAIL: '=' row3 (24,L1+12) not lit");          errors=errors+1; end

        text_pix(11'd40, L1, p, o);            if (!p)        begin $display("  FAIL: '2' tens row0 (40,L1) not lit");         errors=errors+1; end
        text_pix(11'd40, L1 + 12'd4, p, o);    if (p)         begin $display("  FAIL: '2' row1 (40,L1+4) should be blank");    errors=errors+1; end
        text_pix(11'd48, L1 + 12'd4, p, o);    if (!p)        begin $display("  FAIL: '2' row1 right dot (48,L1+4) not lit"); errors=errors+1; end
        text_pix(11'd40, L1 + 12'd12, p, o);   if (!p)        begin $display("  FAIL: '2' row3 left dot (40,L1+12) not lit"); errors=errors+1; end
        text_pix(11'd48, L1 + 12'd12, p, o);   if (p)         begin $display("  FAIL: '2' row3 right dot (48,L1+12) should be blank"); errors=errors+1; end
        text_pix(11'd56, L1, p, o);            if (!p)        begin $display("  FAIL: '2' ones (56,L1) not lit");             errors=errors+1; end

        text_pix(11'd8,  L2, p, o);            if (!p)        begin $display("  FAIL: 'Y' row0 dot0 (8,L2) not lit");         errors=errors+1; end
        text_pix(11'd12, L2, p, o);            if (p)         begin $display("  FAIL: 'Y' row0 dot1 (12,L2) should be blank"); errors=errors+1; end
        text_pix(11'd12, L2 + 12'd8, p, o);    if (!p)        begin $display("  FAIL: 'Y' row2 center (12,L2+8) not lit");    errors=errors+1; end
        text_pix(11'd24, L2, p, o);            if (p)         begin $display("  FAIL: '=' row0 line2 (24,L2) should be blank"); errors=errors+1; end
        text_pix(11'd24, L2 + 12'd4, p, o);    if (!p)        begin $display("  FAIL: '=' row1 line2 (24,L2+4) not lit");     errors=errors+1; end
        text_pix(11'd40, L2, p, o);            if (p || !o)   begin $display("  FAIL: blank tens of yoff=3 (40,L2) should be blank-in-cell"); errors=errors+1; end
        text_pix(11'd40, L2 + 12'd4, p, o);    if (p)         begin $display("  FAIL: blank tens of yoff=3 (40,L2+4) should be blank-in-cell"); errors=errors+1; end
        text_pix(11'd56, L2, p, o);            if (!p)        begin $display("  FAIL: '3' row0 (56,L2) not lit");             errors=errors+1; end
        text_pix(11'd56, L2 + 12'd4, p, o);    if (p)         begin $display("  FAIL: '3' row1 left (56,L2+4) should be blank"); errors=errors+1; end
        text_pix(11'd64, L2 + 12'd4, p, o);    if (!p)        begin $display("  FAIL: '3' row1 right (64,L2+4) not lit");   errors=errors+1; end
        text_pix(11'd8,  L1 + 12'd20, p, o);   if (p || o)    begin $display("  FAIL: inter-line gap (8,L1+20) should be empty"); errors=errors+1; end

        // 状态方块区（x 24..79 / y 8..15）必须完全没有文字像素
        text_pix(11'd24, 12'd8,  p, o);        if (p || o)    begin $display("  FAIL: readout touched status square (24,8)"); errors=errors+1; end
        text_pix(11'd56, 12'd12, p, o);        if (p || o)    begin $display("  FAIL: readout touched status square (56,12)"); errors=errors+1; end

        show_art;

        text_metrics(6'd24, 5'd4, cnt_b, lit_maxx, lit_miny, lit_maxy, sig_b);
        $display("case2 (xoff=24,yoff=4) : pixels=%0d  x_max=%0d  y=[%0d..%0d]  sig=%016h",
                 cnt_b, lit_maxx, lit_miny, lit_maxy, sig_b);
        if (cnt_b <= 0) begin
            $display("  FAIL: case2 no lit pixel");
            errors = errors + 1;
        end

        text_metrics(6'd5, 5'd12, cnt_c, lit_maxx, lit_miny, lit_maxy, sig_c);
        $display("case3 (xoff=5, yoff=12) : pixels=%0d  x_max=%0d  y=[%0d..%0d]  sig=%016h",
                 cnt_c, lit_maxx, lit_miny, lit_maxy, sig_c);
        if (cnt_c <= 0) begin
            $display("  FAIL: case3 no lit pixel");
            errors = errors + 1;
        end

        if (sig_a == sig_b || sig_b == sig_c || sig_a == sig_c) begin
            $display("  FAIL: two of the three value patterns are identical");
            errors = errors + 1;
        end else begin
            $display("  OK  : three value patterns are all different");
        end

        //======================================================================
        // B) 补偿量确实推动 bbox 框
        //======================================================================
        $display("==============================================================");
        $display(" B) shape_osd : bbox follows i_xoff / i_yoff");
        $display("==============================================================");

        // 锁存 bbox（600..700 / 100..200）
        xoff = 6'd22; yoff = 5'd3;
        @(negedge clk); i_vs = 1'b1;
        @(negedge clk); i_vs = 1'b0;
        @(negedge clk);

        // ox0 = 600-480-22 = 98 ; oy0 = 100-3 = 97
        box_pix(11'd98,  12'd150, bx); $display("  xoff=22 : (98,150) box=%0d (expect 1)", bx); if (!bx) begin errors=errors+1; $display("  FAIL"); end
        box_pix(11'd96,  12'd150, bx); $display("  xoff=22 : (96,150) box=%0d (expect 0)", bx); if (bx)  begin errors=errors+1; $display("  FAIL"); end
        box_pix(11'd150, 12'd97,  bx); $display("  yoff=3  : (150,97) box=%0d (expect 1)", bx); if (!bx) begin errors=errors+1; $display("  FAIL"); end
        box_pix(11'd150, 12'd95,  bx); $display("  yoff=3  : (150,95) box=%0d (expect 0)", bx); if (bx)  begin errors=errors+1; $display("  FAIL"); end

        xoff = 6'd24; yoff = 5'd5;
        @(negedge clk);

        // ox0 = 600-480-24 = 96 ; oy0 = 100-5 = 95
        box_pix(11'd96,  12'd150, bx); $display("  xoff=24 : (96,150) box=%0d (expect 1)", bx); if (!bx) begin errors=errors+1; $display("  FAIL"); end
        box_pix(11'd98,  12'd150, bx); $display("  xoff=24 : (98,150) box=%0d (expect 0)", bx); if (bx)  begin errors=errors+1; $display("  FAIL"); end
        box_pix(11'd150, 12'd95,  bx); $display("  yoff=5  : (150,95) box=%0d (expect 1)", bx); if (!bx) begin errors=errors+1; $display("  FAIL"); end
        box_pix(11'd150, 12'd97,  bx); $display("  yoff=5  : (150,97) box=%0d (expect 0)", bx); if (bx)  begin errors=errors+1; $display("  FAIL"); end

        //======================================================================
        $display("==============================================================");
        if (errors == 0)
            $display(" RESULT: PASS  (all checks OK)");
        else
            $display(" RESULT: FAIL  (%0d error(s))", errors);
        $display("==============================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;
        $display(" RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
