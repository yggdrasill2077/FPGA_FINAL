//////////////////////////////////////////////////////////////////////////////
// despeckle_2px.v —— 边缘二值图 3x3 邻域计数去孤立点（2 像素/时钟）
//
//   判定（单遍，不做迭代）：
//     统计 3x3 邻域内「除自身外」的白点个数 cnt
//     像素本身为 1 且 cnt >= MIN_NEI → 保持 1；否则输出 0
//     （MIN_NEI=2 表示邻居数 0/1 都视为孤立点清除）
//
//   3x3 窗口直接复用 win3x3_2px（1 拍同步读 + 数据滞后 2 拍），
//   DW=2 时每列 1 bit，窗口列序 {x2, x1, x0, xm1} = bit[3],[2],[1],[0]：
//     像素 0（列 2p）  的 3x3 窗 = bit 0/1/2，中心 = bit1
//     像素 1（列 2p+1）的 3x3 窗 = bit 1/2/3，中心 = bit2
//
//   边界 clamp（用边缘像素复制，不当 0）：
//     行首（x0 的列号为 0）  → xm1 用 x0 复制
//     行尾（x1 为最后一个）   → x2  用 x1 复制
//     帧前两行               → 上两行用当前行复制
//
//   x/row 计数在本模块内部自己数（i_de 域），不复用上游锐化域的计数器，
//   因为 edge 模块输出与锐化输入之间隔着整条流水线，相位不同。
//////////////////////////////////////////////////////////////////////////////
module despeckle_2px #(
    parameter integer H_PAIRS = 960,
    parameter integer ADDR_W  = 10,
    parameter integer MIN_NEI = 2
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              i_de,
    input  wire              i_hs,
    input  wire              i_vs,
    input  wire [1:0]        i_e,       // {e1, e0}
    output reg               o_de,
    output reg               o_hs,
    output reg               o_vs,
    output reg  [1:0]        o_e
);

    // ------------------------------------------------------------------
    // 本域内的像素对列号 / 行号
    // ------------------------------------------------------------------
    reg  [ADDR_W-1:0] pcol;
    reg  [11:0]       prow;
    reg  [11:0]       row_d1, row_d2;
    reg               de_q;

    wire line_end = de_q & ~i_de;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol <= {ADDR_W{1'b0}};
            prow <= 12'd0;
            de_q <= 1'b0;
        end else begin
            de_q   <= i_de;
            row_d1 <= prow;
            row_d2 <= row_d1;

            if (!i_de)
                pcol <= {ADDR_W{1'b0}};
            else if (pcol == (H_PAIRS - 1))
                pcol <= {ADDR_W{1'b0}};
            else
                pcol <= pcol + 1'b1;

            if (i_vs)
                prow <= 12'd0;
            else if (line_end)
                prow <= prow + 12'd1;
        end
    end

    // ------------------------------------------------------------------
    // 3x3 窗口
    // ------------------------------------------------------------------
    wire              w_de;
    wire [ADDR_W-1:0] w_x;
    wire [11:0]       w_row;
    wire [3:0]        w_top, w_mid, w_bot;

    win3x3_2px #(
        .DW      (2),
        .H_PAIRS (H_PAIRS),
        .ADDR_W  (ADDR_W)
    ) u_win (
        .clk    (clk), .rst_n (rst_n),
        .i_de   (i_de), .i_x (pcol), .i_row (prow), .i_pair (i_e),
        .o_de   (w_de), .o_x (w_x), .o_row (w_row),
        .o_top  (w_top), .o_mid (w_mid), .o_bot (w_bot)
    );

    // ------------------------------------------------------------------
    // 边界 clamp
    // ------------------------------------------------------------------
    wire at_left  = (w_x == {ADDR_W{1'b0}});
    wire at_right = (w_x == (H_PAIRS - 1));
    wire vclamp   = (row_d2 < 12'd2);   // 窗口底行行号（滞后 2 拍）

    // 行首：bit0(xm1) ← bit1(x0)
    wire [3:0] top_l = at_left ? {w_top[3:2], w_top[1], w_top[1]} : w_top;
    wire [3:0] mid_l = at_left ? {w_mid[3:2], w_mid[1], w_mid[1]} : w_mid;
    wire [3:0] bot_l = at_left ? {w_bot[3:2], w_bot[1], w_bot[1]} : w_bot;

    // 行尾：bit3(x2) ← bit2(x1)
    wire [3:0] top_h = at_right ? {w_top[2], w_top[2], w_top[1], w_top[0]} : top_l;
    wire [3:0] mid_h = at_right ? {w_mid[2], w_mid[2], w_mid[1], w_mid[0]} : mid_l;
    wire [3:0] bot_h = at_right ? {w_bot[2], w_bot[2], w_bot[1], w_bot[0]} : bot_l;

    // 帧前两行：上两行用当前行复制
    wire [3:0] u2 = vclamp ? bot_h : top_h;   // y-2
    wire [3:0] u1 = vclamp ? bot_h : mid_h;   // y-1
    wire [3:0] u0 = bot_h;                    // y

    // ------------------------------------------------------------------
    // 8 邻域计数（不含中心）
    //   像素0：中心 u0[1]，邻域 = {0,2}@y + {0,1,2}@y-1 + {0,1,2}@y-2
    //   像素1：中心 u0[2]，邻域 = {1,3}@y + {1,2,3}@y-1 + {1,2,3}@y-2
    // ------------------------------------------------------------------
    wire [3:0] cnt0 = {3'b000, u2[0]} + {3'b000, u2[1]} + {3'b000, u2[2]} +
                      {3'b000, u1[0]} + {3'b000, u1[1]} + {3'b000, u1[2]} +
                      {3'b000, u0[0]} + {3'b000, u0[2]};

    wire [3:0] cnt1 = {3'b000, u2[1]} + {3'b000, u2[2]} + {3'b000, u2[3]} +
                      {3'b000, u1[1]} + {3'b000, u1[2]} + {3'b000, u1[3]} +
                      {3'b000, u0[1]} + {3'b000, u0[3]};

    wire e0 = u0[1] & (cnt0 >= MIN_NEI);
    wire e1 = u0[2] & (cnt1 >= MIN_NEI);

    // ------------------------------------------------------------------
    // 时序信号延迟 2 拍（与窗口数据对齐）
    // ------------------------------------------------------------------
    reg d1_de, d2_de, d1_hs, d2_hs, d1_vs, d2_vs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_de <= 1'b0; d2_de <= 1'b0;
            d1_hs <= 1'b0; d2_hs <= 1'b0;
            d1_vs <= 1'b0; d2_vs <= 1'b0;
        end else begin
            d1_de <= i_de; d2_de <= d1_de;
            d1_hs <= i_hs; d2_hs <= d1_hs;
            d1_vs <= i_vs; d2_vs <= d1_vs;
        end
    end

    always @(*) begin
        o_de = d2_de;
        o_hs = d2_hs;
        o_vs = d2_vs;
        o_e  = {e1, e0};
    end

endmodule
