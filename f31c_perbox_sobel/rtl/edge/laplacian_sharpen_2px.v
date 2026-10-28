//////////////////////////////////////////////////////////////////////////////
// laplacian_sharpen_2px.v —— 3x3 八邻域拉普拉斯锐化（各向同性，2 像素/时钟）
//
//   核：  [-1 -1 -1]
//         [-1  9 -1]
//         [-1 -1 -1]
//   等价：y = c + (Lap8 * SHARP_K) >>> 3 ，其中 Lap8 = 8*c - (八邻域之和)
//   SHARP_K：0 = 不锐化，4 = +50%，8 = +100%（沿用原语义）
//   结果用有符号中间量计算，越界饱和到 0 / 255
//
//   八邻域等权 → 水平/垂直/对角方向一视同仁（各向同性）；
//   相比原来的一维水平 3-tap 版本，垂直方向也能被锐化。
//
//   3x3 窗口直接复用已验证的 win3x3_2px（1 拍同步读 + o_x 滞后 2 拍的对齐
//   模式），不自建行缓存。窗口列序 {x2, x1, x0, xm1}：
//     像素 0（列 2p）的 3x3 窗 = 第 0/1/2 列，中心 = mid[15:8]
//     像素 1（列 2p+1）的 3x3 窗 = 第 1/2/3 列，中心 = mid[23:16]
//
//   数据滞后 2 个像素对：RGB 用两级寄存器同步延迟，与窗口对齐。
//   同一亮度修正量 (y - c) 加到 RGB 三通道，各通道单独饱和裁切。
//   帧边界不做 clamp（上层 pix_ok 掩膜已屏蔽行首/行尾与帧前两行）。
//////////////////////////////////////////////////////////////////////////////
module laplacian_sharpen_2px #(
    parameter integer H_PAIRS = 960,
    parameter integer ADDR_W  = 10,
    parameter integer SHARP_K = 4
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               i_de,
    input  wire [ADDR_W-1:0]  i_x,
    input  wire [11:0]        i_row,
    input  wire [15:0]        i_gray,      // {g1, g0}
    input  wire [47:0]        i_rgb,       // {rgb1, rgb0}，每像素 {b,g,r}

    output wire               o_de,
    output wire [ADDR_W-1:0]  o_x,
    output wire [11:0]        o_row,
    output wire [15:0]        o_gray,
    output wire [47:0]        o_rgb
);

    // ------------------------------------------------------------------
    // 3x3 灰度窗口（复用公共模块，已验证对齐）
    // ------------------------------------------------------------------
    wire [31:0] w_top, w_mid, w_bot;

    win3x3_2px #(
        .DW      (16),
        .H_PAIRS (H_PAIRS),
        .ADDR_W  (ADDR_W)
    ) u_win (
        .clk    (clk), .rst_n (rst_n),
        .i_de   (i_de), .i_x (i_x), .i_row (i_row), .i_pair (i_gray),
        .o_de   (o_de), .o_x (o_x), .o_row (o_row),
        .o_top  (w_top), .o_mid (w_mid), .o_bot (w_bot)
    );

    // ------------------------------------------------------------------
    // 八邻域之和（不含中心）
    // ------------------------------------------------------------------
    wire [7:0] c0 = w_mid[15:8];      // 像素 0 中心
    wire [7:0] c1 = w_mid[23:16];     // 像素 1 中心

    wire [10:0] s0 = w_top[7:0]  + w_top[15:8]  + w_top[23:16] +
                     w_mid[7:0]  +                 w_mid[23:16] +
                     w_bot[7:0]  + w_bot[15:8]  + w_bot[23:16];

    wire [10:0] s1 = w_top[15:8] + w_top[23:16] + w_top[31:24] +
                     w_mid[15:8] +                 w_mid[31:24] +
                     w_bot[15:8] + w_bot[23:16] + w_bot[31:24];

    // ------------------------------------------------------------------
    // y = clamp( c + ((8c - s8) * K) >>> 3 )
    // ------------------------------------------------------------------
    function automatic [7:0] sharp_lap8;
        input [7:0]  c;
        input [10:0] s8;
        integer lap, y;
        begin
            lap = ({24'd0, c} * 8) - {21'd0, s8};
            y   = c + ((lap * SHARP_K) >>> 3);
            if (y < 0)
                sharp_lap8 = 8'd0;
            else if (y > 255)
                sharp_lap8 = 8'd255;
            else
                sharp_lap8 = y[7:0];
        end
    endfunction

    wire [7:0] y0 = sharp_lap8(c0, s0);
    wire [7:0] y1 = sharp_lap8(c1, s1);

    // 亮度修正量（有符号，范围 -255..+255）
    wire signed [10:0] d0 = $signed({3'b0, y0}) - $signed({3'b0, c0});
    wire signed [10:0] d1 = $signed({3'b0, y1}) - $signed({3'b0, c1});

    // ------------------------------------------------------------------
    // RGB 同步延迟 2 拍（与窗口对齐）
    // ------------------------------------------------------------------
    reg [47:0] rgb_d1, rgb_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb_d1 <= 48'd0;
            rgb_d2 <= 48'd0;
        end else begin
            rgb_d1 <= i_rgb;
            rgb_d2 <= rgb_d1;
        end
    end

    // ------------------------------------------------------------------
    // 亮度修正量加到 RGB 三通道（各自饱和）
    // ------------------------------------------------------------------
    wire [7:0] ch0a, ch0b, ch0c, ch1a, ch1b, ch1c;

    add_delta_clamp u_ch0a (.i_ch(rgb_d2[7:0]),   .i_d(d0), .o_ch(ch0a));
    add_delta_clamp u_ch0b (.i_ch(rgb_d2[15:8]),  .i_d(d0), .o_ch(ch0b));
    add_delta_clamp u_ch0c (.i_ch(rgb_d2[23:16]), .i_d(d0), .o_ch(ch0c));
    add_delta_clamp u_ch1a (.i_ch(rgb_d2[31:24]), .i_d(d1), .o_ch(ch1a));
    add_delta_clamp u_ch1b (.i_ch(rgb_d2[39:32]), .i_d(d1), .o_ch(ch1b));
    add_delta_clamp u_ch1c (.i_ch(rgb_d2[47:40]), .i_d(d1), .o_ch(ch1c));

    assign o_gray = {y1, y0};
    assign o_rgb  = {ch1c, ch1b, ch1a, ch0c, ch0b, ch0a};

endmodule


//////////////////////////////////////////////////////////////////////////////
// 单通道加修正量并饱和
//////////////////////////////////////////////////////////////////////////////
module add_delta_clamp (
    input  wire [7:0]         i_ch,
    input  wire signed [10:0] i_d,
    output wire [7:0]         o_ch
);
    wire signed [11:0] s = $signed({4'b0, i_ch}) + i_d;
    assign o_ch = s[11] ? 8'd0 : (|s[11:8] ? 8'hFF : s[7:0]);
endmodule
