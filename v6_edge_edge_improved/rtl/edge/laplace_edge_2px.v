//////////////////////////////////////////////////////////////////////////////
// laplace_edge_2px.v —— 拉普拉斯零交叉边缘检测（2 像素/时钟）
//
//   与 Sobel（一阶、有方向、边缘偏粗）互补：拉普拉斯是二阶、各向同性，
//   用「零交叉」判定可直接得到单像素宽边缘。
//
//   处理链：
//     灰度对 → 3x3 窗口(win3x3) → 八邻域拉普拉斯 L = 8c - Σ八邻域（有符号）
//            → L 再过一级 3x3 窗口 → 与上/下/左/右四个邻点做零交叉判定
//
//   零交叉判定（Marr-Hildreth 简化版）：
//     若 L(本点) 与某邻点符号相反，且 |L(本点) - L(邻点)| > i_threshold
//     → 判为边缘
//
//   时延：两级 win3x3 各滞后 2 拍 = 共 4 拍，o_de/o_hs/o_vs 同步延迟 4 拍。
//////////////////////////////////////////////////////////////////////////////
module laplace_edge_2px #(
    parameter integer H_PAIRS = 960,
    parameter integer ADDR_W  = 10
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               i_de,
    input  wire               i_hs,
    input  wire               i_vs,
    input  wire [7:0]         i_g0,
    input  wire [7:0]         i_g1,
    input  wire [11:0]        i_threshold,
    output reg                o_de,
    output reg                o_hs,
    output reg                o_vs,
    output reg                o_e0,
    output reg                o_e1
);

    // ------------------------------------------------------------------
    // 本域像素对列号
    // ------------------------------------------------------------------
    reg [ADDR_W-1:0] pcol;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pcol <= {ADDR_W{1'b0}};
        else if (!i_de)
            pcol <= {ADDR_W{1'b0}};
        else if (pcol == (H_PAIRS - 1))
            pcol <= {ADDR_W{1'b0}};
        else
            pcol <= pcol + 1'b1;
    end

    // ------------------------------------------------------------------
    // 第一级：灰度 3x3 窗口
    // ------------------------------------------------------------------
    wire        g_de;
    wire [9:0]  g_x;
    wire [11:0] g_row;
    wire [31:0] g_top, g_mid, g_bot;

    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_gray (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (pcol), .i_row (12'd0), .i_pair ({i_g1, i_g0}),
        .o_de (g_de), .o_x (g_x), .o_row (g_row),
        .o_top (g_top), .o_mid (g_mid), .o_bot (g_bot)
    );

    // 灰度窗口的列序 {x2,x1,x0,xm1}；像素0 用 0/1/2 列、像素1 用 1/2/3 列
    wire [7:0] gc0 = g_mid[15:8];
    wire [7:0] gc1 = g_mid[23:16];

    wire [10:0] gs0 = g_top[7:0]  + g_top[15:8]  + g_top[23:16] +
                      g_mid[7:0]  +                g_mid[23:16] +
                      g_bot[7:0]  + g_bot[15:8]  + g_bot[23:16];

    wire [10:0] gs1 = g_top[15:8] + g_top[23:16] + g_top[31:24] +
                      g_mid[15:8] +                g_mid[31:24] +
                      g_bot[15:8] + g_bot[23:16] + g_bot[31:24];

    // 八邻域拉普拉斯 L = 8c - Σ8（有符号，范围 ±2040，13 位）
    wire [10:0] c8_0 = {gc0, 3'b000};                 // 8c ≤ 2040
    wire [10:0] c8_1 = {gc1, 3'b000};

    wire signed [12:0] lap0 = $signed({2'b00, c8_0}) - $signed({2'b00, gs0});
    wire signed [12:0] lap1 = $signed({2'b00, c8_1}) - $signed({2'b00, gs1});

    // ------------------------------------------------------------------
    // 第二级：L 的 3x3 窗口（DW = 26 = 两个 13bit 有符号值）
    // ------------------------------------------------------------------
    wire        l_de;
    wire [9:0]  l_x;
    wire [11:0] l_row;
    wire [51:0] l_top, l_mid, l_bot;

    win3x3_2px #(.DW(26), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_lap (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (g_x), .i_row (g_row), .i_pair ({lap1, lap0}),
        .o_de (l_de), .o_x (l_x), .o_row (l_row),
        .o_top (l_top), .o_mid (l_mid), .o_bot (l_bot)
    );

    // 每列 13bit：x2=[51:39] x1=[38:26] x0=[25:13] xm1=[12:0]
    // 像素0 中心 = x0，四邻 = 左(xm1) 右(x1) 上(top.x0) 下(bot.x0)
    wire signed [12:0] p0_c  = l_mid[25:13];
    wire signed [12:0] p0_l  = l_mid[12:0];
    wire signed [12:0] p0_r  = l_mid[38:26];
    wire signed [12:0] p0_u  = l_top[25:13];
    wire signed [12:0] p0_d  = l_bot[25:13];

    // 像素1 中心 = x1，四邻 = 左(x0) 右(x2) 上(top.x1) 下(bot.x1)
    wire signed [12:0] p1_c  = l_mid[38:26];
    wire signed [12:0] p1_l  = l_mid[25:13];
    wire signed [12:0] p1_r  = l_mid[51:39];
    wire signed [12:0] p1_u  = l_top[38:26];
    wire signed [12:0] p1_d  = l_bot[38:26];

    // 零交叉判定（单侧标注）：异号 + |差| > 阈值 + |L本| > |L邻|
    //   零交叉两侧只保留 |L| 更大的一侧 → 边缘宽度由 2px 降为 1px
    function zc;
        input signed [12:0] c;
        input signed [12:0] n;
        input        [11:0] thr;
        reg   signed [13:0] d;
        reg   signed [13:0] a;
        reg   signed [13:0] ac;
        reg   signed [13:0] an;
        begin
            d  = $signed({c[12], c}) - $signed({n[12], n});
            a  = d[13] ? -d : d;
            ac = c[12] ? -$signed({c[12], c}) : $signed({c[12], c});
            an = n[12] ? -$signed({n[12], n}) : $signed({n[12], n});
            // 对称剖面时 |L本| == |L邻|，用 c[12] 固定保留"负→正"一侧，
            // 避免整数对齐的干净边缘整段不标（虚线）
            zc = (c[12] ^ n[12]) && (a > $signed({2'b00, thr})) &&
                 ((ac > an) || ((ac == an) && c[12]));
        end
    endfunction

    wire e0 = zc(p0_c, p0_l, i_threshold) | zc(p0_c, p0_r, i_threshold) |
              zc(p0_c, p0_u, i_threshold) | zc(p0_c, p0_d, i_threshold);
    wire e1 = zc(p1_c, p1_l, i_threshold) | zc(p1_c, p1_r, i_threshold) |
              zc(p1_c, p1_u, i_threshold) | zc(p1_c, p1_d, i_threshold);

    // ------------------------------------------------------------------
    // 时序延迟 4 拍
    // ------------------------------------------------------------------
    reg d1_de, d2_de, d3_de, d4_de;
    reg d1_hs, d2_hs, d3_hs, d4_hs;
    reg d1_vs, d2_vs, d3_vs, d4_vs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_de <= 1'b0; d2_de <= 1'b0; d3_de <= 1'b0; d4_de <= 1'b0;
            d1_hs <= 1'b0; d2_hs <= 1'b0; d3_hs <= 1'b0; d4_hs <= 1'b0;
            d1_vs <= 1'b0; d2_vs <= 1'b0; d3_vs <= 1'b0; d4_vs <= 1'b0;
        end else begin
            d1_de <= i_de; d2_de <= d1_de; d3_de <= d2_de; d4_de <= d3_de;
            d1_hs <= i_hs; d2_hs <= d1_hs; d3_hs <= d2_hs; d4_hs <= d3_hs;
            d1_vs <= i_vs; d2_vs <= d1_vs; d3_vs <= d2_vs; d4_vs <= d3_vs;
        end
    end

    always @(*) begin
        o_de = d4_de;
        o_hs = d4_hs;
        o_vs = d4_vs;
        o_e0 = e0;
        o_e1 = e1;
    end

endmodule
