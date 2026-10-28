//////////////////////////////////////////////////////////////////////////////
// edge_canny_2px.v —— 自研边缘检测引擎（E1：Gauss + Sobel + Laplacian + 一致性门控）
//
//   结构（方案 §3/§4）：
//     gray ──► [win_gray 3x3] ──► [Gauss 3x3 带限] ──► [win_gauss 3x3]
//                                                        ├─ Sobel  → gx,gy,G,dir
//                                                        └─ Laplacian → L4,L8
//              ──► 一致性门控 (|G|>T1) && (|L4|>T2) ──► 二值边缘
//
//   * Gauss 直接用灰度窗的 8 邻域 + 中心算，不需要额外行缓存
//   * Sobel 与 Laplacian 共用同一份「高斯后」窗口（不各建一套）
//   * Sobel 严格按赛题：3×3 卷积、G = |Gx| + |Gy|、无开方
//   * T1 = i_threshold（沿用现有阈值按键）；T2 = T1 >> T2_SHIFT（默认 /4）
//   * 时延：两级窗口各 2 拍 = 4 拍；o_de/o_hs/o_vs 延迟 4 拍
//
//   幅值口径（parameter MAG_ISO_SEL，默认 0）：
//     MAG_ISO_SEL = 0 → {G1,G0}   = |Gx|+|Gy|，与赛题给定写法一致（默认行为不变）
//     MAG_ISO_SEL = 1 → {Gi1,Gi0} = max(|Gx|,|Gy|) + min(|Gx|,|Gy|)/2
//       对角方向不再偏高（原口径角度增益偏置 ≈ +41%），但幅值整体变小：
//       轴向不变、对角降为 0.75×，等效平均约 0.85×。
//       ★ 因此 MAG_ISO_SEL = 1 时阈值必须同步下调：
//         T' ≈ 0.854·T = T - (T>>3) - (T>>6)   （例：T=1024 → T'=880）
//         局部阈值 thr_loc / 双阈值 T_lo 都由 i_threshold 派生，改一处即可。
//       若沿用原 T 做阈值，边缘会明显变少（对角方向尤其）。
//
//   内部信号 gx/gy/G/dir/L4/L8 全部保留具名，供后续 NMS/亚像素阶段使用。
//
//   ===== 双通路（2026-10-27 新增，默认参数下通路B 行为与改前逐位一致）=====
//     中值灰度 ─┬─► [通路A] 直连 Sobel → |Gx|+|Gy| → 阈值二值化 → o_e_sobel
//               │        （B3 基础项：无高斯 / 无 NMS / 无滞后 / 无增益）
//               └─► [通路B] 2 级高斯 → Sobel 或 Scharr → C1 → NMS → 双阈值滞后
//                          → 去斑 → AA → o_e / o_aa / o_mag
//                          （A4 高档项）
//     参数：
//       GRAD_SEL     = 0 通路B 用 Sobel（默认，改前行为）；1 = Scharr
//       GAUSS_BYPASS = 0 通路B 走 1+2 级高斯（默认）；1 = 直连原始中值灰度
//     拍数：通路B 数据链 8 拍；通路A 直连 2 拍 + 6 拍对齐 = 8 拍，两路同拍，
//           顶层直接用同一个 o_de/o_hs/o_vs，不需要补延迟。
//     注意：通路A 的算子固定 Sobel（赛题 B3 写法），不受 GRAD_SEL 影响。
//////////////////////////////////////////////////////////////////////////////
module edge_canny_2px #(
    parameter integer H_PAIRS  = 960,
    parameter integer ADDR_W   = 10,
    parameter integer GAUSS_ON    = 1,    // 1 = 前置高斯带限，0 = 跳过高斯（默认，纯 Sobel 基线）
    parameter integer LAP_GATE_ON = 0,    // 1 = 启用 |L4| 一致性门控，0 = 只做 |G|>T1（默认）
    parameter integer T2_SHIFT    = 2,    // T2 = T1 >> T2_SHIFT
    parameter integer LOCAL_T_ON  = 1,    // 1 = 局部自适应阈值，0 = 只用全局 T1
    parameter integer LOCAL_SHIFT = 1,    // 阈值斜率：T_local = ḡ >> LOCAL_SHIFT
    parameter integer SUBPIX_ON   = 1,    // 1 = 抛物线亚像素 + OSD
    parameter integer CANNY_HYST_ON = 1,  // 1 = 双阈值 + 单遍滞后
    parameter integer HYST_SHIFT  = 3,    // T_lo = T_hi >> HYST_SHIFT
    parameter integer GAIN_SHIFT  = 1,    // 阈值比较前的 |G| 左移增益（仅比较用，不影响 NMS）
    parameter MAG_ISO_SEL = 1'b0,         // 幅值口径：0 = |Gx|+|Gy|（赛题口径，默认）；1 = mag_iso
    parameter SHARP_EN    = 1'b0,
    parameter GAUSS2_ON   = 1'b0,         // 0 = 只用 1 级高斯（保留弱边，省 RAM）
    parameter integer AA_ON      = 1,     // 1 = 打开亚像素抗锯齿等级 o_aa（SUBPIX_ON=0 时自动退化）
    parameter integer AA_MAG_TH  = 2,     // 半强度门限：dq ≥ AA_MAG_TH（Q4.4；2 → |δ| ≥ 1/8 = 0.125）
    // ---------------- 双通路 / 梯度算子选择（新增，默认值 = 改前行为）----------------
    parameter integer GRAD_SEL     = 0,   // 通路B 的梯度算子：0 = Sobel（默认），1 = Scharr
    parameter integer GAUSS_BYPASS = 0,   // 1 = 通路B 跳过 2 级高斯，直连原始中值灰度
    // ---------------- 逐帧直方图自动阈值（2026-10-27 新增，默认开）----------------
    //   1 = thr_src 取 auto_thr_2px 统计出的上一帧阈值（o_valid=0 时仍用 i_threshold）
    //   0 = 完全回退到 i_threshold（改前行为，逐位一致）
    parameter integer AUTO_THR     = 1
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               i_de,
    input  wire               i_hs,
    input  wire               i_vs,
    input  wire [47:0]        i_rgb,
    input  wire [7:0]         i_g0,
    input  wire [7:0]         i_g1,
    input  wire [11:0]        i_threshold,
    output reg                o_de,
    output reg                o_hs,
    output reg                o_vs,
    output reg  [1:0]         o_e,
    // 通路A：中值灰度 → 直连 Sobel → |Gx|+|Gy| → 阈值二值化（无高斯/NMS/滞后）
    //   与 o_e 严格同拍（B 的数据链 8 拍，A 直连 2 拍 + 6 拍对齐延迟）
    output reg  [1:0]         o_e_sobel,
    output wire [15:0]        o_mag,    // {pix1[7:0], pix0[7:0]} 边缘强度（NMS 幅值取高 8 位）
    output wire [3:0]         o_aa,     // {pix1[1:0], pix0[1:0]} 抗锯齿等级：0=无 / 1=半强度 / 2=全强度
    output reg  [15:0]        o_osd,    // {px1, px0} 的 OSD 亮度
    output reg  [15:0]        o_bg,     // 对齐后的灰度 {g1,g0}（与 despeckle 输出同相）
    output reg  [47:0]        o_rgb     // 对齐后的彩色 {rgb1,rgb0}（同一组延迟，逐拍同相）
);

    // ------------------------------------------------------------------
    // 像素对列号
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
    // 第一级：灰度 3x3 窗 → Gauss 带限
    // ------------------------------------------------------------------
    wire [31:0] gy_top, gy_mid, gy_bot;
    wire [9:0]  gy_x;

    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_gray (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (pcol), .i_row (12'd0), .i_pair ({i_g1, i_g0}),
        .o_de (), .o_x (gy_x), .o_row (),
        .o_top (gy_top), .o_mid (gy_mid), .o_bot (gy_bot)
    );

    wire [11:0] gsum0 = gy_top[7:0]   + {gy_top[15:8], 1'b0}  + gy_top[23:16]
                      + {gy_mid[7:0], 1'b0}  + {gy_mid[15:8], 2'b00} + {gy_mid[23:16], 1'b0}
                      + gy_bot[7:0]   + {gy_bot[15:8], 1'b0}  + gy_bot[23:16];

    wire [11:0] gsum1 = gy_top[15:8]  + {gy_top[23:16], 1'b0} + gy_top[31:24]
                      + {gy_mid[15:8], 1'b0} + {gy_mid[23:16], 2'b00} + {gy_mid[31:24], 1'b0}
                      + gy_bot[15:8]  + {gy_bot[23:16], 1'b0} + gy_bot[31:24];

    wire low_zone = (i_threshold <= 12'd16);
    // low_zone 旁路：与第一级窗输出对齐（打 2 拍）
    reg lz1b, lz2b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lz1b <= 1'b0; lz2b <= 1'b0; end
        else begin lz1b <= low_zone; lz2b <= lz1b; end
    end
    wire low_zone_d2 = lz2b;
    wire [7:0] bg0 = (GAUSS_ON && !low_zone_d2) ? gsum0[11:4] : gy_mid[15:8];
    wire [7:0] bg1 = (GAUSS_ON && !low_zone_d2) ? gsum1[11:4] : gy_mid[23:16];
    //--------------------------------------------------------------------------
    // 第二级高斯（k=2 级联）：加深低通 σ≈1.06，仅用于边缘通路；显示仍用一级输出
    //   GAUSS_BYPASS = 1 → 边缘通路直连原始中值灰度（1/2 级高斯全部跳过），
    //   显示用的 bg0/bg1 不受影响（左半屏仍是带限灰度）。
    //--------------------------------------------------------------------------
    wire [31:0] h2_top, h2_mid, h2_bot;
    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_gray2 (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (pcol), .i_row (12'd0), .i_pair ({bg1, bg0}),
        .o_de (), .o_x (), .o_row (),
        .o_top (h2_top), .o_mid (h2_mid), .o_bot (h2_bot)
    );
    wire [11:0] h2s0 = h2_top[7:0]      + {h2_top[15:8], 1'b0}  + h2_top[23:16]
                     + {h2_mid[7:0], 1'b0} + {h2_mid[15:8], 2'b00} + {h2_mid[23:16], 1'b0}
                     + h2_bot[7:0]      + {h2_bot[15:8], 1'b0}  + h2_bot[23:16];
    wire [11:0] h2s1 = h2_top[15:8]     + {h2_top[23:16], 1'b0} + h2_top[31:24]
                     + {h2_mid[15:8], 1'b0} + {h2_mid[23:16], 2'b00} + {h2_mid[31:24], 1'b0}
                     + h2_bot[15:8]     + {h2_bot[23:16], 1'b0} + h2_bot[31:24];
    wire [7:0] rawg0 = gy_mid[15:8];      // 原始中值灰度（未滤波），通路A 的输入
    wire [7:0] rawg1 = gy_mid[23:16];

    // GAUSS_BYPASS = 1：通路B 直连原始中值灰度（滤波运算全部跳过），
    //   但保留 win_gray2 的 2 拍直通延迟 —— 否则通路B 会比通路A 短 2 拍，
    //   双通路的相位对齐在 debug 模式下就失效了。综合时参数为 0 则整段被裁掉。
    reg [7:0] rawg0_d1, rawg0_d2, rawg1_d1, rawg1_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rawg0_d1 <= 8'd0; rawg0_d2 <= 8'd0;
            rawg1_d1 <= 8'd0; rawg1_d2 <= 8'd0;
        end else begin
            rawg0_d1 <= rawg0; rawg0_d2 <= rawg0_d1;
            rawg1_d1 <= rawg1; rawg1_d2 <= rawg1_d1;
        end
    end

    wire [7:0] bs0 = GAUSS_BYPASS ? rawg0_d2 : (GAUSS2_ON ? h2s0[11:4] : bg0);
    wire [7:0] bs1 = GAUSS_BYPASS ? rawg1_d2 : (GAUSS2_ON ? h2s1[11:4] : bg1);


    //==========================================================================
    // 显示行对齐（P1-2）
    //   顶层接线：i_g = 中值输出（3x3 窗中心在源行 s-1），i_rgb = debayer 原始行
    //   改前实测（sim/tb_align.v，以源行 s 为基准）：
    //     o_bg  左半灰度 = s-5   （中值 1 + win_gray 1 + bgfifo 3）
    //     o_e   红色边缘 = s-4   （中值 1 + win_gray/win_band/win_mag 各 1）
    //     o_rgb 右半彩色 = s-3   （rgbfifo 3，i_rgb 本身不带行延迟）
    //   → 红边比彩色老 1 行、左半灰度比彩色老 2 行，分缝和红边都错行。
    //   对齐目标取边缘路径的 s-4（边缘链路没有可调的行缓存）：
    //     灰度 bgfifo 3 → 2 行（早 1 行）
    //     彩色 rgbfifo 3 → 4 行（晚 1 行；4 行延迟要 5 个 bank，4 bank 会读回正在写的那行，
    //                          故第 4 行用独立 2 bank 乒乓缓存，并把 rg_d 5 级减到 4 级）
    //==========================================================================
    localparam integer GRAY_LINES = 3;

    // ---------------- 灰度显示 FIFO：GRAY_LINES 行（4 bank，同步读）----------------
    reg  [15:0] bgfifo [0:4095];
    reg  [1:0]  bwline;
    reg         bde_q;
    wire        bline_end = bde_q & ~i_de;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bwline <= 2'd0;
            bde_q  <= 1'b0;
        end else begin
            bde_q <= i_de;
            if (bline_end)
                bwline <= bwline + 2'd1;
        end
    end

    wire [1:0] brline = bwline - GRAY_LINES;      // 灰度：2 行（原 3 行）
    wire [1:0] brgb3  = bwline - 2'd3;            // 彩色主 FIFO 仍是 3 行

    always @(posedge clk) begin
        if (i_de)
            bgfifo[{bwline, pcol}] <= {bg1, bg0};
    end

    reg [15:0] bgf_q;
    always @(posedge clk) begin
        bgf_q <= bgfifo[{brline, pcol}];
    end

    // 彩色通道：主 FIFO 3 行 + 1 行乒乓 = 4 行（补回中值那 1 行）
    reg  [47:0] rgbfifo [0:4095];
    always @(posedge clk) begin
        if (i_de)
            rgbfifo[{bwline, pcol}] <= i_rgb;
    end

    reg [47:0] rgbf_q;
    always @(posedge clk) begin
        rgbf_q <= rgbfifo[{brgb3, pcol}];
    end

    // 再延后 1 行：2 bank 乒乓（写当前行 bank=r1lp / 读另一 bank=上一行），深度 2048 = 2^11
    reg  [47:0] rgb1l [0:2047];
    reg         r1lp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         r1lp <= 1'b0;
        else if (bline_end) r1lp <= ~r1lp;
    end

    always @(posedge clk) begin
        if (i_de)
            rgb1l[{r1lp, pcol}] <= rgbf_q;
    end

    reg [47:0] rgbf2_q;
    always @(posedge clk) begin
        rgbf2_q <= rgb1l[{~r1lp, pcol}];
    end
    reg  [15:0] bg_d1, bg_d2, bg_d3, bg_d4, bg_d5;
    reg  [47:0] rg_d1, rg_d2, rg_d3, rg_d4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bg_d1<=16'd0; bg_d2<=16'd0; bg_d3<=16'd0; bg_d4<=16'd0; bg_d5<=16'd0;
            rg_d1<=48'd0; rg_d2<=48'd0; rg_d3<=48'd0; rg_d4<=48'd0;
            o_rgb<=48'd0;
            o_bg <= 16'd0;
        end else begin
            bg_d1 <= bgf_q; bg_d2 <= bg_d1; bg_d3 <= bg_d2;
            bg_d4 <= bg_d3; bg_d5 <= bg_d4;
            o_bg  <= bg_d5;
            // 彩色：rgbf2_q(4 行) + 4 级，与改前 rgbf_q(3 行) + 5 级同拍（横向相位不变）
            rg_d1 <= rgbf2_q; rg_d2 <= rg_d1; rg_d3 <= rg_d2;
            rg_d4 <= rg_d3;
            o_rgb <= rg_d4;
        end
    end



    // ------------------------------------------------------------------
    // 局部自适应阈值支路：水平 run-sum(最近 8 对 ≈16 像素) + 垂直一阶 IIR(N=3)
    //   T(x) = clamp(sqrt_table[vmean[7:3]], T/2, 2T)   ← 局部项为 √ 亮度关系
    // ------------------------------------------------------------------
    reg  [15:0] hs0, hs1, hs2, hs3, hs4, hs5, hs6, hs7;
    reg  [11:0] hsum;
    wire [8:0]  hpair = bg0 + bg1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs0 <= 16'd0; hs1 <= 16'd0; hs2 <= 16'd0; hs3 <= 16'd0;
            hs4 <= 16'd0; hs5 <= 16'd0; hs6 <= 16'd0; hs7 <= 16'd0;
            hsum <= 12'd0;
        end else begin
            hs7 <= hs6; hs6 <= hs5; hs5 <= hs4; hs4 <= hs3;
            hs3 <= hs2; hs2 <= hs1; hs1 <= hs0;
            hs0 <= hpair;
            hsum <= hsum + hpair - hs7;
        end
    end

    wire [7:0] hmean = hsum[11:4];

    reg  [7:0] vmem [0:1023];
    reg  [7:0] vmean;
    reg  [9:0] pcol_d;
    reg  [7:0] vrd;
    reg  [7:0] hmean_d;

    // 同步读（保证推断为 BRAM），读回值与打一拍的 hmean 对齐
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol_d  <= 10'd0;
            vrd     <= 8'd0;
            hmean_d <= 8'd0;
        end else begin
            pcol_d  <= pcol;
            vrd     <= vmem[pcol];
            hmean_d <= hmean;
        end
    end

    wire signed [8:0] dv   = ({1'b0, hmean_d}) - ({1'b0, vrd});
    wire        [7:0] vnew = vrd + (dv >>> 3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vmean <= 8'd0;
        else begin
            vmean <= vnew;
            if (i_de)
                vmem[pcol_d] <= vnew;
        end
    end

    // ------------------------------------------------------------------
    // 局部阈值 ∝ √亮度（散粒噪声 σ ∝ √N，N ∝ 灰度）
    //   原式 thr_loc = vmean >> 1 是量纲错配：把「灰度均值」直接当「梯度幅值阈值」
    //   用，亮度一升高阈值就线性飙到梯度域里，与噪声的 √ 规律不符。
    //   改为 32 项 × 8bit 的平方根查表：
    //     sqrt_table[i] ≈ round(16·√i),  i = vmean[7:3]（vmean = 8i … 8i+7 一桶）
    //     ⇒ thr_loc ≈ 16·√(vmean/8) = √(32·vmean) ≈ 5.657·√vmean
    //   标定点：vmean = 128（中灰，i = 16）→ 64，与原 vmean >> 1 完全相等，
    //   即中等亮度阈值量级不变，只把「随亮度上升的斜率」从线性改成 √：
    //     暗区略高（vmean=8 → 16，原 4）、亮区略低（vmean=248 → 89，原 124）。
    //   8bit 无符号表，最大值 89，拼进 12bit 阈值域不会溢出。
    //   LOCAL_SHIFT 仍是「每级再除 2」的语义（默认 1 级 = 不再移位），
    //   由常数移位实现，综合时会被折叠成连线。
    // ------------------------------------------------------------------
    wire [4:0] vidx = vmean[7:3];

    reg [7:0] sqrt_table;
    always @(*) begin
        case (vidx)
            5'd0 : sqrt_table = 8'd0;   5'd1 : sqrt_table = 8'd16;
            5'd2 : sqrt_table = 8'd23;  5'd3 : sqrt_table = 8'd28;
            5'd4 : sqrt_table = 8'd32;  5'd5 : sqrt_table = 8'd36;
            5'd6 : sqrt_table = 8'd39;  5'd7 : sqrt_table = 8'd42;
            5'd8 : sqrt_table = 8'd45;  5'd9 : sqrt_table = 8'd48;
            5'd10: sqrt_table = 8'd51;  5'd11: sqrt_table = 8'd53;
            5'd12: sqrt_table = 8'd55;  5'd13: sqrt_table = 8'd58;
            5'd14: sqrt_table = 8'd60;  5'd15: sqrt_table = 8'd62;
            5'd16: sqrt_table = 8'd64;  5'd17: sqrt_table = 8'd66;
            5'd18: sqrt_table = 8'd68;  5'd19: sqrt_table = 8'd70;
            5'd20: sqrt_table = 8'd72;  5'd21: sqrt_table = 8'd73;
            5'd22: sqrt_table = 8'd75;  5'd23: sqrt_table = 8'd77;
            5'd24: sqrt_table = 8'd78;  5'd25: sqrt_table = 8'd80;
            5'd26: sqrt_table = 8'd82;  5'd27: sqrt_table = 8'd83;
            5'd28: sqrt_table = 8'd85;  5'd29: sqrt_table = 8'd86;
            5'd30: sqrt_table = 8'd88;  5'd31: sqrt_table = 8'd89;
            default: sqrt_table = 8'd89;
        endcase
    end

    localparam integer SQRT_RSH = (LOCAL_SHIFT > 0) ? (LOCAL_SHIFT - 1) : 0;
    wire [11:0] thr_loc = {4'b0000, sqrt_table, 2'b00} >> SQRT_RSH;   // ×4：使局部项在 T≥180 时不被下钳位吃掉

    // ------------------------------------------------------------------
    // 逐帧直方图自动阈值（AUTO_THR，2026-10-27）
    //   thr_src = AUTO_THR && o_valid ? 上一帧统计阈值 : i_threshold
    //   o_thr 是「上一帧」的结果，本帧直接使用 → 天然 1 帧延迟，无需额外处理。
    //   实例化在下方 NMS 之后（输入是 NMS 后的 G0n/G1n），这里先声明输出线。
    //   注意：low_zone 判据仍用 i_threshold（手动档的「最低档」语义），
    //         避免自动阈值把系统卡在低档位里（死锁）。
    // ------------------------------------------------------------------
    wire [11:0] athr_thr;
    wire        athr_val;
    wire [11:0] thr_src = ((AUTO_THR != 0) && athr_val) ? athr_thr : i_threshold;

    // ------------------------------------------------------------------
    // 双边钳位：thr_loc ∈ [T/2, 2T]
    //   原式 max(thr_loc, i_threshold) 只有单边下钳位 —— 局部阈值只能被抬高、
    //   永远不可能被拉低，暗区（vmean 小 → thr_loc 小）被恒定的 i_threshold
    //   完全覆盖，LOCAL_T_ON 支路在暗区等于失效（等于没有局部自适应）。
    //     下界 T/2：允许暗区把阈值降到全局值的一半（比原来多一档灵敏度，
    //               但仍有地板，不会像 T_ONLY 那样全放行）
    //     上界 2T ：防止亮区局部阈值无限抬升，把真实边缘也一起吃掉
    //   2T 用左移 1 位实现（移位不占 LUT/乘法器）；T 最大 4032 → 2T = 8064
    //   超出 12bit，所以上界比较在 13bit 上做。thr_hi 一旦 ≥ 4096 就必然
    //   大于任何 12bit 的 thr_loc，此刻该分支不可能被选中，故 thr_hi[11:0]
    //   截位取值安全。
    //   （想要更紧的上界 1.5T 就把 thr_hi 换成 thr_src + (thr_src>>1)，
    //     代价是一个 12bit 加法器；默认取 2T，使默认阈值档下中灰处与原
    //     max() 分支的取值连续。）
    // ------------------------------------------------------------------
    wire [11:0] thr_lo    = thr_src >> 1;
    wire [12:0] thr_hi    = {1'b0, thr_src} << 1;
    wire [12:0] thr_locx  = {1'b0, thr_loc};
    wire [11:0] thr_loc_c = (thr_locx < {1'b0, thr_lo}) ? thr_lo :
                            (thr_locx > thr_hi)         ? thr_hi[11:0] : thr_loc;

    wire [11:0] thr_eff = low_zone ? ((i_threshold > 12'd32) ? i_threshold : 12'd32)
                     : (LOCAL_T_ON ? thr_loc_c : thr_src);
    // ------------------------------------------------------------------
    // 第二级：带限后 3x3 窗（Sobel 与 Laplacian 共用）
    // ------------------------------------------------------------------
    wire [31:0] raw_top, raw_mid, raw_bot;
    wire [ADDR_W-1:0] bw_x;

    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_band (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (gy_x), .i_row (12'd0), .i_pair ({bs1, bs0}),
        .o_de (), .o_x (bw_x), .o_row (),
        .o_top (raw_top), .o_mid (raw_mid), .o_bot (raw_bot)
    );

    // ---- 列边界钳位：行首 xm1 用 x0 复制，行尾 x2 用 x1 复制 ----
    wire at_left  = (bw_x == {ADDR_W{1'b0}});
    wire at_right = (bw_x == (H_PAIRS - 1));

    wire [31:0] bt_top = at_left  ? {raw_top[31:24], raw_top[23:16], raw_top[15:8], raw_top[15:8]} :
                         at_right ? {raw_top[23:16], raw_top[23:16], raw_top[15:8], raw_top[7:0]}  : raw_top;
    wire [31:0] bt_mid = at_left  ? {raw_mid[31:24], raw_mid[23:16], raw_mid[15:8], raw_mid[15:8]} :
                         at_right ? {raw_mid[23:16], raw_mid[23:16], raw_mid[15:8], raw_mid[7:0]}  : raw_mid;
    wire [31:0] bt_bot = at_left  ? {raw_bot[31:24], raw_bot[23:16], raw_bot[15:8], raw_bot[15:8]} :
                         at_right ? {raw_bot[23:16], raw_bot[23:16], raw_bot[15:8], raw_bot[7:0]}  : raw_bot;
    // 低档位判定：仅在最低档附近启用阈值地板
    // ---------------- Sobel（像素0 / 像素1，共用这份窗）----------------
    wire signed [11:0] gx0, gy0, gx1, gy1;
    wire [11:0]        G0, G1;
    wire [11:0]        Gi0, Gi1;      // 各向异性补偿幅值（MAG_ISO_SEL = 1 时进 NMS）

    sobel_3x3 #(.KIND(GRAD_SEL)) u_sob0 (
        .i_p00 (bt_top[7:0]),   .i_p01 (bt_top[15:8]),  .i_p02 (bt_top[23:16]),
        .i_p10 (bt_mid[7:0]),   .i_p11 (bt_mid[15:8]),  .i_p12 (bt_mid[23:16]),
        .i_p20 (bt_bot[7:0]),   .i_p21 (bt_bot[15:8]),  .i_p22 (bt_bot[23:16]),
        .o_gx (gx0), .o_gy (gy0), .o_magnitude (G0), .o_mag_iso (Gi0)
    );

    sobel_3x3 #(.KIND(GRAD_SEL)) u_sob1 (
        .i_p00 (bt_top[15:8]),  .i_p01 (bt_top[23:16]), .i_p02 (bt_top[31:24]),
        .i_p10 (bt_mid[15:8]),  .i_p11 (bt_mid[23:16]), .i_p12 (bt_mid[31:24]),
        .i_p20 (bt_bot[15:8]),  .i_p21 (bt_bot[23:16]), .i_p22 (bt_bot[31:24]),
        .o_gx (gx1), .o_gy (gy1), .o_magnitude (G1), .o_mag_iso (Gi1)
    );

    // 方向码（四方向，供后续 NMS 使用）
    wire [11:0] agx0 = gx0[11] ? (~gx0 + 1'b1) : gx0;
    wire [11:0] agy0 = gy0[11] ? (~gy0 + 1'b1) : gy0;
    wire [11:0] agx1 = gx1[11] ? (~gx1 + 1'b1) : gx1;
    wire [11:0] agy1 = gy1[11] ? (~gy1 + 1'b1) : gy1;

    wire [1:0] dir0 = ({1'b0, agx0} << 1 <= {1'b0, agy0}) ? 2'd1 :
                      ({1'b0, agy0} << 1 <= {1'b0, agx0}) ? 2'd0 :
                      (gx0[11] ^ gy0[11])                 ? 2'd2 : 2'd3;
    wire [1:0] dir1 = ({1'b0, agx1} << 1 <= {1'b0, agy1}) ? 2'd1 :
                      ({1'b0, agy1} << 1 <= {1'b0, agx1}) ? 2'd0 :
                      (gx1[11] ^ gy1[11])                 ? 2'd2 : 2'd3;

    //==========================================================================
    // 通路A（B3 基础项）：中值灰度 → 直连 Sobel → |Gx|+|Gy| → 阈值二值化
    //   * 不经过高斯：直接用第一级 win_gray 的原始灰度窗 gy_top/mid/bot
    //   * 不经过 NMS / 双阈值滞后 / C1：就是最朴素的 `G > T`
    //   * 列边界钳位规则与通路B 完全相同，只是对齐 gy_x（2 拍）而不是 bw_x（6 拍）
    //   * 算子固定 KIND = 0（Sobel）：这是赛题 B3 指定的写法，不受 GRAD_SEL 影响；
    //     GRAD_SEL 只切换通路B（Scharr / Sobel）
    //   * 拍数对齐（见报告）：
    //       通路B 数据链 = win_gray 2 + win_gray2 2 + win_band 2 + win_mag 2 = 8 拍
    //       通路A 直连   = win_gray 2 拍
    //       ⇒ A 的 G 再打 6 拍，与 o_e 同拍，**差值 = 0 拍**；
    //         顶层直接与 o_e 共用 o_de/o_hs/o_vs，不需要再补延迟。
    //   * 阈值：与通路B 同一根 thr_eff（局部自适应 + 低档位地板），但
    //     **不乘 GAIN_SHIFT 增益**、不做滞后 —— 严格是 `|Gx|+|Gy| > T`。
    //     注：thr_eff 由 vmean IIR 派生，比窗口晚约 3~4 拍（通路B 同样如此），
    //         阈值是慢变量，3 拍的错位对结果无影响。
    //==========================================================================
    wire at_left_a  = (gy_x == {ADDR_W{1'b0}});
    wire at_right_a = (gy_x == (H_PAIRS - 1));

    wire [31:0] ag_top = at_left_a  ? {gy_top[31:24], gy_top[23:16], gy_top[15:8], gy_top[15:8]} :
                         at_right_a ? {gy_top[23:16], gy_top[23:16], gy_top[15:8], gy_top[7:0]}  : gy_top;
    wire [31:0] ag_mid = at_left_a  ? {gy_mid[31:24], gy_mid[23:16], gy_mid[15:8], gy_mid[15:8]} :
                         at_right_a ? {gy_mid[23:16], gy_mid[23:16], gy_mid[15:8], gy_mid[7:0]}  : gy_mid;
    wire [31:0] ag_bot = at_left_a  ? {gy_bot[31:24], gy_bot[23:16], gy_bot[15:8], gy_bot[15:8]} :
                         at_right_a ? {gy_bot[23:16], gy_bot[23:16], gy_bot[15:8], gy_bot[7:0]}  : gy_bot;

    wire signed [11:0] gxa0, gya0, gxa1, gya1;
    wire [11:0]        Ga0, Ga1, Gia0, Gia1;

    sobel_3x3 #(.KIND(0)) u_sob_a0 (
        .i_p00 (ag_top[7:0]),   .i_p01 (ag_top[15:8]),  .i_p02 (ag_top[23:16]),
        .i_p10 (ag_mid[7:0]),   .i_p11 (ag_mid[15:8]),  .i_p12 (ag_mid[23:16]),
        .i_p20 (ag_bot[7:0]),   .i_p21 (ag_bot[15:8]),  .i_p22 (ag_bot[23:16]),
        .o_gx (gxa0), .o_gy (gya0), .o_magnitude (Ga0), .o_mag_iso (Gia0)
    );

    sobel_3x3 #(.KIND(0)) u_sob_a1 (
        .i_p00 (ag_top[15:8]),  .i_p01 (ag_top[23:16]), .i_p02 (ag_top[31:24]),
        .i_p10 (ag_mid[15:8]),  .i_p11 (ag_mid[23:16]), .i_p12 (ag_mid[31:24]),
        .i_p20 (ag_bot[15:8]),  .i_p21 (ag_bot[23:16]), .i_p22 (ag_bot[31:24]),
        .o_gx (gxa1), .o_gy (gya1), .o_magnitude (Ga1), .o_mag_iso (Gia1)
    );

    // ---- 6 拍对齐延迟（使通路A 的 G 与通路B 的 o_e 同拍）----
    reg [11:0] ga0_d1, ga0_d2, ga0_d3, ga0_d4, ga0_d5, ga0_d6;
    reg [11:0] ga1_d1, ga1_d2, ga1_d3, ga1_d4, ga1_d5, ga1_d6;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ga0_d1 <= 12'd0; ga0_d2 <= 12'd0; ga0_d3 <= 12'd0;
            ga0_d4 <= 12'd0; ga0_d5 <= 12'd0; ga0_d6 <= 12'd0;
            ga1_d1 <= 12'd0; ga1_d2 <= 12'd0; ga1_d3 <= 12'd0;
            ga1_d4 <= 12'd0; ga1_d5 <= 12'd0; ga1_d6 <= 12'd0;
        end else begin
            ga0_d1 <= Ga0; ga0_d2 <= ga0_d1; ga0_d3 <= ga0_d2;
            ga0_d4 <= ga0_d3; ga0_d5 <= ga0_d4; ga0_d6 <= ga0_d5;
            ga1_d1 <= Ga1; ga1_d2 <= ga1_d1; ga1_d3 <= ga1_d2;
            ga1_d4 <= ga1_d3; ga1_d5 <= ga1_d4; ga1_d6 <= ga1_d5;
        end
    end

    // 纯阈值二值化（无 NMS、无滞后、无增益）
    wire e0a = (ga0_d6 > thr_eff);
    wire e1a = (ga1_d6 > thr_eff);


    // ------------------------------------------------------------------
    // NMS：|G| 的 3x3 窗（DW=24，两个 12bit 幅值打包）
    //   幅值来源由 MAG_ISO_SEL 选择（两者都是 12bit，窗后各级零改动）：
    //     MAG_ISO_SEL = 0 → {G1, G0}   = |Gx|+|Gy|      （赛题口径，默认）
    //     MAG_ISO_SEL = 1 → {Gi1, Gi0} = max(|Gx|,|Gy|) + min(|Gx|,|Gy|)/2
    // ------------------------------------------------------------------
    wire [47:0] m_top, m_mid, m_bot;
    wire [ADDR_W-1:0] m_x;

    win3x3_2px #(.DW(24), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_mag (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (bw_x), .i_row (12'd0),
        .i_pair (MAG_ISO_SEL ? {Gi1, Gi0} : {G1, G0}),
        .o_de (), .o_x (m_x), .o_row (),
        .o_top (m_top), .o_mid (m_mid), .o_bot (m_bot)
    );

    // 列序 {x2,x1,x0,xm1} = [47:36],[35:24],[23:12],[11:0]
    // 像素0 中心 = x0 列，像素1 中心 = x1 列
    wire [11:0] p0_c  = m_mid[23:12];
    wire [11:0] p0_l  = m_mid[11:0];
    wire [11:0] p0_r  = m_mid[35:24];
    wire [11:0] p0_u  = m_top[23:12];
    wire [11:0] p0_d  = m_bot[23:12];
    wire [11:0] p0_ur = m_top[35:24];
    wire [11:0] p0_dl = m_bot[11:0];
    wire [11:0] p0_ul = m_top[11:0];
    wire [11:0] p0_dr = m_bot[35:24];

    wire [11:0] p1_c  = m_mid[35:24];
    wire [11:0] p1_l  = m_mid[23:12];
    wire [11:0] p1_r  = m_mid[47:36];
    wire [11:0] p1_u  = m_top[35:24];
    wire [11:0] p1_d  = m_bot[35:24];
    wire [11:0] p1_ur = m_top[47:36];
    wire [11:0] p1_dl = m_bot[23:12];
    wire [11:0] p1_ul = m_top[23:12];
    wire [11:0] p1_dr = m_bot[47:36];

    // 方向码延迟 2 拍（与该级窗口对齐）
    reg [1:0] d0n_1, d0n_2, d1n_1, d1n_2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin d0n_1 <= 2'd0; d0n_2 <= 2'd0; d1n_1 <= 2'd0; d1n_2 <= 2'd0; end
        else begin d0n_1 <= dir0; d0n_2 <= d0n_1; d1n_1 <= dir1; d1n_2 <= d1n_1; end
    end

    // 邻点选择（H/V = 0/1，"/" = 2，"\ " = 3）
    wire [11:0] n0 = (d0n_2 == 2'd0) ? p0_l  : (d0n_2 == 2'd1) ? p0_u  :
                     (d0n_2 == 2'd2) ? p0_ur : p0_ul;
    wire [11:0] q0 = (d0n_2 == 2'd0) ? p0_r  : (d0n_2 == 2'd1) ? p0_d  :
                     (d0n_2 == 2'd2) ? p0_dl : p0_dr;
    wire [11:0] n1 = (d1n_2 == 2'd0) ? p1_l  : (d1n_2 == 2'd1) ? p1_u  :
                     (d1n_2 == 2'd2) ? p1_ur : p1_ul;
    wire [11:0] q1 = (d1n_2 == 2'd0) ? p1_r  : (d1n_2 == 2'd1) ? p1_d  :
                     (d1n_2 == 2'd2) ? p1_dl : p1_dr;

    // keep = 两侧都允许相等，但必须严格大于其中至少一侧：
    //   (G0 >= G_neg) && (G0 >= G_pos) && ((G0 > G_neg) || (G0 > G_pos))
    //   这样梯度脊线上相邻点幅值相等时不再被单侧严格比较误杀；
    //   而「三边及以上等值」的平坦梯度平台（如线性斜坡内部）仍只保留平台边缘，
    //   不会让整片区域同时通过 NMS（纯两侧 >= 会整片保留）。
    // ---------------- C2：幅值拉普拉斯锐化（边缘变细）----------------
    //   G' = 2·G − (up+down+left+right)/4   （等价 G + 0.25·(4G − S)）
    //   只锐化中心点；4 邻点用原幅值参与 NMS 比较（省掉额外行缓存）
    wire [12:0] s0sum = {1'b0,p0_u} + {1'b0,p0_d} + {1'b0,p0_l} + {1'b0,p0_r};
    wire [12:0] s1sum = {1'b0,p1_u} + {1'b0,p1_d} + {1'b0,p1_l} + {1'b0,p1_r};
    // 实测最优是"幅值 4 邻域平均"（= m + 0.25·∇²m = S/4），不是锐化
    wire [11:0] c0s   = SHARP_EN ? s0sum[13:2] : p0_c;
    wire [11:0] c1s   = SHARP_EN ? s1sum[13:2] : p1_c;

    wire keep0 = (c0s >= n0) && (c0s >= q0) && ((c0s > n0) || (c0s > q0));
    wire keep1 = (c1s >= n1) && (c1s >= q1) && ((c1s > n1) || (c1s > q1));

    wire [11:0] G0n = keep0 ? c0s : 12'd0;
    wire [11:0] G1n = keep1 ? c1s : 12'd0;

    // ------------------------------------------------------------------
    // 逐帧直方图自动阈值（AUTO_THR）
    //   输入 = NMS 后的幅值（G0n/G1n，各 12bit，打包成 24bit）
    //   输出 o_thr 是上一帧统计的阈值、本帧使用（天然 1 帧延迟）；
    //   o_valid = 0（首帧统计完成前）时 thr_src 自动回退到 i_threshold。
    //   AUTO_THR = 0 时该实例输出不参与 thr_src（综合会整块裁掉）。
    // ------------------------------------------------------------------
    auto_thr_2px #(
        .PCT_NUM (8),
        .PCT_DEN (100)
    ) u_auto_thr (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_de    (i_de),
        .i_vs    (i_vs),
        .i_mag   ({G1n, G0n}),
        .o_thr   (athr_thr),
        .o_valid (athr_val)
    );
    // ---------------- 增益（仅用于阈值比较，带饱和，不进 NMS）----------------
    function automatic [11:0] gain_sat;
        input [11:0] g;
        begin
            gain_sat = (g > (12'hFFF >> GAIN_SHIFT)) ? 12'hFFF : (g << GAIN_SHIFT);
        end
    endfunction
    // ------------------------------------------------------------------
    // 抛物线亚像素：δ = 0.5·(G₋−G₊)/(G₋−2G₀+G₊)，Q4.4
    //   守卫 G₀≥G₋ 且 G₀≥G₊；|δ|·16 = 8|num|/|den| ∈ [0,8]，用 4 级复原除法
    // ------------------------------------------------------------------
    wire [11:0] num0 = (n0 >= q0) ? (n0 - q0) : (q0 - n0);      // |G₋ − G₊|
    wire [11:0] den0 = (c0s - n0) + (c0s - q0);               // |den| = 2G0−G₋−G₊
    wire [11:0] num1 = (n1 >= q1) ? (n1 - q1) : (q1 - n1);
    wire num_dir0 = (n0 >= q0);        // 0 = δ 为正
    wire num_dir1 = (n1 >= q1);
    wire [11:0] den1 = (c1s - n1) + (c1s - q1);

    wire [15:0] dn0 = {1'b0, num0, 3'b000};                     // 8|num|
    wire [15:0] dn1 = {1'b0, num1, 3'b000};
    wire [15:0] dd0 = {4'b0, den0};
    wire [15:0] dd1 = {4'b0, den1};

    wire [15:0] d3r0 = dd0 << 3, d2r0 = dd0 << 2, d1r0 = dd0 << 1;
    wire [15:0] d3r1 = dd1 << 3, d2r1 = dd1 << 2, d1r1 = dd1 << 1;

    wire q3_0 = (dn0 >= d3r0);
    wire [15:0] r3_0 = q3_0 ? (dn0 - d3r0) : dn0;
    wire q2_0 = (r3_0 >= d2r0);
    wire [15:0] r2_0 = q2_0 ? (r3_0 - d2r0) : r3_0;
    wire q1_0 = (r2_0 >= d1r0);
    wire [15:0] r1_0 = q1_0 ? (r2_0 - d1r0) : r2_0;
    wire q0_0 = (r1_0 >= dd0);
    wire [3:0] dq0 = (den0 == 12'd0) ? 4'd0 : {q3_0, q2_0, q1_0, q0_0};

    wire q3_1 = (dn1 >= d3r1);
    wire [15:0] r3_1 = q3_1 ? (dn1 - d3r1) : dn1;
    wire q2_1 = (r3_1 >= d2r1);
    wire [15:0] r2_1 = q2_1 ? (r3_1 - d2r1) : r3_1;
    wire q1_1 = (r2_1 >= d1r1);
    wire [15:0] r1_1 = q1_1 ? (r2_1 - d1r1) : r2_1;
    wire q0_1 = (r1_1 >= dd1);
    wire [3:0] dq1 = (den1 == 12'd0) ? 4'd0 : {q3_1, q2_1, q1_1, q0_1};

    // OSD：画面中线附近 3 行，边缘点亮度 ∝ |δ|（4 位为 Q4.4，左移 4 位成 8bit）
    // ---- 前向引用修复：OSD 段引用的信号提前声明 ----
    reg  [9:0] ocol;
    wire       e0, e1, e0f, e1f;
    wire [7:0] osd_num, osd_mode;
    reg        d6_de;

    reg [11:0] row_d6;
    wire osd_row = (row_d6 == 12'd536) || (row_d6 == 12'd537) || (row_d6 == 12'd538);

    // 只点亮阈值后的真实边缘点（e0/e1），否则整行局部极大都会被点亮
    wire [7:0] osd0 = (SUBPIX_ON && osd_row && e0f) ? {dq0, 4'b0000} : (osd_num | osd_mode);
    wire [7:0] osd1 = (SUBPIX_ON && osd_row && e1f) ? {dq1, 4'b0000} : (osd_num | osd_mode);
    // ------------------------------------------------------------------
    // OSD 数值读出：像素条(长度 ∝ |δ|，0~16px) + 符号点(δ>0 点亮)
    //   取「上一扫描行最后一个 NMS 边缘点」的 δ，避免同一行内反复跳动
    // ------------------------------------------------------------------
    reg [3:0] last_dq;
    reg       last_sg;
    reg [3:0] disp_dq;
    reg       disp_sg;
    reg       osd_row_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_dq <= 4'd0; last_sg <= 1'b0;
            disp_dq <= 4'd0; disp_sg <= 1'b0;
            osd_row_d <= 1'b0;
        end else begin
            osd_row_d <= osd_row;
            if (osd_row && !osd_row_d) begin
                last_dq <= 4'd0;
                last_sg <= 1'b0;
            end else if (osd_row && e0) begin
                last_dq <= dq0;
                last_sg <= (num_dir0 == 1'b0);
            end else if (osd_row && e1) begin
                last_dq <= dq1;
                last_sg <= (num_dir1 == 1'b0);
            end
            if (osd_row && !osd_row_d) begin
                disp_dq <= last_dq;
                disp_sg <= last_sg;
            end
        end
    end

    wire [4:0] bar_len = {disp_dq, 1'b0};               // 0..16 px
    wire [9:0] bar_x   = {ocol, 1'b0};                  // 当前像素 x
    wire       bar_on  = (bar_x >= 10'd100) &&
                         ((bar_x - 10'd100) < {1'b0, bar_len});
    wire       sign_on = (bar_x == 10'd96) && disp_sg;

    assign osd_num = (SUBPIX_ON && osd_row && (bar_on || sign_on)) ? 8'hFF : 8'd0;

    // 模式指示方块：左上角 x 8..16 / y 8..16，常规档暗灰 0x40，细节模式亮白 0xFF
    wire ind_on = (row_d6 >= 12'd8) && (row_d6 < 12'd16) &&
                  (bar_x >= 10'd8) && (bar_x < 10'd16);
    assign osd_mode = ind_on ? (low_zone ? 8'hFF : 8'hC0) : 8'd0;
    // ---------------- Laplacian（同一份窗）----------------
    wire [7:0] c0 = bt_mid[15:8];
    wire [7:0] c1 = bt_mid[23:16];

    wire [10:0] l4p0 = bt_top[15:8] + bt_bot[15:8] + bt_mid[7:0]  + bt_mid[23:16];
    wire [10:0] l4p1 = bt_top[23:16] + bt_bot[23:16] + bt_mid[15:8] + bt_mid[31:24];

    wire [9:0] c4_0 = {c0, 2'b00};
    wire [9:0] c4_1 = {c1, 2'b00};

    wire signed [10:0] L4_0 = $signed({1'b0, c4_0}) - $signed({1'b0, l4p0});
    wire signed [10:0] L4_1 = $signed({1'b0, c4_1}) - $signed({1'b0, l4p1});

    wire [10:0] absL4_0 = L4_0[10] ? (~L4_0 + 1'b1) : L4_0;
    wire [10:0] absL4_1 = L4_1[10] ? (~L4_1 + 1'b1) : L4_1;

    // L8（八邻域版，供后续亚像素法向使用，保留具名）
    wire [10:0] s8_0 = bt_top[7:0]   + bt_top[15:8]   + bt_top[23:16]
                     + bt_mid[7:0]   +                  bt_mid[23:16]
                     + bt_bot[7:0]   + bt_bot[15:8]   + bt_bot[23:16];
    wire [10:0] s8_1 = bt_top[15:8]  + bt_top[23:16]  + bt_top[31:24]
                     + bt_mid[15:8]  +                  bt_mid[31:24]
                     + bt_bot[15:8]  + bt_bot[23:16]  + bt_bot[31:24];

    wire signed [12:0] L8_0 = $signed({2'b00, c0, 3'b000}) - $signed({2'b00, s8_0});
    wire signed [12:0] L8_1 = $signed({2'b00, c1, 3'b000}) - $signed({2'b00, s8_1});

    // ---- 输出列计数器（与输出数据同相，用于行尾屏蔽）----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ocol <= {ADDR_W{1'b0}};
        else if (!d6_de)
            ocol <= {ADDR_W{1'b0}};
        else if (ocol == (H_PAIRS - 1))
            ocol <= {ADDR_W{1'b0}};
        else
            ocol <= ocol + 1'b1;
    end
    // ---- 行计数（vsync 高有效清零）+ 4 拍延迟 + 前 2 行屏蔽 ----
    reg [11:0] prow;
    reg        de_q;
    wire       line_end = de_q & ~i_de;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prow <= 12'd0;
            de_q <= 1'b0;
        end else begin
            de_q <= i_de;
            if (i_vs)
                prow <= 12'd0;
            else if (line_end)
                prow <= prow + 12'd1;
        end
    end

    reg [11:0] row_d1, row_d2, row_d3, row_d4, row_d5;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin row_d1<=12'd0; row_d2<=12'd0; row_d3<=12'd0; row_d4<=12'd0; row_d5<=12'd0; row_d6<=12'd0; end
        else begin row_d1<=prow; row_d2<=row_d1; row_d3<=row_d2; row_d4<=row_d3; row_d5<=row_d4; row_d6<=row_d5; end
    end

    // 两级 3x3 窗口串联：有效数据从第 4 行开始；左右两端各屏蔽 1 对（2 像素）
    // 两级 3x3 窗口串联：有效数据从第 4 行开始
    // 行首/行尾用输出列计数器屏蔽（管线头部与尾部都会带入相邻行数据）
    wire pix_ok = (row_d6 >= 12'd6) &&
                   (ocol != {ADDR_W{1'b0}}) &&
                   (ocol < (H_PAIRS - 2));
    // ---------------- 一致性门控 ----------------
    wire [11:0] T2 = thr_src >> T2_SHIFT;     // 自动/手动阈值（AUTO_THR）派生

    assign e0 = ((gain_sat(G0n) > thr_eff) && (LAP_GATE_ON ? (absL4_0 > T2) : 1'b1));
    assign e1 = ((gain_sat(G1n) > thr_eff) && (LAP_GATE_ON ? (absL4_1 > T2) : 1'b1));

    // ---------------- Canny 双阈值 + 单遍 8 邻域滞后 ----------------
    //   邻点 strong 直接取自同一份 |G| 3x3 窗（NMS 级已有），
    //   因此不需要额外的 strong 行缓存，也不增加流水线延迟。
    wire [11:0] T_lo = thr_src >> HYST_SHIFT;

    wire w0 = keep0 && (gain_sat(p0_c) > T_lo);
    wire w1 = keep1 && (gain_sat(p1_c) > T_lo);

    wire any_s0 = (gain_sat(p0_l) > thr_eff) | (gain_sat(p0_r) > thr_eff) |
                  (gain_sat(p0_u) > thr_eff) | (gain_sat(p0_d) > thr_eff) |
                  (gain_sat(p0_ul) > thr_eff) | (gain_sat(p0_ur) > thr_eff) |
                  (gain_sat(p0_dl) > thr_eff) | (gain_sat(p0_dr) > thr_eff);
    wire any_s1 = (gain_sat(p1_l) > thr_eff) | (gain_sat(p1_r) > thr_eff) |
                  (gain_sat(p1_u) > thr_eff) | (gain_sat(p1_d) > thr_eff) |
                  (gain_sat(p1_ul) > thr_eff) | (gain_sat(p1_ur) > thr_eff) |
                  (gain_sat(p1_dl) > thr_eff) | (gain_sat(p1_dr) > thr_eff);

    assign e0f = (CANNY_HYST_ON ? (e0 | (w0 & any_s0)) : e0);
    assign e1f = (CANNY_HYST_ON ? (e1 | (w1 & any_s1)) : e1);


    // ------------------------------------------------------------------
    // 时序延迟 4 拍
    // ------------------------------------------------------------------
    reg d1_de, d2_de, d3_de, d4_de, d5_de;
    reg d1_hs, d2_hs, d3_hs, d4_hs, d5_hs, d6_hs;
    reg d1_vs, d2_vs, d3_vs, d4_vs, d5_vs, d6_vs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_de <= 1'b0; d2_de <= 1'b0; d3_de <= 1'b0; d4_de <= 1'b0; d5_de <= 1'b0; d6_de <= 1'b0;
            d1_hs <= 1'b0; d2_hs <= 1'b0; d3_hs <= 1'b0; d4_hs <= 1'b0; d5_hs <= 1'b0; d6_hs <= 1'b0;
            d1_vs <= 1'b0; d2_vs <= 1'b0; d3_vs <= 1'b0; d4_vs <= 1'b0; d5_vs <= 1'b0; d6_vs <= 1'b0;
        end else begin
            d1_de <= i_de; d2_de <= d1_de; d3_de <= d2_de; d4_de <= d3_de; d5_de <= d4_de; d6_de <= d5_de;
            d1_hs <= i_hs; d2_hs <= d1_hs; d3_hs <= d2_hs; d4_hs <= d3_hs; d5_hs <= d4_hs; d6_hs <= d5_hs;
            d1_vs <= i_vs; d2_vs <= d1_vs; d3_vs <= d2_vs; d4_vs <= d3_vs; d5_vs <= d4_vs; d6_vs <= d5_vs;
        end
    end

    // ------------------------------------------------------------------
    // 亚像素抗锯齿（AA）等级：每像素 2 bit，{pix1,pix0}
    //   0 = 不画 / 1 = 半强度 / 2 = 全强度
    //
    //   规则（逐像素）：
    //     * 本像素就是边缘（e0f/e1f）                            → 2
    //     * 否则水平相邻像素(x−1 或 x+1)是边缘，且它的亚像素偏移 δ
    //       指向本像素（|δ| > 1/8，Q4.4 即 dq ≥ AA_MAG_TH）      → 1
    //     * 其余                                                → 0
    //
    //   δ 的方向：num_dirX = (G₋ ≥ G₊)，0 表示 δ > 0（抛物线峰位偏向 q 侧）。
    //   n/q 是按 NMS 方向码选的邻点，换算成「水平方向」：
    //     dir=0 水平  ：n=左  q=右   → δ>0 点亮右邻
    //     dir=1 垂直  ：δ 无水平分量 → 不点亮（垂直边缘的台阶不在 x 上）
    //     dir=2 "/"   ：n=右上 q=左下 → δ>0 点亮左邻
    //     dir=3 "\"   ：n=左上 q=右下 → δ>0 点亮右邻
    //   对角方向的水平分量实际是 |δ|/√2≈0.707·|δ|，这里按需求原文
    //   「|δ| > 1/8」用 |δ| 判门限，不做 √2 缩放（省乘法器）。
    //
    //   2 px/clk 的邻点关系（一对像素 = 偶列 2p / 奇列 2p+1）：
    //     偶像素 左邻 = 上一拍的 pix1 → aa_rr1_d（1 拍寄存器）
    //            右邻 = 本拍的   pix1 → aa_rl1（同拍）
    //     奇像素 左邻 = 本拍的   pix0 → aa_rr0（打 1 拍成 aa_rr0_d）
    //            右邻 = 下一拍的 pix0 → aa_rl0（下一拍才出现）
    //   所以奇像素只能晚一拍定级 ⇒ o_aa 整体比 o_e 晚 1 拍输出，
    //   顶层用 1 拍寄存器对齐（见 ti60f225_oob_top.v 的 aa_d1）。
    //   AA_ON=0 或 SUBPIX_ON=0 时半强度项恒为 0，o_aa = {2{e}}（原二值行为，
    //   拍数不变，便于顶层无缝回退）。
    // ------------------------------------------------------------------
    wire aa_act = (AA_ON != 0) && (SUBPIX_ON != 0);   // 是否允许半强度等级

    // |δ| 门限（dq 是 Q4.4 的 |δ|·16，0..8）
    wire aa_mag0 = ({1'b0, dq0} >= AA_MAG_TH);
    wire aa_mag1 = ({1'b0, dq1} >= AA_MAG_TH);

    // δ > 0 ⇔ num_dirX == 0（峰位偏向 q 侧）
    wire aa_pos0 = ~num_dir0;
    wire aa_pos1 = ~num_dir1;

    // 该边缘像素把「半强度」请求投向哪一侧（hr=右邻 / hl=左邻）
    wire aa_hr0 = (d0n_2 == 2'd1) ? 1'b0 : ((d0n_2 == 2'd2) ? ~aa_pos0 :  aa_pos0);
    wire aa_hl0 = (d0n_2 == 2'd1) ? 1'b0 : ((d0n_2 == 2'd2) ?  aa_pos0 : ~aa_pos0);
    wire aa_hr1 = (d1n_2 == 2'd1) ? 1'b0 : ((d1n_2 == 2'd2) ? ~aa_pos1 :  aa_pos1);
    wire aa_hl1 = (d1n_2 == 2'd1) ? 1'b0 : ((d1n_2 == 2'd2) ?  aa_pos1 : ~aa_pos1);

    wire aa_e0c = e0f & pix_ok;
    wire aa_e1c = e1f & pix_ok;

    wire aa_rr0 = aa_e0c & aa_mag0 & aa_hr0;   // pix0 → 右邻(x+1)
    wire aa_rl0 = aa_e0c & aa_mag0 & aa_hl0;   // pix0 → 左邻(x−1)
    wire aa_rr1 = aa_e1c & aa_mag1 & aa_hr1;   // pix1 → 右邻(x+1)
    wire aa_rl1 = aa_e1c & aa_mag1 & aa_hl1;   // pix1 → 左邻(x−1)

    reg        aa_rr1_d;   // 上一拍 pix1 的「向右请求」= 本拍 pix0 的左邻
    reg        aa_rr0_d;   // 上一拍 pix0 的「向右请求」= 本拍 pix1 的左邻
    reg        aa_e0v, aa_e1v, aa_pokv;
    reg  [1:0] aa0_lv;     // pix0 等级（打一拍后与 pix1 同拍输出）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aa_rr1_d <= 1'b0;
            aa_rr0_d <= 1'b0;
            aa_e0v   <= 1'b0;
            aa_e1v   <= 1'b0;
            aa_pokv  <= 1'b0;
            aa0_lv   <= 2'd0;
        end else begin
            aa_rr1_d <= aa_rr1;
            aa_rr0_d <= aa_rr0;
            aa_e0v   <= aa_e0c;
            aa_e1v   <= aa_e1c;
            aa_pokv  <= pix_ok;
            // 偶像素：左邻来自上一拍（aa_rr1_d），右邻是本拍 pix1（aa_rl1）
            aa0_lv   <= pix_ok ? ( aa_e0c ? 2'd2 :
                                 ((aa_act && (aa_rr1_d | aa_rl1)) ? 2'd1 : 2'd0) )
                               : 2'd0;
        end
    end

    // 奇像素：左邻是本拍 pix0 的向右请求（aa_rr0_d = 上一拍），
    //         右邻是下一拍 pix0 的向左请求（aa_rl0 正好在下一拍出现）
    wire [1:0] aa1_lv = aa_pokv ? ( aa_e1v ? 2'd2 :
                                  ((aa_act && (aa_rr0_d | aa_rl0)) ? 2'd1 : 2'd0) )
                                : 2'd0;

    assign o_aa = { aa1_lv, aa0_lv };

    // 方案 E：边缘强度 = NMS 幅值（高 8 位），非边缘为 0…… 由顶层与 e/aa 组合使用
    wire [11:0] gs0 = gain_sat(G0n);
    wire [11:0] gs1 = gain_sat(G1n);
    assign o_mag = { (keep1 ? gs1[11:4] : 8'd0), (keep0 ? gs0[11:4] : 8'd0) };

    always @(*) begin
        o_de = d6_de;
        o_hs = d6_hs;
        o_vs = d6_vs;
        o_e  = { e1f & pix_ok, e0f & pix_ok };
        // 通路A：与 o_e 同拍（都是 8 拍数据 + 同一套 pix_ok 显示掩膜）
        o_e_sobel = { e1a & pix_ok, e0a & pix_ok };
        o_osd = { osd1 & {8{pix_ok}}, osd0 & {8{pix_ok}} };
    end

endmodule
