//==============================================================================
// tb_align.v —— 三路显示行对齐测量（P1-2 验证）
//
//   复刻顶层的数据接线关系：
//      源行 s ──┬─> median3x3_2px ──> edge_canny_2px.i_g   （中值，内容中心已上移 1 行）
//               └─> 打 2 拍 ────────> edge_canny_2px.i_rgb （debayer 原始行）
//   edge_canny_2px 的三个输出分别喂显示：
//      o_bg  → 左半灰度   o_rgb → 右半彩色   o_e → 红色边缘叠加
//
//   测法：整幅黑底，在第 R..R+1 行画一条**整行白条**（2 行厚）。
//     * o_bg / o_rgb 是像素值 → 白条出现在哪几行，就说明该路的"内容行"
//     * o_e 是二值边缘 → 白条的水平上下沿会在 content 行 R-1 / R+2 各出一条
//   输出行号用 o_de 计数（三路共用同一个 o_de），列方向固定取第 10 对像素，
//   避开行首/行尾的流水线污染。
//
//   期望（改前）：
//       o_rgb  内容行 = s-3   （rgbfifo 3 行）
//       o_e    内容行 = s-4   （win_gray + win_band + win_mag 各 1 行，o_bg 的 FIFO 不参与）
//       o_bg   内容行 = s-5   （中值 1 行 + win_gray 1 行 + bgfifo 3 行）
//   改后目标：三路都等于 s-4（彩色 +1 行、灰度 -1 行），接缝与红边都不再错行。
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -s tb_align -o sim/tb_align.vvp sim/tb_align.v \
//              rtl/median3x3_2px.v rtl/edge/edge_canny_2px.v rtl/edge/win3x3_2px.v \
//              rtl/edge/sobel_3x3.v rtl/simple_dual_port_ram.v
//     vvp sim/tb_align.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_align;

    localparam integer HP   = 64;     // 每行像素对
    localparam integer VL   = 40;     // 行数
    localparam integer R    = 12;     // 阶跃行（源行 R 起全白，R 之前全黑）
    localparam integer GAP  = 6;      // 行间空闲拍
    localparam [11:0]  THR  = 12'd400;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        i_de = 1'b0;
    reg        i_hs = 1'b0;
    reg        i_vs = 1'b0;
    reg [7:0]  i_g0 = 8'd0;
    reg [7:0]  i_g1 = 8'd0;
    reg [47:0] i_rgb = 48'd0;

    // ---------------- 中值（与顶层一致：i_vs 接 rgb_vs 电平，这里用行同步脉冲）----
    wire        m_de, m_hs, m_vs, m_va;
    wire [7:0]  m_g0, m_g1;

    median3x3_2px u_median3x3 (
        .clk    (clk),
        .rst_n  (rst_n),
        .i_de   (i_de),
        .i_hs   (i_hs),
        .i_vs   (i_vs),
        .i_valid(i_de),
        .i_g0   (i_g0),
        .i_g1   (i_g1),
        .o_de   (m_de),
        .o_hs   (m_hs),
        .o_vs   (m_vs),
        .o_valid(m_va),
        .o_g0   (m_g0),
        .o_g1   (m_g1)
    );

    // ---------------- 彩色打 2 拍（顶层 rgb_in_d1/d2 → rgb_in_al）----------------
    reg [47:0] rgb_d1, rgb_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rgb_d1 <= 48'd0; rgb_d2 <= 48'd0; end
        else begin rgb_d1 <= i_rgb; rgb_d2 <= rgb_d1; end
    end

    // ---------------- 边缘引擎 ----------------
    wire        c_de, c_hs, c_vs;
    wire [1:0]  c_e;
    wire [15:0] c_osd, c_bg;
    wire [47:0] c_rgb;

    edge_canny_2px #(
        .H_PAIRS    (HP),
        .ADDR_W     (7),
        .T2_SHIFT   (2),
        .HYST_SHIFT (4)
    ) u_edge_canny (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_de       (m_de),
        .i_hs       (m_hs),
        .i_vs       (m_vs),
        .i_g0       (m_g0),
        .i_g1       (m_g1),
        .i_threshold(THR),
        .o_de       (c_de),
        .o_hs       (c_hs),
        .o_vs       (c_vs),
        .o_e        (c_e),
        .o_osd      (c_osd),
        .o_bg       (c_bg),
        .o_rgb      (c_rgb),
        .i_rgb      (rgb_d2)
    );

    // ---------------- 输出行号 / 列号计数 ----------------
    reg        de_q;
    integer    orow;
    integer    ocol;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin de_q <= 1'b0; orow <= -1; ocol <= 0; end
        else begin
            de_q <= c_de;
            if (c_de && !de_q) begin          // 行起始 → 行号 +1
                orow <= orow + 1;
                ocol <= 0;
            end else if (c_de) begin
                ocol <= ocol + 1;
            end
        end
    end

    // 采样结果
    integer first_bg, first_rgb, first_e, last_e;
    integer n_bg, n_rgb, n_e;
    integer e_sum, e_cen;
    reg [7:0] bg_seen [0:VL+8];
    reg [7:0] rgb_seen[0:VL+8];
    reg [1:0] e_seen  [0:VL+8];

    // 横向相位：每一行里第一次出现白/边缘的列号（-1 = 该行没有）
    integer col_bg  [0:VL+8];
    integer col_rgb [0:VL+8];
    integer col_e   [0:VL+8];
    integer i;
    initial begin
        for (i = 0; i <= VL + 8; i = i + 1) begin
            col_bg[i] = -1; col_rgb[i] = -1; col_e[i] = -1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_bg = -1; first_rgb = -1; first_e = -1; last_e = -1;
            n_bg = 0; n_rgb = 0; n_e = 0; e_sum = 0;
        end else if (c_de && orow >= 0 && orow <= VL + 8) begin
            if (c_bg[7:0]  > 8'd128 && col_bg[orow]  < 0) col_bg[orow]  = ocol;
            if (c_rgb[7:0] > 8'd128 && col_rgb[orow] < 0) col_rgb[orow] = ocol;
            if (c_e        != 2'd0  && col_e[orow]   < 0) col_e[orow]   = ocol;
        end
        if (!rst_n) begin
            // 保持上面的复位
        end else if (c_de && ocol == 10 && orow >= 0 && orow <= VL + 8) begin
            bg_seen[orow]  = c_bg[7:0];
            rgb_seen[orow] = c_rgb[7:0];
            e_seen[orow]   = c_e;
            if (c_bg[7:0]  > 8'd128) begin n_bg  = n_bg + 1;  if (first_bg  < 0) first_bg  = orow; end
            if (c_rgb[7:0] > 8'd128) begin n_rgb = n_rgb + 1; if (first_rgb < 0) first_rgb = orow; end
            if (c_e        != 2'd0) begin n_e = n_e + 1; e_sum = e_sum + orow; if (first_e < 0) first_e = orow; last_e = orow; end
        end
    end

    // ---------------- 激励 ----------------
    task send_line(input integer row);
        integer p;
        begin
            for (p = 0; p < HP; p = p + 1) begin
                i_de = 1'b1;
                if (row >= R) begin
                    i_g0 = 8'd255; i_g1 = 8'd255;
                    i_rgb = {6{8'd255}};
                end else begin
                    i_g0 = 8'd0; i_g1 = 8'd0;
                    i_rgb = 48'd0;
                end
                @(posedge clk); #1;
            end
            i_de = 1'b0; i_g0 = 8'd0; i_g1 = 8'd0; i_rgb = 48'd0;
            repeat (GAP) begin @(posedge clk); #1; end
        end
    endtask

    integer r, k;
    integer off_bg, off_rgb, off_e;
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (6) begin @(posedge clk); #1; end

        i_vs = 1'b1; repeat (3) begin @(posedge clk); #1; end i_vs = 1'b0;
        repeat (3) begin @(posedge clk); #1; end

        for (r = 0; r < VL; r = r + 1) send_line(r);
        repeat (60) begin @(posedge clk); #1; end

        off_bg  = (first_bg  < 0) ? -99 : (first_bg  - R);
        off_rgb = (first_rgb < 0) ? -99 : (first_rgb - R);
        e_cen   = (n_e == 0) ? -99 : ((e_sum + n_e/2) / n_e);
        off_e   = (e_cen     < 0) ? -99 : (e_cen     - R);

        $display("");
        $display("======================================================================");
        $display(" 三路行对齐测量   阶跃源行 R=%0d（R 之前全黑 / R 起全白）  o_de 行数 %0d", R, orow + 1);
        $display("======================================================================");
        $display("  o_bg (左半灰度) : 首次非零行 = %0d  相对源行偏移 = %0d  (命中 %0d 行)",
                 first_bg, off_bg, n_bg);
        $display("  o_rgb(右半彩色) : 首次非零行 = %0d  相对源行偏移 = %0d  (命中 %0d 行)",
                 first_rgb, off_rgb, n_rgb);
        $display("  o_e  (红色边缘) : 命中行 %0d..%0d  重心行 = %0d  相对源阶跃行偏移 = %0d  (命中 %0d 行)",
                 first_e, last_e, e_cen, off_e, n_e);
        $display("----------------------------------------------------------------------");
        $display("  按内容行计（越大越老）：  彩色 s-%0d   边缘 s-%0d   灰度 s-%0d",
                 (off_rgb < 0 ? 0 : off_rgb), (off_e < 0 ? 0 : off_e), (off_bg < 0 ? 0 : off_bg));
        // 横向相位不在此处测：整行全白的阶跃图案没有纵向特征，"首个白列"恒为 0。
        // 行缓存只改行号不改拍数（rg_d 5 级→4 级 + 1 行乒乓），三路横向相位与改前一致。
        if (off_bg == off_rgb && off_rgb == off_e)
            $display("  RESULT: ALIGNED  三路同相（内容行 = s-%0d）", off_rgb);
        else
            $display("  RESULT: MISALIGNED  灰度-彩色 = %0d 行，边缘-彩色 = %0d 行",
                     (off_bg - off_rgb), (off_e - off_rgb));
        $display("----------------------------------------------------------------------");
        $display("  行明细 (输出行 : bg rgb edge)");
        for (k = 0; k <= orow; k = k + 1)
            if (bg_seen[k] != 8'd0 || rgb_seen[k] != 8'd0 || e_seen[k] != 2'd0)
                $display("    %3d : %4d %4d %0d", k, bg_seen[k], rgb_seen[k], e_seen[k]);
        $display("======================================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
