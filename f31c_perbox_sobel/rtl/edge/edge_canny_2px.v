//////////////////////////////////////////////////////////////////////////////
// edge_canny_2px.v ?? ?????????E1?Gauss + Sobel + Laplacian + ??????
//
//   ????? ?3/?4??
//     gray ??? [win_gray 3x3] ??? [Gauss 3x3 ??] ??? [win_gauss 3x3]
//                                                        ?? Sobel  ? gx,gy,G,dir
//                                                        ?? Laplacian ? L4,L8
//              ??? ????? (|G|>T1) && (|L4|>T2) ??? ????
//
//   * Gauss ??????? 8 ?? + ????????????
//   * Sobel ? Laplacian ???????????????????
//   * Sobel ??????3?3 ???G = |Gx| + |Gy|????
//   * T1 = i_threshold???????????T2 = T1 >> T2_SHIFT??? /4?
//   * ???????? 2 ? = 4 ??o_de/o_hs/o_vs ?? 4 ?
//
//   ?????parameter MAG_ISO_SEL??? 0??
//     MAG_ISO_SEL = 0 ? {G1,G0}   = |Gx|+|Gy|??????????????????
//     MAG_ISO_SEL = 1 ? {Gi1,Gi0} = max(|Gx|,|Gy|) + min(|Gx|,|Gy|)/2
//       ?????????????????? ? +41%??????????
//       ????????? 0.75??????? 0.85??
//       ? ?? MAG_ISO_SEL = 1 ??????????
//         T' ? 0.854?T = T - (T>>3) - (T>>6)   ???T=1024 ? T'=880?
//         ???? thr_loc / ??? T_lo ?? i_threshold ?????????
//       ???? T ????????????????????
//
//   ???? gx/gy/G/dir/L4/L8 ?????????? NMS/????????
//////////////////////////////////////////////////////////////////////////////
module edge_canny_2px #(
    parameter integer H_PAIRS  = 960,
    parameter integer ADDR_W   = 10,
    parameter integer GAUSS_ON    = 1,    // 1 = ???????0 = ????????? Sobel ???
    parameter integer LAP_GATE_ON = 0,    // 1 = ?? |L4| ??????0 = ?? |G|>T1????
    parameter integer T2_SHIFT    = 2,    // T2 = T1 >> T2_SHIFT
    parameter integer LOCAL_T_ON  = 1,    // 1 = ????????0 = ???? T1
    parameter integer LOCAL_SHIFT = 1,    // ?????T_local = ? >> LOCAL_SHIFT
    parameter integer SUBPIX_ON   = 1,    // 1 = ?????? + OSD
    parameter integer CANNY_HYST_ON = 1,  // 1 = ??? + ????
    parameter integer HYST_SHIFT  = 3,    // T_lo = T_hi >> HYST_SHIFT
    parameter integer GAIN_SHIFT  = 1,    // ?????? |G| ????????????? NMS?
    parameter MAG_ISO_SEL = 1'b0,         // ?????0 = |Gx|+|Gy|??????????1 = mag_iso
    parameter SHARP_EN    = 1'b0,
    parameter GAUSS2_ON   = 1'b0,   // O4：只用 1 级高斯，省 6 块 RAM（并保留更多弱边）         // 1 = ???????????
    parameter integer AA_ON      = 1,     // 1 = ?????????? o_aa?SUBPIX_ON=0 ??????
    parameter integer AA_MAG_TH  = 2,      // ??????dq ? AA_MAG_TH?Q4.4?2 ? |?| ? 1/8 = 0.125?
    // ================= 双通路（通路A：中值灰度直连 Sobel）=================
    //   通路A 只在模块内新增输出 o_e_sobel，默认参数下通路B（o_e/o_aa/o_mag/
    //   o_osd/o_bg/o_rgb）与改前逐位一致。
    //   GAUSS_BYPASS = 1 → 通路B 也跳过 1/2 级高斯，直连原始中值灰度
    //   （只用于双通路对比实验；顶层不传 ⇒ 0，通路B 行为不变）
    parameter integer GAUSS_BYPASS = 0
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
    // 通路A（赛题 B3 基础项）：中值灰度 → 直连 Sobel → |Gx|+|Gy| → 阈值二值化
    //   （无高斯 / 无 NMS / 无滞后 / 无增益 / 无 AA）
    //   与 o_e 严格同拍：通路B 数据链 2+2+2+2 = 8 拍，
    //                    通路A 直连 2 拍 + 6 拍对齐延迟 = 8 拍 ⇒ 差值 0 拍
    output reg  [1:0]         o_e_sobel,
    output wire [15:0]        o_mag,    // {pix1[7:0], pix0[7:0]} ?????NMS ???? 8 ??
    output wire [3:0]         o_aa,     // {pix1[1:0], pix0[1:0]} ??????0=? / 1=??? / 2=???
    output reg  [15:0]        o_osd,    // {px1, px0} ? OSD ??
    output reg  [15:0]        o_bg,     // ?????? {g1,g0}?? despeckle ?????
    output reg  [47:0]        o_rgb     // ?????? {rgb1,rgb0}????????????
);

    // ------------------------------------------------------------------
    // ?????
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
    // ?????? 3x3 ? ? Gauss ??
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
    // low_zone ?????????????? 2 ??
    reg lz1b, lz2b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lz1b <= 1'b0; lz2b <= 1'b0; end
        else begin lz1b <= low_zone; lz2b <= lz1b; end
    end
    wire low_zone_d2 = lz2b;
    wire [7:0] bg0 = (GAUSS_ON && !low_zone_d2) ? gsum0[11:4] : gy_mid[15:8];
    wire [7:0] bg1 = (GAUSS_ON && !low_zone_d2) ? gsum1[11:4] : gy_mid[23:16];
    //--------------------------------------------------------------------------
    // ??????k=2 ???????? ??1.06?????????????????
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
    // GAUSS_BYPASS = 1：通路B 直连原始中值灰度（1/2 级高斯全部跳过），
    //   但保留 win_gray2 的 2 拍直通延迟 —— 否则通路B 会比通路A 短 2 拍，
    //   双通路的相位对齐就失效了。顶层不传该参数（= 0）时这一路被常数选择掉。
    wire [7:0] rawg0 = gy_mid[15:8];      // 原始中值灰度（未滤波），通路A 的输入
    wire [7:0] rawg1 = gy_mid[23:16];

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
    // ??????P1-2?
    //   ?????i_g = ?????3x3 ?????? s-1??i_rgb = debayer ???
    //   ?????sim/tb_align.v???? s ?????
    //     o_bg  ???? = s-5   ??? 1 + win_gray 1 + bgfifo 3?
    //     o_e   ???? = s-4   ??? 1 + win_gray/win_band/win_mag ? 1?
    //     o_rgb ???? = s-3   ?rgbfifo 3?i_rgb ????????
    //   ? ?????? 1 ?????????? 2 ???????????
    //   ?????????? s-4???????????????
    //     ?? bgfifo 3 ? 2 ??? 1 ??
    //     ?? rgbfifo 3 ? 4 ??? 1 ??4 ???? 5 ? bank?4 bank ??????????
    //                          ?? 4 ???? 2 bank ??????? rg_d 5 ??? 4 ??
    //==========================================================================
    localparam integer GRAY_LINES = 3;

    // ---------------- ???? FIFO?GRAY_LINES ??4 bank?????----------------
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

    wire [1:0] brline = bwline - GRAY_LINES;      // ???2 ??? 3 ??
    wire [1:0] brgb3  = bwline - 2'd3;            // ??? FIFO ?? 3 ?

    always @(posedge clk) begin
        if (i_de)
            bgfifo[{bwline, pcol}] <= {bg1, bg0};
    end

    reg [15:0] bgf_q;
    always @(posedge clk) begin
        bgf_q <= bgfifo[{brline, pcol}];
    end

    // ?????? FIFO 3 ? + 1 ??? = 4 ??????? 1 ??
    reg  [47:0] rgbfifo [0:4095];
    always @(posedge clk) begin
        if (i_de)
            rgbfifo[{bwline, pcol}] <= i_rgb;
    end

    reg [47:0] rgbf_q;
    always @(posedge clk) begin
        rgbf_q <= rgbfifo[{brgb3, pcol}];
    end

    // ??? 1 ??2 bank ??????? bank=r1lp / ??? bank=??????? 2048 = 2^11
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
            // ???rgbf2_q(4 ?) + 4 ????? rgbf_q(3 ?) + 5 ???????????
            rg_d1 <= rgbf2_q; rg_d2 <= rg_d1; rg_d3 <= rg_d2;
            rg_d4 <= rg_d3;
            o_rgb <= rg_d4;
        end
    end



    // ------------------------------------------------------------------
    // ???????????? run-sum(?? 8 ? ?16 ??) + ???? IIR(N=3)
    //   T(x) = clamp(sqrt_table[vmean[7:3]], T/2, 2T)   ? ???? ? ????
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

    // ????????? BRAM?????????? hmean ??
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
    // ???? ? ???????? ? ? ?N?N ? ???
    //   ?? thr_loc = vmean >> 1 ????????????????????????
    //   ??????????????????????? ? ?????
    //   ?? 32 ? ? 8bit ???????
    //     sqrt_table[i] ? round(16??i),  i = vmean[7:3]?vmean = 8i ? 8i+7 ???
    //     ? thr_loc ? 16??(vmean/8) = ?(32?vmean) ? 5.657??vmean
    //   ????vmean = 128????i = 16?? 64??? vmean >> 1 ?????
    //   ????????????????????????????? ??
    //     ?????vmean=8 ? 16?? 4???????vmean=248 ? 89?? 124??
    //   8bit ???????? 89??? 12bit ????????
    //   LOCAL_SHIFT ??????? 2??????? 1 ? = ??????
    //   ???????????????????
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
    wire [11:0] thr_loc = {4'b0000, sqrt_table} >> SQRT_RSH;

    // ------------------------------------------------------------------
    // ?????thr_loc ? [T/2, 2T]
    //   ?? max(thr_loc, i_threshold) ??????? ?? ??????????
    //   ????????????vmean ? ? thr_loc ?????? i_threshold
    //   ?????LOCAL_T_ON ?????????????????????
    //     ?? T/2???????????????????????????
    //               ????????? T_ONLY ??????
    //     ?? 2T ????????????????????????
    //   2T ??? 1 ???????? LUT/?????T ?? 4032 ? 2T = 8064
    //   ?? 12bit???????? 13bit ???thr_hi ?? ? 4096 ???
    //   ???? 12bit ? thr_loc?????????????? thr_hi[11:0]
    //   ???????
    //   ???????? 1.5T ?? thr_hi ?? i_threshold + (i_threshold>>1)?
    //     ????? 12bit ??????? 2T?????????????
    //     max() ?????????
    // ------------------------------------------------------------------
    wire [11:0] thr_lo    = i_threshold >> 1;
    wire [12:0] thr_hi    = {1'b0, i_threshold} << 1;
    wire [12:0] thr_locx  = {1'b0, thr_loc};
    wire [11:0] thr_loc_c = (thr_locx < {1'b0, thr_lo}) ? thr_lo :
                            (thr_locx > thr_hi)         ? thr_hi[11:0] : thr_loc;

    wire [11:0] thr_eff = low_zone ? ((i_threshold > 12'd32) ? i_threshold : 12'd32)
                     : (LOCAL_T_ON ? thr_loc_c : i_threshold);
    // ------------------------------------------------------------------
    // ??????? 3x3 ??Sobel ? Laplacian ???
    // ------------------------------------------------------------------
    wire [31:0] raw_top, raw_mid, raw_bot;
    wire [ADDR_W-1:0] bw_x;

    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win_band (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_x (gy_x), .i_row (12'd0), .i_pair ({bs1, bs0}),
        .o_de (), .o_x (bw_x), .o_row (),
        .o_top (raw_top), .o_mid (raw_mid), .o_bot (raw_bot)
    );

    // ---- ???????? xm1 ? x0 ????? x2 ? x1 ?? ----
    wire at_left  = (bw_x == {ADDR_W{1'b0}});
    wire at_right = (bw_x == (H_PAIRS - 1));

    wire [31:0] bt_top = at_left  ? {raw_top[31:24], raw_top[23:16], raw_top[15:8], raw_top[15:8]} :
                         at_right ? {raw_top[23:16], raw_top[23:16], raw_top[15:8], raw_top[7:0]}  : raw_top;
    wire [31:0] bt_mid = at_left  ? {raw_mid[31:24], raw_mid[23:16], raw_mid[15:8], raw_mid[15:8]} :
                         at_right ? {raw_mid[23:16], raw_mid[23:16], raw_mid[15:8], raw_mid[7:0]}  : raw_mid;
    wire [31:0] bt_bot = at_left  ? {raw_bot[31:24], raw_bot[23:16], raw_bot[15:8], raw_bot[15:8]} :
                         at_right ? {raw_bot[23:16], raw_bot[23:16], raw_bot[15:8], raw_bot[7:0]}  : raw_bot;
    // ???????????????????
    // ---------------- Sobel???0 / ??1???????----------------
    wire signed [11:0] gx0, gy0, gx1, gy1;
    wire [11:0]        G0, G1;
    wire [11:0]        Gi0, Gi1;      // ?????????MAG_ISO_SEL = 1 ?? NMS?

    sobel_3x3 u_sob0 (
        .i_p00 (bt_top[7:0]),   .i_p01 (bt_top[15:8]),  .i_p02 (bt_top[23:16]),
        .i_p10 (bt_mid[7:0]),   .i_p11 (bt_mid[15:8]),  .i_p12 (bt_mid[23:16]),
        .i_p20 (bt_bot[7:0]),   .i_p21 (bt_bot[15:8]),  .i_p22 (bt_bot[23:16]),
        .o_gx (gx0), .o_gy (gy0), .o_magnitude (G0), .o_mag_iso (Gi0)
    );

    sobel_3x3 u_sob1 (
        .i_p00 (bt_top[15:8]),  .i_p01 (bt_top[23:16]), .i_p02 (bt_top[31:24]),
        .i_p10 (bt_mid[15:8]),  .i_p11 (bt_mid[23:16]), .i_p12 (bt_mid[31:24]),
        .i_p20 (bt_bot[15:8]),  .i_p21 (bt_bot[23:16]), .i_p22 (bt_bot[31:24]),
        .o_gx (gx1), .o_gy (gy1), .o_magnitude (G1), .o_mag_iso (Gi1)
    );

    // ??????????? NMS ???
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
    // 通路A（赛题 B3 基础项）：中值灰度 → 直连 Sobel → |Gx|+|Gy| → 阈值二值化
    //   * 不经过高斯：直接复用第一级 win_gray 的原始灰度窗 gy_top/gy_mid/gy_bot
    //   * 不经过 NMS / 双阈值滞后 / 增益 / AA：就是最朴素的 |Gx|+|Gy| > thr_eff
    //   * 列边界钳位规则与通路B 完全相同，只是对齐 gy_x（2 拍）而不是 bw_x（6 拍）
    //   * sobel_3x3 不传 KIND：F31c 工程没有该参数，默认口径就是 |Gx|+|Gy|
    //   * 拍数对齐：
    //       通路B 数据链 = win_gray 2 + win_gray2 2 + win_band 2 + win_mag 2 = 8 拍
    //       通路A 直连   = win_gray 2 拍
    //       ⇒ A 的 |Gx|+|Gy| 再打 6 拍，与 o_e 同拍（差值 = 0 拍），
    //         顶层直接与 o_e 共用 o_de/o_hs/o_vs，不需要再补延迟。
    //   * 阈值：与通路B 同一根 thr_eff（局部自适应 + 低档位地板，见上），
    //     但 **不乘 GAIN_SHIFT 增益**、不做滞后 —— 严格是 |Gx|+|Gy| > T。
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

    // 不传 KIND（F31c 的 sobel_3x3 无参数，默认 Sobel / |Gx|+|Gy|）
    sobel_3x3 u_sob_a0 (
        .i_p00 (ag_top[7:0]),   .i_p01 (ag_top[15:8]),  .i_p02 (ag_top[23:16]),
        .i_p10 (ag_mid[7:0]),   .i_p11 (ag_mid[15:8]),  .i_p12 (ag_mid[23:16]),
        .i_p20 (ag_bot[7:0]),   .i_p21 (ag_bot[15:8]),  .i_p22 (ag_bot[23:16]),
        .o_gx (gxa0), .o_gy (gya0), .o_magnitude (Ga0), .o_mag_iso (Gia0)
    );

    sobel_3x3 u_sob_a1 (
        .i_p00 (ag_top[15:8]),  .i_p01 (ag_top[23:16]), .i_p02 (ag_top[31:24]),
        .i_p10 (ag_mid[15:8]),  .i_p11 (ag_mid[23:16]), .i_p12 (ag_mid[31:24]),
        .i_p20 (ag_bot[15:8]),  .i_p21 (ag_bot[23:16]), .i_p22 (ag_bot[31:24]),
        .o_gx (gxa1), .o_gy (gya1), .o_magnitude (Ga1), .o_mag_iso (Gia1)
    );

    // ---- 6 拍对齐延迟（使通路A 的 |Gx|+|Gy| 与通路B 的 o_e 同拍）----
    reg [11:0] ga0_d1, ga0_d2, ga0_d3, ga0_d4, ga0_d5, ga0_d6;
    reg [11:0] ga1_d1, ga1_d2, ga1_d3, ga1_d4, ga1_d5, ga1_d6;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ga0_d1 <= 12'd0; ga0_d2 <= 12'd0; ga0_d3 <= 12'd0;
            ga0_d4 <= 12'd0; ga0_d5 <= 12'd0; ga0_d6 <= 12'd0;
            ga1_d1 <= 12'd0; ga1_d2 <= 12'd0; ga1_d3 <= 12'd0;
            ga1_d4 <= 12'd0; ga1_d5 <= 12'd0; ga1_d6 <= 12'd0;
        end else begin
            ga0_d1 <= Ga0;   ga0_d2 <= ga0_d1; ga0_d3 <= ga0_d2;
            ga0_d4 <= ga0_d3; ga0_d5 <= ga0_d4; ga0_d6 <= ga0_d5;
            ga1_d1 <= Ga1;   ga1_d2 <= ga1_d1; ga1_d3 <= ga1_d2;
            ga1_d4 <= ga1_d3; ga1_d5 <= ga1_d4; ga1_d6 <= ga1_d5;
        end
    end

    // 纯阈值二值化（无 NMS、无滞后、无增益）
    wire e0a = (ga0_d6 > thr_eff);
    wire e1a = (ga1_d6 > thr_eff);

    // ------------------------------------------------------------------
    // NMS?|G| ? 3x3 ??DW=24??? 12bit ?????
    //   ????? MAG_ISO_SEL ??????? 12bit??????????
    //     MAG_ISO_SEL = 0 ? {G1, G0}   = |Gx|+|Gy|      ?????????
    //     MAG_ISO_SEL = 1 ? {Gi1, Gi0} = max(|Gx|,|Gy|) + min(|Gx|,|Gy|)/2
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

    // ?? {x2,x1,x0,xm1} = [47:36],[35:24],[23:12],[11:0]
    // ??0 ?? = x0 ????1 ?? = x1 ?
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

    // ????? 2 ??????????
    reg [1:0] d0n_1, d0n_2, d1n_1, d1n_2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin d0n_1 <= 2'd0; d0n_2 <= 2'd0; d1n_1 <= 2'd0; d1n_2 <= 2'd0; end
        else begin d0n_1 <= dir0; d0n_2 <= d0n_1; d1n_1 <= dir1; d1n_2 <= d1n_1; end
    end

    // ?????H/V = 0/1?"/" = 2?"\ " = 3?
    wire [11:0] n0 = (d0n_2 == 2'd0) ? p0_l  : (d0n_2 == 2'd1) ? p0_u  :
                     (d0n_2 == 2'd2) ? p0_ur : p0_ul;
    wire [11:0] q0 = (d0n_2 == 2'd0) ? p0_r  : (d0n_2 == 2'd1) ? p0_d  :
                     (d0n_2 == 2'd2) ? p0_dl : p0_dr;
    wire [11:0] n1 = (d1n_2 == 2'd0) ? p1_l  : (d1n_2 == 2'd1) ? p1_u  :
                     (d1n_2 == 2'd2) ? p1_ur : p1_ul;
    wire [11:0] q1 = (d1n_2 == 2'd0) ? p1_r  : (d1n_2 == 2'd1) ? p1_d  :
                     (d1n_2 == 2'd2) ? p1_dl : p1_dr;

    // keep = ??????????????????????
    //   (G0 >= G_neg) && (G0 >= G_pos) && ((G0 > G_neg) || (G0 > G_pos))
    //   ???????????????????????????
    //   ???????????????????????????????????
    //   ??????????? NMS???? >= ???????
    // ---------------- C2???????????????----------------
    //   G' = 2?G ? (up+down+left+right)/4   ??? G + 0.25?(4G ? S)?
    //   ???????4 ???????? NMS ???????????
    wire [12:0] s0sum = {1'b0,p0_u} + {1'b0,p0_d} + {1'b0,p0_l} + {1'b0,p0_r};
    wire [12:0] s1sum = {1'b0,p1_u} + {1'b0,p1_d} + {1'b0,p1_l} + {1'b0,p1_r};
    // ?????"?? 4 ????"?= m + 0.25???m = S/4??????
    wire [11:0] c0s   = SHARP_EN ? s0sum[13:2] : p0_c;
    wire [11:0] c1s   = SHARP_EN ? s1sum[13:2] : p1_c;

    wire keep0 = (c0s >= n0) && (c0s >= q0) && ((c0s > n0) || (c0s > q0));
    wire keep1 = (c1s >= n1) && (c1s >= q1) && ((c1s > n1) || (c1s > q1));

    wire [11:0] G0n = keep0 ? c0s : 12'd0;
    wire [11:0] G1n = keep1 ? c1s : 12'd0;
    // ---------------- ????????????????? NMS?----------------
    function automatic [11:0] gain_sat;
        input [11:0] g;
        begin
            gain_sat = (g > (12'hFFF >> GAIN_SHIFT)) ? 12'hFFF : (g << GAIN_SHIFT);
        end
    endfunction
    // ------------------------------------------------------------------
    // ???????? = 0.5?(G??G?)/(G??2G?+G?)?Q4.4
    //   ?? G??G? ? G??G??|?|?16 = 8|num|/|den| ? [0,8]?? 4 ?????
    // ------------------------------------------------------------------
    wire [11:0] num0 = (n0 >= q0) ? (n0 - q0) : (q0 - n0);      // |G? ? G?|
    wire [11:0] den0 = (c0s - n0) + (c0s - q0);               // |den| = 2G0?G??G?
    wire [11:0] num1 = (n1 >= q1) ? (n1 - q1) : (q1 - n1);
    wire num_dir0 = (n0 >= q0);        // 0 = ? ??
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

    // OSD??????? 3 ??????? ? |?|?4 ?? Q4.4??? 4 ?? 8bit?
    // ---- ???????OSD ?????????? ----
    reg  [9:0] ocol;
    wire       e0, e1, e0f, e1f;
    wire [7:0] osd_num, osd_mode;
    reg        d6_de;

    reg [11:0] row_d6;
    wire osd_row = (row_d6 == 12'd536) || (row_d6 == 12'd537) || (row_d6 == 12'd538);

    // ?????????????e0/e1???????????????
    wire [7:0] osd0 = (SUBPIX_ON && osd_row && e0f) ? {dq0, 4'b0000} : (osd_num | osd_mode);
    wire [7:0] osd1 = (SUBPIX_ON && osd_row && e1f) ? {dq1, 4'b0000} : (osd_num | osd_mode);
    // ------------------------------------------------------------------
    // OSD ????????(?? ? |?|?0~16px) + ???(?>0 ??)
    //   ??????????? NMS ????? ????????????
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
    wire [9:0] bar_x   = {ocol, 1'b0};                  // ???? x
    wire       bar_on  = (bar_x >= 10'd100) &&
                         ((bar_x - 10'd100) < {1'b0, bar_len});
    wire       sign_on = (bar_x == 10'd96) && disp_sg;

    assign osd_num = (SUBPIX_ON && osd_row && (bar_on || sign_on)) ? 8'hFF : 8'd0;

    // ?????????? x 8..16 / y 8..16?????? 0x40??????? 0xFF
    wire ind_on = (row_d6 >= 12'd8) && (row_d6 < 12'd16) &&
                  (bar_x >= 10'd8) && (bar_x < 10'd16);
    assign osd_mode = ind_on ? (low_zone ? 8'hFF : 8'hC0) : 8'd0;
    // ---------------- Laplacian??????----------------
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

    // L8??????????????????????
    wire [10:0] s8_0 = bt_top[7:0]   + bt_top[15:8]   + bt_top[23:16]
                     + bt_mid[7:0]   +                  bt_mid[23:16]
                     + bt_bot[7:0]   + bt_bot[15:8]   + bt_bot[23:16];
    wire [10:0] s8_1 = bt_top[15:8]  + bt_top[23:16]  + bt_top[31:24]
                     + bt_mid[15:8]  +                  bt_mid[31:24]
                     + bt_bot[15:8]  + bt_bot[23:16]  + bt_bot[31:24];

    wire signed [12:0] L8_0 = $signed({2'b00, c0, 3'b000}) - $signed({2'b00, s8_0});
    wire signed [12:0] L8_1 = $signed({2'b00, c1, 3'b000}) - $signed({2'b00, s8_1});

    // ---- ??????????????????????----
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
    // ---- ????vsync ??????+ 4 ??? + ? 2 ??? ----
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

    // ?? 3x3 ??????????? 4 ??????????? 1 ??2 ???
    // ?? 3x3 ??????????? 4 ???
    // ??/?????????????????????????????
    wire pix_ok = (row_d6 >= 12'd6) &&
                   (ocol != {ADDR_W{1'b0}}) &&
                   (ocol < (H_PAIRS - 2));
    // ---------------- ????? ----------------
    wire [11:0] T2 = i_threshold >> T2_SHIFT;

    assign e0 = ((gain_sat(G0n) > thr_eff) && (LAP_GATE_ON ? (absL4_0 > T2) : 1'b1));
    assign e1 = ((gain_sat(G1n) > thr_eff) && (LAP_GATE_ON ? (absL4_1 > T2) : 1'b1));

    // ---------------- Canny ??? + ?? 8 ???? ----------------
    //   ?? strong ??????? |G| 3x3 ??NMS ?????
    //   ???????? strong ??????????????
    wire [11:0] T_lo = i_threshold >> HYST_SHIFT;

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
    // ???? 4 ?
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
    // ???????AA??????? 2 bit?{pix1,pix0}
    //   0 = ?? / 1 = ??? / 2 = ???
    //
    //   ????????
    //     * ????????e0f/e1f?                            ? 2
    //     * ????????(x?1 ? x+1)???????????? ?
    //       ??????|?| > 1/8?Q4.4 ? dq ? AA_MAG_TH?      ? 1
    //     * ??                                                ? 0
    //
    //   ? ????num_dirX = (G? ? G?)?0 ?? ? > 0???????? q ???
    //   n/q ?? NMS ??????????????????
    //     dir=0 ??  ?n=?  q=?   ? ?>0 ????
    //     dir=1 ??  ?? ????? ? ????????????? x ??
    //     dir=2 "/"   ?n=?? q=?? ? ?>0 ????
    //     dir=3 "\"   ?n=?? q=?? ? ?>0 ????
    //   ???????????? |?|/?2?0.707?|?|????????
    //   ?|?| > 1/8?? |?| ?????? ?2 ?????????
    //
    //   2 px/clk ?????????? = ?? 2p / ?? 2p+1??
    //     ??? ?? = ???? pix1 ? aa_rr1_d?1 ?????
    //            ?? = ???   pix1 ? aa_rl1????
    //     ??? ?? = ???   pix0 ? aa_rr0?? 1 ?? aa_rr0_d?
    //            ?? = ???? pix0 ? aa_rl0????????
    //   ???????????? ? o_aa ??? o_e ? 1 ????
    //   ??? 1 ???????? ti60f225_oob_top.v ? aa_d1??
    //   AA_ON=0 ? SUBPIX_ON=0 ??????? 0?o_aa = {2{e}}???????
    //   ???????????????
    // ------------------------------------------------------------------
    wire aa_act = (AA_ON != 0) && (SUBPIX_ON != 0);   // ?????????

    // |?| ???dq ? Q4.4 ? |?|?16?0..8?
    wire aa_mag0 = ({1'b0, dq0} >= AA_MAG_TH);
    wire aa_mag1 = ({1'b0, dq1} >= AA_MAG_TH);

    // ? > 0 ? num_dirX == 0????? q ??
    wire aa_pos0 = ~num_dir0;
    wire aa_pos1 = ~num_dir1;

    // ???????????????????hr=?? / hl=???
    wire aa_hr0 = (d0n_2 == 2'd1) ? 1'b0 : ((d0n_2 == 2'd2) ? ~aa_pos0 :  aa_pos0);
    wire aa_hl0 = (d0n_2 == 2'd1) ? 1'b0 : ((d0n_2 == 2'd2) ?  aa_pos0 : ~aa_pos0);
    wire aa_hr1 = (d1n_2 == 2'd1) ? 1'b0 : ((d1n_2 == 2'd2) ? ~aa_pos1 :  aa_pos1);
    wire aa_hl1 = (d1n_2 == 2'd1) ? 1'b0 : ((d1n_2 == 2'd2) ?  aa_pos1 : ~aa_pos1);

    wire aa_e0c = e0f & pix_ok;
    wire aa_e1c = e1f & pix_ok;

    wire aa_rr0 = aa_e0c & aa_mag0 & aa_hr0;   // pix0 ? ??(x+1)
    wire aa_rl0 = aa_e0c & aa_mag0 & aa_hl0;   // pix0 ? ??(x?1)
    wire aa_rr1 = aa_e1c & aa_mag1 & aa_hr1;   // pix1 ? ??(x+1)
    wire aa_rl1 = aa_e1c & aa_mag1 & aa_hl1;   // pix1 ? ??(x?1)

    reg        aa_rr1_d;   // ??? pix1 ???????= ?? pix0 ???
    reg        aa_rr0_d;   // ??? pix0 ???????= ?? pix1 ???
    reg        aa_e0v, aa_e1v, aa_pokv;
    reg  [1:0] aa0_lv;     // pix0 ???????? pix1 ?????

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
            // ????????????aa_rr1_d??????? pix1?aa_rl1?
            aa0_lv   <= pix_ok ? ( aa_e0c ? 2'd2 :
                                 ((aa_act && (aa_rr1_d | aa_rl1)) ? 2'd1 : 2'd0) )
                               : 2'd0;
        end
    end

    // ????????? pix0 ??????aa_rr0_d = ?????
    //         ?????? pix0 ??????aa_rl0 ?????????
    wire [1:0] aa1_lv = aa_pokv ? ( aa_e1v ? 2'd2 :
                                  ((aa_act && (aa_rr0_d | aa_rl0)) ? 2'd1 : 2'd0) )
                                : 2'd0;

    assign o_aa = { aa1_lv, aa0_lv };

    // ?? E????? = NMS ???? 8 ??????? 0?? ???? e/aa ????
    wire [11:0] gs0 = gain_sat(G0n);
    wire [11:0] gs1 = gain_sat(G1n);
    assign o_mag = { (keep1 ? gs1[11:4] : 8'd0), (keep0 ? gs0[11:4] : 8'd0) };

    always @(*) begin
        o_de = d6_de;
        o_hs = d6_hs;
        o_vs = d6_vs;
        o_e  = { e1f & pix_ok, e0f & pix_ok };
        // 通路A：与 o_e 同拍（同样是 8 拍数据 + 同一套 pix_ok 显示掩膜）
        o_e_sobel = { e1a & pix_ok, e0a & pix_ok };
        o_osd = { osd1 & {8{pix_ok}}, osd0 & {8{pix_ok}} };
    end

endmodule
