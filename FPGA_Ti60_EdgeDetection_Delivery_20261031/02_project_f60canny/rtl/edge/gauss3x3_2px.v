//////////////////////////////////////////////////////////////////////////////
// gauss3x3_2px.v —— 3x3 高斯带限滤波（2 像素/时钟）
//
//   核：  [1 2 1]
//         [2 4 2] / 16
//         [1 2 1]
//
//   sum = t0 + 2*t1 + t2
//       + 2*(m0 + 2*m1 + m2)
//       + b0 + 2*b1 + b2          （≤ 4080，12 位）
//   out = sum >> 4                （纯移位，无除法器）
//
//   3x3 窗口复用 win3x3_2px（1 拍同步读 + 数据滞后 2 拍）。
//   窗口列序 {x2, x1, x0, xm1}：像素 0 用 0/1/2 列，像素 1 用 1/2/3 列。
//   输出为组合结果，de/hs/vs 同步延迟 2 拍与数据对齐。
//   帧边界不做 clamp（上层显示/掩膜已覆盖边缘像素）。
//////////////////////////////////////////////////////////////////////////////
module gauss3x3_2px #(
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
    output reg                o_de,
    output reg                o_hs,
    output reg                o_vs,
    output reg  [7:0]         o_g0,
    output reg  [7:0]         o_g1
);

    // ------------------------------------------------------------------
    // 本域像素对列号（行缓存写入地址）
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
    // 3x3 窗口
    // ------------------------------------------------------------------
    wire [31:0] w_top, w_mid, w_bot;

    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win (
        .clk   (clk), .rst_n (rst_n),
        .i_de  (i_de), .i_x (pcol), .i_row (12'd0), .i_pair ({i_g1, i_g0}),
        .o_de  (), .o_x (), .o_row (),
        .o_top (w_top), .o_mid (w_mid), .o_bot (w_bot)
    );

    // ------------------------------------------------------------------
    // 高斯加权求和（×2 用移位，×4 用两位移位）
    // ------------------------------------------------------------------
    wire [11:0] sum0 = w_top[7:0]   + {w_top[15:8], 1'b0}  + w_top[23:16]
                     + {w_mid[7:0], 1'b0}  + {w_mid[15:8], 2'b00} + {w_mid[23:16], 1'b0}
                     + w_bot[7:0]   + {w_bot[15:8], 1'b0}  + w_bot[23:16];

    wire [11:0] sum1 = w_top[15:8]  + {w_top[23:16], 1'b0} + w_top[31:24]
                     + {w_mid[15:8], 1'b0} + {w_mid[23:16], 2'b00} + {w_mid[31:24], 1'b0}
                     + w_bot[15:8]  + {w_bot[23:16], 1'b0} + w_bot[31:24];

    // ------------------------------------------------------------------
    // 时序延迟 2 拍
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
        o_g0 = sum0[11:4];      // >> 4
        o_g1 = sum1[11:4];
    end

endmodule
