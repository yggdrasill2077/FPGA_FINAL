//==============================================================================
// mode_text_osd.v —— 边缘通路模式文字提示（"SOBEL" / "CANNY"，3×5 点阵）
//
//   需求背景：
//     edge_path_r = 1 → 通路B Canny（上电默认）；= 0 → 通路A 直连 Sobel。
//     KEY2 长按 1 s 切换。原来只有 x 88..95 / y 8..15 一个 8×8 亮度方块，
//     看不出"是哪种模式"，这里在画面左上角补一行文字提示。
//
//   显示内容：
//     i_mode = 0 → "SOBEL"
//     i_mode = 1 → "CANNY"
//
//   版式（与 shape_adjust_osd 完全同风格）：
//     字体 3 点宽 × 5 点高，每点 4×4 px → 字符 12×20 px，字距 16 px（12+4 空白）
//     起点 (8, 30)；5 个字符 → 5 个 16 px pitch，字形 x = 8..83（见下）、y = 30..49
//       SOBEL 实测点亮像素 x = 8..83（'L' 底横 111 到最右点）
//       CANNY 实测点亮像素 x = 8..81（'Y' 顶部 101）
//     坐标全部用移位（16 = 2^4、4 = 2^2），无乘法器、无除法器。
//
//   显示时机（方案 B：切换后显示 2 s）：
//     * 用 i_vs（hdmi_tx_vs）数帧，不用像素时钟数 2 s（148.5 MHz × 2 s ≈ 2.97e8，
//       要 29 位计数器 ≈ +29 FF；数帧只要 7 位）。
//     * 1080p60：像素时钟 148.5 MHz（sdc: 6.734 ns），2200×1125×60 = 148.5 M
//       → 60 fps，120 帧 = 2.000 s。
//     * hold_cnt 从 0 数到 120（饱和），hold_cnt < 120 时显示：
//         - 复位后先显示 2 s（上电就能看到当前模式，不会误判）
//         - i_mode 变化（切换瞬间）把 hold_cnt 清零 → 重新显示 2 s
//         - 数满 120 帧后自动熄灭，不再占用画面
//     * i_mode 在顶层已是 hdmi 域 2FF 同步后的 edge_path_s2，慢变量，无需再同步。
//
//   颜色：
//     o_px = 8'hFF（纯白），由顶层 OR 进左半屏三通道灰度树（与既有 OSD 一致）。
//     黑描边未做：需要把左半 OR 树改成 "边框区强制压黑" 的 mux，改顶层合成路径，
//     收益有限，按需求"若成本高就跳过"跳过。
//
//   资源（Efinity 预估）：
//     0 RAM（9 个 15 bit 字形写成常量 case）、+9 FF（hold_cnt[6:0] + mode_d + vs_d）、
//     约 +60..110 LUT（字形选择 + 行/点 mux + 坐标比较）。
//
//   注：本模块全组合输出 o_px / o_on，与 i_de / i_x / i_y 同拍，和 shape_adjust_osd
//       的时序约定一致，不需要额外的行缓存或 1 拍延迟。
//==============================================================================
module mode_text_osd #(
    parameter [6:0] HOLD_FRAMES = 7'd120      // 显示帧数：120 帧 @60 fps = 2.000 s
)(
    input  wire        clk,     // hdmi_tx_slow_clk（仅用于 2 s 帧计数）
    input  wire        rst_n,   // vid_rst_n
    input  wire        i_de,    // comp_de_o：有效像素区
    input  wire [10:0] i_x,     // comp_x 0..1919
    input  wire [11:0] i_y,     // fr_y   0..1079
    input  wire        i_vs,    // hdmi_tx_vs：帧同步（上升沿 = 新的一帧）
    input  wire        i_mode,  // 0 = SOBEL（通路A直连）/ 1 = CANNY（通路B，默认）
    output reg  [7:0]  o_px,    // 文字位图：点亮 0xFF / 其余 0x00
    output reg         o_on     // 字符单元区内（含未点亮的点）且处于 2 s 窗口内为 1
);

    // ------------------------------------------------------------------
    // 版式常量
    // ------------------------------------------------------------------
    localparam [10:0] X0   = 11'd8;      // 字符 0 左沿
    localparam [11:0] Y0   = 12'd30;     // 顶部（y 8..15 是 4 个状态方块，必须避开）
    localparam [11:0] CH_H = 12'd20;     // 5 点 × 4 px
    // 5 字符 × 16 px pitch = 80 px 宽 → x = 8..87 的字符格，字形实际占用 8..83

    // ------------------------------------------------------------------
    // 3×5 字形（15 bit = 5 行 × 3 点；bit[14:12] 最上一行，bit[2] 为最左点）
    //   S O B E L C A N Y —— 手写 case，不新增 ROM/RAM
    // ------------------------------------------------------------------
    function [14:0] letter_pat;
        input [3:0] idx;                 // 0=S 1=O 2=B 3=E 4=L 5=C 6=A 7=N 8=Y
        begin
            case (idx)
                4'd0:    letter_pat = 15'b111_100_111_001_111;   // S
                4'd1:    letter_pat = 15'b111_101_101_101_111;   // O
                4'd2:    letter_pat = 15'b110_101_110_101_110;   // B
                4'd3:    letter_pat = 15'b111_100_111_100_111;   // E
                4'd4:    letter_pat = 15'b100_100_100_100_111;   // L
                4'd5:    letter_pat = 15'b011_100_100_100_011;   // C
                4'd6:    letter_pat = 15'b010_101_111_101_101;   // A
                4'd7:    letter_pat = 15'b101_111_111_111_101;   // N
                4'd8:    letter_pat = 15'b101_101_010_010_010;   // Y
                default: letter_pat = 15'd0;                      // 空格（不点亮）
            endcase
        end
    endfunction

    // 取 15 bit 图案的第 r 行（r = 0 最上）
    function [2:0] pat_row;
        input [14:0] p;
        input [2:0]  r;
        begin
            case (r)
                3'd0:    pat_row = p[14:12];
                3'd1:    pat_row = p[11:9];
                3'd2:    pat_row = p[8:6];
                3'd3:    pat_row = p[5:3];
                default: pat_row = p[2:0];
            endcase
        end
    endfunction

    // 字符序号 ci（0..4）→ 字形编号：mode 0 拼 SOBEL / mode 1 拼 CANNY
    function [3:0] glyph_idx;
        input       m;
        input [2:0] ci;
        begin
            case (ci)
                3'd0:    glyph_idx = m ? 4'd5 : 4'd0;   // C / S
                3'd1:    glyph_idx = m ? 4'd6 : 4'd1;   // A / O
                3'd2:    glyph_idx = m ? 4'd7 : 4'd2;   // N / B
                3'd3:    glyph_idx = m ? 4'd7 : 4'd3;   // N / E
                default: glyph_idx = m ? 4'd8 : 4'd4;   // Y / L
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 2 s 显示窗口：帧计数（i_vs 上升沿 +1，饱和在 HOLD_FRAMES）
    //   复位 → 0（上电显示 2 s）；i_mode 变化 → 清零（切换后重新显示 2 s）
    // ------------------------------------------------------------------
    reg        vs_d;        // i_vs 打一拍，用于取上升沿
    reg        mode_d;      // i_mode 打一拍，用于检测切换
    reg  [6:0] hold_cnt;    // 0..120

    wire vs_rise = i_vs & ~vs_d;             // 一帧只有一个 clk 的脉冲
    wire hold_on = (hold_cnt < HOLD_FRAMES);

    always @( posedge clk or negedge rst_n ) begin
        if( !rst_n ) begin
            vs_d     <= 1'b0;
            mode_d   <= 1'b0;
            hold_cnt <= 7'd0;
        end else begin
            vs_d   <= i_vs;
            mode_d <= i_mode;
            if( i_mode != mode_d )                       // 模式切换 → 重新计时
                hold_cnt <= 7'd0;
            else if( vs_rise && (hold_cnt < HOLD_FRAMES) )
                hold_cnt <= hold_cnt + 7'd1;
        end
    end

    // ------------------------------------------------------------------
    // 坐标 → 字符序号 / 行号 / 点序号（16 px 字距、4 px 点距，全部是移位）
    //   cx  = x − 8      0..79（5 字符 × 16）
    //   ci  = cx[6:4]    字符序号 0..4
    //   dc  = cx[3:2]    点序号 0..3（3 = 字形右侧 4 px 空白）
    //   row = dy[4:2]    0..4
    // ------------------------------------------------------------------
    wire [10:0] cx = i_x - X0;
    wire [11:0] dy = i_y - Y0;

    wire in_x    = (i_x >= X0) && (cx < 11'd80);
    wire in_y    = (i_y >= Y0) && (dy < CH_H);
    wire [2:0] ci = cx[6:4];
    wire [1:0] dc = cx[3:2];
    wire in_cell  = in_x && (dc != 2'd3);

    wire [2:0] row = dy[4:2];
    wire [3:0] gid = glyph_idx(i_mode, ci);
    wire [2:0] bmp = pat_row(letter_pat(gid), row);

    // 取当前点（bit2 = 最左点）；dc==3 是字间空白，不点亮
    wire dot = (dc == 2'd0) ? bmp[2] :
               (dc == 2'd1) ? bmp[1] :
               (dc == 2'd2) ? bmp[0] : 1'b0;

    // ------------------------------------------------------------------
    // 输出（组合，与 i_de/i_x/i_y 同拍）
    // ------------------------------------------------------------------
    // 输出打一拍，切断组合路径（1 像素位移，肉眼不可见）
    reg on_c, px_c;
    always @(*) begin
        on_c = i_de && hold_on && in_y && in_cell;
        px_c = i_de && hold_on && in_y && in_cell && dot;
    end
    always @( posedge clk or negedge rst_n ) begin
        if( !rst_n ) begin
            o_on <= 1'b0;
            o_px <= 8'h00;
        end else begin
            o_on <= on_c;
            o_px <= px_c ? 8'hFF : 8'h00;
        end
    end

endmodule
