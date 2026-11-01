//==============================================================================
// tb_offset_sys.v —— 「检测框(OSD bbox) ↔ 显示图像」像素偏移精确测量
//
//   目的：一次性测出 shape_osd 的 box 与显示图像之间的行/列偏移，
//         从而给出唯一正确的 XOFF / YOFF，替代上板试错。
//
//   本 TB **逐行复刻顶层 ti60f225_oob_top.v 的视频通路**（不改任何 RTL）：
//
//     camera 2px/clk (vid_clk_dvi2, 74.25MHz)
//        │ i_g0/i_g1
//        ├─► median3x3_2px ──────────────► f_g0/f_g1 (GRAY_ONLY=1, MEDIAN_ON=1)
//        │                                   ├─► shape_recog  → o_bx0/o_by0   （形状通路）
//        │                                   └─► edge_canny_2px i_g0/i_g1    （显示通路）
//        └─► rgb 打 2 拍 ───────────────► edge_canny_2px i_rgb
//
//     edge_canny.o_e ─► despeckle_2px ─► dsp_e/dsp_de
//     edge_canny.o_bg ─► comp_gray_pix_r ─► composer 写 (地址 = comp_x)  ┐
//     edge_canny.o_e  ─► hdmi_tx_rdata  ─► comp_edge_pix ─► composer 写  ┘
//     composer 读地址（顶层 1526-1535 行原样）：
//         comp_x < 960 → comp_rd_addr = comp_x + 480
//         comp_x ≥ 960 → comp_rd_addr = comp_x - 480
//     同步读 1 拍（comp_gray_q）→ comp_o_r/g/b（组合）→ DSI
//     shape_osd 用 comp_x / fr_y（hdmi_tx_slow_clk 域，148.5MHz）
//
//   两条独立测量（都是"同一帧内"、逐像素）：
//     A. 形状通路：合成帧里方块的真值 (X_cam,Y_cam) vs shape_recog 的 o_bx0/o_by0
//     B. 显示通路：同一帧里，屏幕上出现的方块暗像素 bbox  → 反推 "cam→屏" 映射
//        以及 shape_osd 画出的 box 的屏幕 bbox
//     两条一比 → 需要的 XOFF/YOFF。
//
//   图案模式（+pat=N）：
//     0 = 方块（默认）：白底 255 + 暗块 30，用于 bbox / 显示 / 框 三方比对
//     1 = 竖条纹：像素值 = cam_x & 255 → 显示端读到值即为相机 x（精确到 1px）
//     2 = 横条纹：像素值 = cam_row     → 显示端读到值即为相机行（精确到 1 行）
//     3 = 脉冲块：黑底 + 4x4 亮块 → 粗测三通路延迟
//
//   运行（在 v6_edge 根目录，shape_tmpl 用相对路径读 .mem）：
//     iverilog -g2012 -s tb_offset_sys -o sim/tb_offset_sys.vvp sim/tb_offset_sys.v \
//       rtl/median3x3_2px.v rtl/edge/edge_canny_2px.v rtl/edge/win3x3_2px.v \
//       rtl/edge/sobel_3x3.v rtl/simple_dual_port_ram.v rtl/edge/despeckle_2px.v \
//       rtl/edge/shape_recog.v rtl/edge/shape_tmpl.v rtl/edge/shape_osd.v
//     vvp sim/tb_offset_sys.vvp             # 方块模式，3 个位置
//     vvp sim/tb_offset_sys.vvp +pat=1      # 竖条纹（精确列映射）
//     vvp sim/tb_offset_sys.vvp +pat=2      # 横条纹（精确行映射）
//     vvp sim/tb_offset_sys.vvp +pat=3      # 延迟链粗测
//==============================================================================
`timescale 1ns/1ps
module tb_offset_sys;

    //--------------------------------------------------------------------------
    // 帧格式（宽度必须是 1920，保证 composer / OSD 与板上一一对应）
    //   VL 取 120 只是为了仿真快：本测量只依赖行/列计数的相对关系
    //--------------------------------------------------------------------------
    localparam integer HP    = 960;      // 每行像素对 = 1920 px
    localparam integer VL    = 120;      // 每帧行数
    localparam integer HGAP  = 8;        // 行消隐（像素对）
    localparam integer NFR   = 2;        // 每个 case 帧数（第 2 帧测量）
    localparam [11:0]  THR   = 12'd400;  // 边缘阈值（顶层默认量级）

    //--------------------------------------------------------------------------
    // 时钟：hdmi_tx_slow_clk = 2 × vid_clk_dvi2（peri.xml: out_divider 20 / 40）
    //--------------------------------------------------------------------------
    reg vclk = 1'b0;
    reg hclk = 1'b0;
    reg rst_n = 1'b0;
    always #6.734 vclk = ~vclk;          // 13.468 ns → 74.25 MHz
    always #3.367 hclk = ~hclk;          //  6.734 ns → 148.5 MHz

    //--------------------------------------------------------------------------
    // 相机侧激励
    //--------------------------------------------------------------------------
    reg        i_de = 1'b0, i_hs = 1'b0, i_vs = 1'b0;
    reg  [7:0] i_g0 = 8'd0, i_g1 = 8'd0;
    reg [47:0] i_rgb = 48'd0;

    integer pat = 0;                     // 0 方块 / 1 竖条纹 / 2 横条纹 / 3 脉冲
    integer sqx0 = 700, sqx1 = 800;      // 方块相机坐标（含端点，取 4 的倍数）
    integer sqy0 = 40,  sqy1 = 80;
    integer pls_x = 500, pls_y = 60;     // 脉冲块左上角（相机坐标）

    function [7:0] pixval(input integer x, input integer y);
        integer m;
        begin
            if (pat == 0 || pat == 4 || pat == 5)
                pixval = ((x >= sqx0) && (x <= sqx1) &&
                          (y >= sqy0) && (y <= sqy1)) ? 8'd30 : 8'd255;
            else if (pat == 1) begin
                m = x % 256; if (m < 0) m = m + 256;
                pixval = m;
            end else if (pat == 2) begin
                m = y % 256; if (m < 0) m = m + 256;
                pixval = m;
            end else
                pixval = ((x >= pls_x) && (x <= pls_x + 3) &&
                          (y >= pls_y) && (y <= pls_y + 3)) ? 8'd200 : 8'd20;
        end
    endfunction

    task send_line(input integer r);
        integer p;
        reg [7:0] v0, v1;
        begin
            for (p = 0; p < HP; p = p + 1) begin
                i_de = 1'b1;
                v0 = pixval(2*p,     r);
                v1 = pixval(2*p + 1, r);
                i_g0 = v0; i_g1 = v1;
                i_rgb = {v1, v1, v1, v0, v0, v0};
                @(posedge vclk); #1;
            end
            i_de = 1'b0; i_g0 = 8'd0; i_g1 = 8'd0; i_rgb = 48'd0;
            repeat (HGAP) @(posedge vclk);
            #1;
        end
    endtask

    // 帧前 vs 消隐（med_vs / dsp_vs 都要看到）
    task send_vs_blank;
        begin
            i_de = 1'b0; i_vs = 1'b1;
            repeat (2*(HP+HGAP)) @(posedge vclk); #1;
            i_vs = 1'b0;
            repeat (6) @(posedge vclk); #1;
        end
    endtask

    task send_frame;
        integer r;
        begin
            send_vs_blank;
            for (r = 0; r < VL; r = r + 1) send_line(r);
            repeat (8) @(posedge vclk); #1;
        end
    endtask

    //==========================================================================
    // 视频通路（与顶层同构）
    //==========================================================================
    // ---- median3x3（顶层 u_median3x3）----
    wire        m_de, m_hs, m_vs, m_va;
    wire [7:0]  m_g0, m_g1;

    median3x3_2px u_median3x3 (
        .clk    (vclk), .rst_n (rst_n),
        .i_de   (i_de), .i_hs (i_hs), .i_vs (i_vs), .i_valid (i_de),
        .i_g0   (i_g0), .i_g1 (i_g1),
        .o_de   (m_de), .o_hs (m_hs), .o_vs (m_vs), .o_valid (m_va),
        .o_g0   (m_g0), .o_g1 (m_g1)
    );

    // ---- rgb 打 2 拍（顶层 rgb_in_d1/d2）----
    reg [47:0] rgb_in_d1, rgb_in_d2;
    always @(posedge vclk or negedge rst_n) begin
        if (!rst_n) begin rgb_in_d1 <= 48'd0; rgb_in_d2 <= 48'd0; end
        else begin rgb_in_d1 <= i_rgb; rgb_in_d2 <= rgb_in_d1; end
    end

    // ---- shape_recog（顶层 u_shape_recog；BOX_ON_ANY=1 只为保证框一定画出来，
    //      box 的几何与类别判定无关）----
    wire [2:0]  shp_cls;
    wire [10:0] shp_bx0, shp_bx1, shp_by0, shp_by1;
    wire        shp_box_en;
    wire [3:0]  shp_best_idx;
    wire [13:0] shp_best_cnt;
    wire        shp_upd;

    shape_recog #(
        .H_PAIRS   (HP),
        .V_LINES   (VL),
        .TY        (8'd170),
        .THAM      (256),
        .TMPL_MIN  (32),
        .CELL_W    (480),
        .CELL_H    (270),
        .A_MIN     (10),
        .A_MAX     (60000),
        .BOX_ON_ANY(1),
        .WIN_EN    (0)
    ) u_shape_recog (
        .clk   (vclk), .rst_n (rst_n),
        .i_de  (m_de), .i_vs (m_vs),
        .i_g0  (m_g0), .i_g1 (m_g1),
        .o_cls (shp_cls), .o_upd (shp_upd),
        .o_bx0 (shp_bx0), .o_bx1 (shp_bx1),
        .o_by0 (shp_by0), .o_by1 (shp_by1),
        .o_box_en (shp_box_en),
        .o_best_idx (shp_best_idx), .o_best_cnt (shp_best_cnt)
    );

    // ---- edge_canny（顶层 u_edge_canny：GRAY_ONLY=1 → 输入就是 med 灰度）----
    wire        c_de, c_hs, c_vs;
    wire [1:0]  c_e;
    wire [15:0] c_osd, c_bg;
    wire [47:0] c_rgb;

    edge_canny_2px #(
        .H_PAIRS    (HP),
        .ADDR_W     (10),
        .T2_SHIFT   (2),
        .HYST_SHIFT (4)
    ) u_edge_canny (
        .clk (vclk), .rst_n (rst_n),
        .i_de (m_de), .i_hs (m_hs), .i_vs (m_vs),
        .i_g0 (m_g0), .i_g1 (m_g1),
        .i_threshold (THR),
        .o_de (c_de), .o_hs (c_hs), .o_vs (c_vs),
        .o_e (c_e), .o_osd (c_osd), .o_bg (c_bg), .o_rgb (c_rgb),
        .i_rgb (rgb_in_d2)
    );

    wire [47:0] c_rgbx2 = { {8{c_e[1]}}, {8{c_e[1]}}, {8{c_e[1]}},
                            {8{c_e[0]}}, {8{c_e[0]}}, {8{c_e[0]}} };

    // ---- despeckle（顶层 u_despeckle, MIN_NEI=1）----
    wire        d_de, d_hs, d_vs;
    wire [1:0]  d_e;

    despeckle_2px #(
        .H_PAIRS (HP), .ADDR_W (10), .MIN_NEI (1)
    ) u_despeckle (
        .clk (vclk), .rst_n (rst_n),
        .i_de (c_de), .i_hs (c_hs), .i_vs (c_vs),
        .i_e ({c_rgbx2[24], c_rgbx2[0]}),
        .o_de (d_de), .o_hs (d_hs), .o_vs (d_vs), .o_e (d_e)
    );

    wire [47:0] d_rgbx2 = { {8{d_e[1]}}, {8{d_e[1]}}, {8{d_e[1]}},
                            {8{d_e[0]}}, {8{d_e[0]}}, {8{d_e[0]}} };

    //==========================================================================
    // 各级"暗像素 bbox"探针：给出每一级内容在自己的 de 坐标系里的位置，
    // 与相机真值一比就是该级的行/列延迟（这正是对齐用的量）
    //==========================================================================
    wire [11:0] pb_in_x0, pb_in_x1, pb_in_y0, pb_in_y1;
    wire [11:0] pb_md_x0, pb_md_x1, pb_md_y0, pb_md_y1;
    wire [11:0] pb_bg_x0, pb_bg_x1, pb_bg_y0, pb_bg_y1;
    wire [11:0] pb_e_x0,  pb_e_x1,  pb_e_y0,  pb_e_y1;
    wire [11:0] pb_d_x0,  pb_d_x1,  pb_d_y0,  pb_d_y1;
    wire [31:0] pb_in_n, pb_md_n, pb_bg_n, pb_e_n, pb_d_n;

    stage_probe #(.HP(HP)) p_in (
        .clk(vclk), .rst_n(rst_n), .i_vs(i_vs), .i_de(i_de),
        .d0(i_g0 < 8'd128), .d1(i_g1 < 8'd128),
        .minx(pb_in_x0), .maxx(pb_in_x1), .miny(pb_in_y0), .maxy(pb_in_y1), .cnt(pb_in_n));

    stage_probe #(.HP(HP)) p_med (
        .clk(vclk), .rst_n(rst_n), .i_vs(m_vs), .i_de(m_de),
        .d0(m_g0 < 8'd128), .d1(m_g1 < 8'd128),
        .minx(pb_md_x0), .maxx(pb_md_x1), .miny(pb_md_y0), .maxy(pb_md_y1), .cnt(pb_md_n));

    stage_probe #(.HP(HP)) p_bg (
        .clk(vclk), .rst_n(rst_n), .i_vs(c_vs), .i_de(c_de),
        .d0(c_bg[7:0] < 8'd128), .d1(c_bg[15:8] < 8'd128),
        .minx(pb_bg_x0), .maxx(pb_bg_x1), .miny(pb_bg_y0), .maxy(pb_bg_y1), .cnt(pb_bg_n));

    stage_probe #(.HP(HP)) p_e (
        .clk(vclk), .rst_n(rst_n), .i_vs(c_vs), .i_de(c_de),
        .d0(c_e[0] != 1'b0), .d1(c_e[1] != 1'b0),
        .minx(pb_e_x0), .maxx(pb_e_x1), .miny(pb_e_y0), .maxy(pb_e_y1), .cnt(pb_e_n));

    stage_probe #(.HP(HP)) p_d (
        .clk(vclk), .rst_n(rst_n), .i_vs(d_vs), .i_de(d_de),
        .d0(d_e[0] != 1'b0), .d1(d_e[1] != 1'b0),
        .minx(pb_d_x0), .maxx(pb_d_x1), .miny(pb_d_y0), .maxy(pb_d_y1), .cnt(pb_d_n));

    //==========================================================================
    // HDMI 域（与顶层 1396-1557 行逐行同构）
    //==========================================================================
    reg        vid_cnt  = 1'b0;
    reg        rgb_vs_r = 1'b0;
    reg        h_vs = 1'b0, h_hs = 1'b0, h_de = 1'b0;
    reg  [7:0] h_rdata = 8'd0, h_gdata = 8'd0, h_bdata = 8'd0;
    wire       pos_vs = ({rgb_vs_r, d_vs} == 2'b01);

    always @(posedge hclk) begin
        rgb_vs_r <= d_vs;
        if (pos_vs)          vid_cnt <= 1'b1;
        else if (d_de)       vid_cnt <= ~vid_cnt;

        if (vid_cnt) {h_bdata, h_gdata, h_rdata} <= {d_rgbx2[23:8], d_rgbx2[7:0]};
        else         {h_bdata, h_gdata, h_rdata} <= {d_rgbx2[47:32], d_rgbx2[31:24]};

        h_vs <= d_vs;
        h_hs <= d_hs;
        h_de <= d_de;
    end

    // ---- 灰度/彩色锁存（顶层 1489-1498；WB 对偏移无影响，此处直通）----
    reg  [7:0]  comp_gray_pix_r = 8'd0;
    reg  [23:0] comp_rgb_pix    = 24'd0;
    always @(posedge hclk) begin
        if (vid_cnt) comp_gray_pix_r <= c_bg[7:0];
        else         comp_gray_pix_r <= c_bg[15:8];
        comp_rgb_pix <= c_rgb[23:0];
    end

    // ---- composer 行缓存（顶层 1436-1519）----
    reg  [7:0]  cg_mem [0:4095];
    reg  [7:0]  ce_mem [0:4095];
    reg [23:0]  cr_mem [0:4095];
    reg         comp_line_par = 1'b0;
    reg         comp_de_prev  = 1'b0;
    reg  [10:0] comp_x        = 11'd0;

    always @(posedge hclk) begin
        comp_de_prev <= h_de;
        if (!h_de) comp_x <= 11'd0;
        else       comp_x <= comp_x + 11'd1;
        if (comp_de_prev && !h_de) comp_line_par <= ~comp_line_par;
    end

    always @(posedge hclk) begin
        if (h_de) begin
            cg_mem[{comp_line_par, comp_x}] <= comp_gray_pix_r;
            ce_mem[{comp_line_par, comp_x}] <= h_rdata;
            cr_mem[{comp_line_par, comp_x}] <= comp_rgb_pix;
        end
    end

    // ---- 读地址（顶层 1521-1535 原样：左半 comp_x+480，右半 comp_x-480）----
    wire [10:0] comp_rd_addr = (comp_x < 11'd960) ? (comp_x + 11'd480)
                                                  : (comp_x - 11'd480);
    wire        comp_rd_edge = (comp_x >= 11'd960);

    reg  [7:0]  comp_gray_q, comp_edge_q;
    reg  [23:0] comp_rgb_q;
    reg         comp_de_o, comp_hs_o, comp_vs_o;
    reg         comp_rd_edge_d;
    reg  [10:0] rd_addr_d1;

    always @(posedge hclk) begin
        comp_de_o      <= h_de;
        comp_hs_o      <= h_hs;
        comp_vs_o      <= h_vs;
        comp_rd_edge_d <= comp_rd_edge;
        rd_addr_d1     <= comp_rd_addr;
        comp_gray_q    <= cg_mem[{~comp_line_par, comp_rd_addr}];
        comp_edge_q    <= ce_mem[{~comp_line_par, comp_rd_addr}];
        comp_rgb_q     <= cr_mem[{~comp_line_par, comp_rd_addr}];
    end

    wire [7:0] comp_data = comp_rd_edge_d ? comp_edge_q : comp_gray_q;

    // ---- fr_y（顶层 1581-1586）----
    reg [11:0] fr_y;
    always @(posedge hclk or negedge rst_n) begin
        if (!rst_n)                        fr_y <= 12'd0;
        else if (h_vs)                     fr_y <= 12'd0;
        else if (comp_de_prev && !h_de)    fr_y <= fr_y + 12'd1;
    end

    // ---- 跨域 2FF（顶层 1641-1683）----
    wire [43:0] shp_box_v = {shp_bx0, shp_bx1, shp_by0, shp_by1};
    reg  [43:0] box_s1, box_s2;
    always @(posedge hclk or negedge rst_n) begin
        if (!rst_n) begin box_s1 <= 44'd0; box_s2 <= 44'd0; end
        else        begin box_s1 <= shp_box_v; box_s2 <= box_s1; end
    end
    wire [10:0] bxo0 = box_s2[43:33];
    wire [10:0] bxo1 = box_s2[32:22];
    wire [10:0] byo0 = box_s2[21:11];
    wire [10:0] byo1 = box_s2[10:0];

    // 验证用：把 bbox 人为平移 (+SHX,+SHY)，用来证明"加上修正量后框与图像重合"
    integer SHX = 0, SHY = 0;
    integer XADD = 0, YADD = 0;
    wire [11:0] vbxo0 = {1'b0,bxo0} + SHX;
    wire [11:0] vbxo1 = {1'b0,bxo1} + SHX;
    wire [11:0] vbyo0 = {1'b0,byo0} + SHY;
    wire [11:0] vbyo1 = {1'b0,byo1} + SHY;

    reg cls_s1, cls_s2;
    always @(posedge hclk or negedge rst_n) begin
        if (!rst_n) begin cls_s1 <= 1'b0; cls_s2 <= 1'b0; end
        else        begin cls_s1 <= (shp_cls != 3'd0); cls_s2 <= cls_s1; end
    end

    reg boxen_s1, boxen_s2;
    always @(posedge hclk or negedge rst_n) begin
        if (!rst_n) begin boxen_s1 <= 1'b0; boxen_s2 <= 1'b0; end
        else        begin boxen_s1 <= shp_box_en; boxen_s2 <= boxen_s1; end
    end

    // ---- 补偿量（顶层默认 22 / 3；本 TB 可逐 case 改）----
    reg [5:0] XOFF = 6'd22;
    reg [4:0] YOFF = 5'd3;
    reg [5:0] XOFF_s1, XOFF_s2;
    reg [4:0] YOFF_s1, YOFF_s2;
    always @(posedge hclk or negedge rst_n) begin
        if (!rst_n) begin XOFF_s1 <= 6'd22; XOFF_s2 <= 6'd22;
                        YOFF_s1 <= 5'd3;  YOFF_s2 <= 5'd3;  end
        else        begin XOFF_s1 <= XOFF; XOFF_s2 <= XOFF_s1;
                        YOFF_s1 <= YOFF; YOFF_s2 <= YOFF_s1; end
    end

    // ---- shape_osd（顶层 1701-1722）----
    wire [7:0] osd_px_out, box_px_out, grid_px_out;

    shape_osd #(
        .GRID_OSD (1'b0)
    ) u_shape_osd (
        .clk   (hclk), .rst_n (rst_n),
        .i_vs  (h_vs),
        .i_x   (comp_x),
        .i_y   (fr_y),
        .i_cls (cls_s2 ? 3'd2 : 3'd0),
        .i_bx0 (vbxo0[10:0]), .i_bx1 (vbxo1[10:0]),
        .i_by0 (vbyo0[10:0]), .i_by1 (vbyo1[10:0]),
        .i_box_en  (boxen_s2),
        .i_xoff    (XOFF_s2),
        .i_yoff    (YOFF_s2),
        .i_best_idx (4'd0),
        .i_best_cnt (14'd0),
        .o_px   (osd_px_out),
        .o_grid (grid_px_out),
        .o_box  (box_px_out)
    );

    //==========================================================================
    // 测量（hdmi 域，逐像素）
    //   dcol = comp_x - 1：comp_data 比 comp_x 晚 1 拍（同步读 1 拍），
    //   所以当前这拍送出的像素的屏幕列号 = comp_x-1。
    //==========================================================================
    reg     meas_en = 1'b0;
    integer m_img_x0, m_img_x1, m_img_y0, m_img_y1, m_img_n;
    integer m_box_x0, m_box_x1, m_box_y0, m_box_y1, m_box_n;
    integer m_edg_x0, m_edg_x1, m_edg_y0, m_edg_y1, m_edg_n;
    integer dcol, drow;

    task meas_clear;
        begin
            m_img_x0 = 99999; m_img_x1 = -1; m_img_y0 = 99999; m_img_y1 = -1;
            m_box_x0 = 99999; m_box_x1 = -1; m_box_y0 = 99999; m_box_y1 = -1;
            m_edg_x0 = 99999; m_edg_x1 = -1; m_edg_y0 = 99999; m_edg_y1 = -1;
            m_img_n = 0; m_box_n = 0; m_edg_n = 0;
        end
    endtask

    always @(posedge hclk) begin
        if (meas_en && comp_de_o) begin
            dcol = comp_x - 1;
            drow = fr_y;
            if (dcol < 0) dcol = 0;
            // 左半 = 灰度图像
            if (!comp_rd_edge_d) begin
                if (comp_data < 8'd128) begin
                    m_img_n = m_img_n + 1;
                    if (dcol < m_img_x0) m_img_x0 = dcol;
                    if (dcol > m_img_x1) m_img_x1 = dcol;
                    if (drow < m_img_y0) m_img_y0 = drow;
                    if (drow > m_img_y1) m_img_y1 = drow;
                end
            end else begin
                // 右半 = 红色边缘（comp_edge_q = 去孤立点后的边缘）
                if (comp_edge_q != 8'd0) begin
                    m_edg_n = m_edg_n + 1;
                    if (dcol < m_edg_x0) m_edg_x0 = dcol;
                    if (dcol > m_edg_x1) m_edg_x1 = dcol;
                    if (drow < m_edg_y0) m_edg_y0 = drow;
                    if (drow > m_edg_y1) m_edg_y1 = drow;
                end
            end
            // 检测框
            if (box_px_out != 8'd0) begin
                m_box_n = m_box_n + 1;
                if (dcol < m_box_x0) m_box_x0 = dcol;
                if (dcol > m_box_x1) m_box_x1 = dcol;
                if (drow < m_box_y0) m_box_y0 = drow;
                if (drow > m_box_y1) m_box_y1 = drow;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 条纹模式的探针：在选定行/列上打印显示端读到的像素值
    //--------------------------------------------------------------------------
    integer probe_row = 50;
    integer probe_col = 500;

    always @(posedge hclk) begin
        if (meas_en && comp_de_o && !comp_rd_edge_d) begin
            dcol = comp_x - 1;
            drow = fr_y;
            if (dcol < 0) dcol = 0;
            if (pat == 1 && drow == probe_row &&
                (dcol == 100 || dcol == 300 || dcol == 480 || dcol == 500 ||
                 dcol == 700 || dcol == 900)) begin
                $display("  [VSTRIPE] dcol=%0d fr_y=%0d  pixel=%0d  → cam_x ≡ %0d (mod 256), 名义 dcol+480=%0d",
                         dcol, drow, comp_data, comp_data, dcol + 480);
            end
            if (pat == 2 && dcol == probe_col &&
                drow >= 40 && drow <= 60) begin
                $display("  [HSTRIPE] dcol=%0d fr_y=%0d  pixel=%0d  → cam_y = %0d,  差 = cam_y-fr_y = %0d",
                         dcol, drow, comp_data, comp_data, comp_data - drow);
            end
        end
    end

    //--------------------------------------------------------------------------
    // 脉冲模式的粗延迟探针
    //--------------------------------------------------------------------------
    integer cyc = 0;
    always @(posedge vclk) cyc <= cyc + 1;

    integer t_in = -1, t_med = -1, t_cbg = -1, t_ce = -1, t_de = -1;
    always @(posedge vclk) begin
        if (i_de  && (i_g0 > 8'd100 || i_g1 > 8'd100) && t_in  < 0) t_in  = cyc;
        if (m_de  && (m_g0 > 8'd100 || m_g1 > 8'd100) && t_med < 0) t_med = cyc;
        if (c_de  && (c_bg[7:0] > 8'd40 || c_bg[15:8] > 8'd40) && t_cbg < 0) t_cbg = cyc;
        if (d_de  && (d_e != 2'd0) && t_de < 0) t_de = cyc;
        if (c_de  && (c_e != 2'd0) && t_ce < 0) t_ce = cyc;
    end

    //==========================================================================
    // 主流程
    //==========================================================================
    integer f;
    localparam integer TLINE = HP + HGAP;      // 一行 = 968 拍

    task run_frames(input integer n);
        begin
            for (f = 0; f < n; f = f + 1) send_frame;
        end
    endtask

    //--------------------------------------------------------------------------
    // 方块 case
    //--------------------------------------------------------------------------
    task run_square_case(input integer x0, input integer x1,
                         input integer y0, input integer y1,
                         input [5:0] xo, input [4:0] yo,
                         input [255:0] tag);
        integer bx0i, bx1i, by0i, by1i;
        integer reqx, reqy;
        begin
            sqx0 = x0; sqx1 = x1; sqy0 = y0; sqy1 = y1;
            XOFF = xo + XADD; YOFF = yo + YADD;
            run_frames(NFR - 1);
            meas_clear(); meas_en = 1'b1; run_frames(1); meas_en = 1'b0;
            bx0i = shp_bx0; bx1i = shp_bx1; by0i = shp_by0; by1i = shp_by1;

            $display("");
            $display("-----------------------------------------------------------------------");
            $display(" [%0s]  相机方块 x=%0d..%0d  y=%0d..%0d   XOFF=%0d YOFF=%0d",
                     tag, x0, x1, y0, y1, xo, yo);
            $display("   形状通路 bbox  : bx0=%0d bx1=%0d by0=%0d by1=%0d  (真值 %0d,%0d,%0d,%0d)  Δ=(%0d,%0d)",
                     bx0i, bx1i, by0i, by1i, x0, x1, y0, y1, bx0i - x0, by0i - y0);
            $display("   各级内容 bbox（同一帧、以各自 de 为坐标）:");
            $display("     输入   i_g      x=%0d..%0d y=%0d..%0d  Δ=(%0d,%0d)",
                     pb_in_x0, pb_in_x1, pb_in_y0, pb_in_y1, pb_in_x0 - x0, pb_in_y0 - y0);
            $display("     中值   m_g      x=%0d..%0d y=%0d..%0d  Δ=(%0d,%0d)",
                     pb_md_x0, pb_md_x1, pb_md_y0, pb_md_y1, pb_md_x0 - x0, pb_md_y0 - y0);
            $display("     canny  o_bg    x=%0d..%0d y=%0d..%0d  Δ=(%0d,%0d)",
                     pb_bg_x0, pb_bg_x1, pb_bg_y0, pb_bg_y1, pb_bg_x0 - x0, pb_bg_y0 - y0);
            $display("     canny  o_e     x=%0d..%0d y=%0d..%0d  Δ=(%0d,%0d)  (边缘轮廓，非实心)",
                     pb_e_x0, pb_e_x1, pb_e_y0, pb_e_y1, pb_e_x0 - x0, pb_e_y0 - y0);
            $display("     despk  o_e     x=%0d..%0d y=%0d..%0d  Δ=(%0d,%0d)",
                     pb_d_x0, pb_d_x1, pb_d_y0, pb_d_y1, pb_d_x0 - x0, pb_d_y0 - y0);
            $display("   显示图像暗区   : x=%0d..%0d  y=%0d..%0d   (暗像素 %0d 个)",
                     m_img_x0, m_img_x1, m_img_y0, m_img_y1, m_img_n);
            $display("   OSD 框         : x=%0d..%0d  y=%0d..%0d   (像素 %0d 个)",
                     m_box_x0, m_box_x1, m_box_y0, m_box_y1, m_box_n);
            $display("   右半红色边缘   : x=%0d..%0d  y=%0d..%0d   (像素 %0d 个)",
                     m_edg_x0, m_edg_x1, m_edg_y0, m_edg_y1, m_edg_n);
            $display("   → 红边相对图像的偏移 (右半 x-960) = %0d px,  行 = %0d",
                     m_edg_x0 - 960 - (m_img_x0 + 2), m_edg_y0 - m_img_y0);
            $display("   → 图像相对 480 裁剪的偏移 C_x = img_x0+480-真值x0 = %0d px", m_img_x0 + 480 - x0);
            $display("   → 图像相对行计数的偏移 C_y = img_y0 - 真值y0       = %0d 行", m_img_y0 - y0);
            reqx = bx0i - 480 - 1 - m_img_x0;
            reqy = by0i - m_img_y0;
            $display("   → 需要的 XOFF = bx0-480-1-img_x0 = %0d", reqx);
            $display("   → 需要的 YOFF = by0-img_y0       = %0d", reqy);
        end
    endtask

    initial begin
        if ($value$plusargs("pat=%d", pat)) begin end
        if ($value$plusargs("shx=%d", SHX)) begin end
        if ($value$plusargs("shy=%d", SHY)) begin end
        if ($value$plusargs("xof=%d", XADD)) begin end
        if ($value$plusargs("yof=%d", YADD)) begin end
        meas_clear();
        rst_n = 1'b0;
        repeat (20) @(posedge vclk);
        #1 rst_n = 1'b1;
        repeat (20) @(posedge vclk); #1;

        $display("");
        $display("=======================================================================");
        $display(" tb_offset_sys  pat=%0d  (%0d pairs x %0d lines, hclk=2*vclk)", pat, HP, VL);
        $display("=======================================================================");

        if (pat == 0) begin
            // 3 个不同位置：验证偏移是常数还是随位置变化
            run_square_case(700,  800,  40,  80, 6'd0, 5'd0, "case1");
            run_square_case(900,  1040, 20,  60, 6'd0, 5'd0, "case2");
            run_square_case(1100, 1200, 60, 100, 6'd0, 5'd0, "case3");
            // 加了修正量之后的复核（框应与图像暗区完全重合）
            if (SHX != 0 || SHY != 0)
                run_square_case(700, 800, 40, 80, 6'd0, 5'd0, "verify+shx/shy");
        end
        else if (pat == 1) begin
            XOFF = 6'd0; YOFF = 5'd0;
            run_frames(1);
            meas_clear(); meas_en = 1'b1; run_frames(1); meas_en = 1'b0;
        end
        else if (pat == 2) begin
            XOFF = 6'd0; YOFF = 5'd0;
            run_frames(1);
            meas_clear(); meas_en = 1'b1; run_frames(1); meas_en = 1'b0;
        end
        else if (pat == 4) begin
            // 帧锁存时机：第 1 帧方块在 case1 位置，第 2 帧换到 case2 位置。
            // 若 box 仍画在 case1 位置（而图像已在 case2 位置）→ bbox 是"上一帧"的。
            XOFF = 6'd0; YOFF = 5'd0;
            sqx0 = 700; sqx1 = 800; sqy0 = 40; sqy1 = 80;
            send_frame;                                   // frame 1
            sqx0 = 900; sqx1 = 1040; sqy0 = 20; sqy1 = 60;
            meas_clear(); meas_en = 1'b1; send_frame; meas_en = 1'b0;   // frame 2
            $display("");
            $display("------------ 帧锁存时机（pat=4）------------");
            $display("  frame1 方块 cam x=700..800 y=40..80");
            $display("  frame2 方块 cam x=900..1040 y=20..60");
            $display("  frame2 实测: 图像暗区 x=%0d..%0d y=%0d..%0d", m_img_x0, m_img_x1, m_img_y0, m_img_y1);
            $display("  frame2 实测: OSD 框   x=%0d..%0d y=%0d..%0d", m_box_x0, m_box_x1, m_box_y0, m_box_y1);
            $display("  → 若框仍在 219..319 / 44..80，说明 bbox 用的是上一帧（滞后 1 帧）");
        end
        else if (pat == 5) begin
            // 量化残差：坐标不是 4 的倍数时，bbox 量化（x0 上取整 / x1 下取整）的影响
            run_square_case(702, 801, 42, 82, 6'd0, 5'd0, "quant+2,+2");
            run_square_case(703, 803, 43, 83, 6'd0, 5'd0, "quant+3,+3");
        end
        else begin
            XOFF = 6'd0; YOFF = 5'd0;
            run_frames(NFR);
            $display("");
            $display("------------ 三通路延迟粗测（脉冲块 @cam(%0d,%0d)，单位 vclk 拍）------------",
                     pls_x, pls_y);
            $display("  输入脉冲      t_in = %0d", t_in);
            $display("  中值输出      t    = %0d   Δ=%0d 拍", t_med, t_med - t_in);
            $display("  canny o_bg    t    = %0d   Δ=%0d 拍", t_cbg, t_cbg - t_in);
            $display("  canny o_e     t    = %0d   Δ=%0d 拍", t_ce,  t_ce  - t_in);
            $display("  despeckle o_e t    = %0d   Δ=%0d 拍", t_de,  t_de  - t_in);
            $display("  参考：一行 = %0d 拍，列 = 2*(Δ mod %0d)", TLINE, TLINE);
        end

        $display("");
        $display("  最终 bbox: bx0=%0d bx1=%0d by0=%0d by1=%0d box_en=%0d cls=%0d",
                 shp_bx0, shp_bx1, shp_by0, shp_by1, shp_box_en, shp_cls);
        $display("=======================================================================");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 超时保护
    //--------------------------------------------------------------------------
    initial begin
        #200_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule


//==============================================================================
// stage_probe —— 在某一级的 de 坐标系里统计"命中（暗/边缘）"像素的 bbox
//   x = 行内像素对号（0..HP-1）→ 像素列 = 2x / 2x+1
//   y = 行号（de 下降沿 +1，i_vs 清零）
//==============================================================================
module stage_probe #(
    parameter integer HP = 960
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire        d0,
    input  wire        d1,
    output reg  [11:0] minx, maxx, miny, maxy,
    output reg  [31:0] cnt
);
    reg [11:0] x, y;
    reg        de_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 12'd0; y <= 12'd0; de_q <= 1'b0;
        end else begin
            de_q <= i_de;
            if (i_vs) begin
                x <= 12'd0; y <= 12'd0;
            end else begin
                if (i_de) begin
                    if (x == HP - 1) x <= 12'd0;
                    else             x <= x + 12'd1;
                end else           x <= 12'd0;
                if (de_q && !i_de) y <= y + 12'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            minx <= 12'hFFF; maxx <= 12'd0; miny <= 12'hFFF; maxy <= 12'd0; cnt <= 32'd0;
        end else if (i_vs) begin
            minx <= 12'hFFF; maxx <= 12'd0; miny <= 12'hFFF; maxy <= 12'd0; cnt <= 32'd0;
        end else if (i_de && (d0 || d1)) begin
            cnt <= cnt + 32'd1;
            if (d0) begin
                if ((x << 1) < minx) minx <= (x << 1);
                if ((x << 1) > maxx) maxx <= (x << 1);
            end
            if (d1) begin
                if ((x << 1) + 12'd1 < minx) minx <= (x << 1) + 12'd1;
                if ((x << 1) + 12'd1 > maxx) maxx <= (x << 1) + 12'd1;
            end
            if (y < miny) miny <= y;
            if (y > maxy) maxy <= y;
        end
    end
endmodule
