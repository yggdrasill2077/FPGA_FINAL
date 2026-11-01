`timescale 1ns/1ps
//==============================================================================
// tb_aa.v —— 亚像素抗锯齿（AA）等级验证台
//
//   目的：验证 edge_canny_2px 新增的 o_aa 输出（每像素 2bit 等级）能否把
//         「1 px 硬边缘」展成「2 px 强度过渡」，并让强度加权质心更接近真值。
//
//   被测：两个完全相同的实例，只有 AA 打开/关闭不同
//     u_bin : SUBPIX_ON=0, AA_ON=0   → o_aa 只剩 0 / 2（等价原二值输出）
//     u_aa  : SUBPIX_ON=1, AA_ON=1   → o_aa 有 0 / 1 / 2
//   两者的检测通路（Gauss/Sobel/NMS/双阈值滞后）逐位相同，SUBPIX_ON 只影响
//   OSD 与半强度项，因此差异完全来自 AA 等级。
//
//   测试图：三条斜边 15° / 30° / 45°，逐行阶梯（每行一次阶跃），
//     真值 = 理想直线 x_true(y) = x0 + y*tan(theta)
//     灰度 = 该像素被「亮区 x >= x_true」覆盖的面积 * 255
//            （即理想光学边缘的抗锯齿成像；行方向逐行阶梯推进）
//     可选 +HARD=1 换成纯二值阶梯（0/255），作为对照（此时硬阶跃的梯度
//     平台两像素等值，AA 按定义不会新增半强度点，属预期现象）。
//
//   度量：每行「强度加权质心」 vs 真值位置
//     centroid(row) = sum(x*w) / sum(w),  w = o_aa 等级（0/1/2），x = 像素列号
//     因为 edge 模块的 o_de 比数据通路早 3 拍（既有实现，约 6 px 固定横向
//     相位差），且 30/45度 的 NMS 粗方向码会带来每角度不同的系统偏移，
//     所以输出三个量：
//       bias    = mean(centroid - x_true)          ← 固定相位差，AA 前后不变
//       RMS_raw = sqrt(mean((centroid-x_true)^2))  ← 含上述固定偏差
//       RMS_c   = sqrt(mean((centroid-x_true)^2) - bias^2)  ← 扣掉本角度均值
//       RMS_within（汇总）= 扣掉「每个角度各自均值」后的残差   ← 主指标
//     另统计 aa_fired：AA 是否真的点亮了半强度像素的行数（w_aa > w_bin）。
//
//   行首 10 px / 行尾 20 px 不参与统计：2 px/clk 的 win3x3 在行首行尾会混入
//   相邻行数据（i_x/i_de 相位差，既有实现），会在行边界造出假边缘。
//
//   用法：
//     iverilog -g2012 -o sim/tb_aa.vvp sim/tb_aa.v rtl/edge/edge_canny_2px.v \
//              rtl/edge/win3x3_2px.v rtl/edge/sobel_3x3.v rtl/simple_dual_port_ram.v
//     vvp sim/tb_aa.vvp                 # 面积覆盖率灰度（默认）
//     vvp sim/tb_aa.vvp +HARD=1         # 纯二值阶梯对照
//     vvp sim/tb_aa.vvp +TH=56          # 阈值档（硬件默认 56，与 TH=12 结果一致）
//     vvp sim/tb_aa.vvp +DBG=1          # 打印内部信号（第 20 行的等级/列号）
//   编译期可改：-Ptb_aa.MAGTH=2 / -Ptb_aa.NFR=2 / -Ptb_aa.CAL=1（垂直边标定）
//   逐行明细：sim/aa_rows.csv（angle_deg,row,x_true,centroid_bin,centroid_aa,
//                              w_bin,w_aa）
//==============================================================================
module tb_aa;

    // ------------------------------------------------------------------
    // 配置
    // ------------------------------------------------------------------
    parameter integer HP    = 48;     // 每行像素对数（96 px 宽）
    parameter integer ADW   = 6;      // 2^6 = 64 >= HP
    parameter integer VP    = 120;    // 每帧行数
    parameter integer NFR   = 3;      // 每角度帧数（最后一帧计数，前面热身）
    parameter integer MAGTH = 2;      // AA 半强度门限（dq >= MAGTH，Q4.4；2 → |delta| >= 1/8）
    parameter integer TH    = 12;     // 默认阈值档
    parameter integer CAL   = 0;      // 1 = 标定模式：三条垂直边（θ=0）

    localparam integer W = 2*HP;      // 64 像素

    // ------------------------------------------------------------------
    // 时钟 / 复位 / 激励
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg i_de = 1'b0, i_hs = 1'b0, i_vs = 1'b0;
    reg [7:0]  i_g0 = 8'd0, i_g1 = 8'd0;
    reg [47:0] i_rgb = 48'd0;
    reg [11:0] i_th  = TH;

    // ---- 二值参考实例 ----
    wire        b_de, b_hs, b_vs;
    wire [1:0]  b_e;
    wire [3:0]  b_aa;
    wire [15:0] b_osd, b_bg;
    wire [47:0] b_rgb;

    edge_canny_2px #(
        .H_PAIRS (HP), .ADDR_W (ADW),
        .GAUSS_ON (1), .CANNY_HYST_ON (1), .LOCAL_T_ON (1),
        .SUBPIX_ON (0), .AA_ON (0)
    ) u_bin (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_hs (i_hs), .i_vs (i_vs),
        .i_g0 (i_g0), .i_g1 (i_g1), .i_rgb (i_rgb), .i_threshold (i_th),
        .o_de (b_de), .o_hs (b_hs), .o_vs (b_vs),
        .o_e (b_e), .o_aa (b_aa), .o_osd (b_osd), .o_bg (b_bg), .o_rgb (b_rgb)
    );

    // ---- AA 实例 ----
    wire        a_de, a_hs, a_vs;
    wire [1:0]  a_e;
    wire [3:0]  a_aa;
    wire [15:0] a_osd, a_bg;
    wire [47:0] a_rgb;

    edge_canny_2px #(
        .H_PAIRS (HP), .ADDR_W (ADW),
        .GAUSS_ON (1), .CANNY_HYST_ON (1), .LOCAL_T_ON (1),
        .SUBPIX_ON (1), .AA_ON (1), .AA_MAG_TH (MAGTH)
    ) u_aa (
        .clk (clk), .rst_n (rst_n),
        .i_de (i_de), .i_hs (i_hs), .i_vs (i_vs),
        .i_g0 (i_g0), .i_g1 (i_g1), .i_rgb (i_rgb), .i_threshold (i_th),
        .o_de (a_de), .o_hs (a_hs), .o_vs (a_vs),
        .o_e (a_e), .o_aa (a_aa), .o_osd (a_osd), .o_bg (a_bg), .o_rgb (a_rgb)
    );

    // ------------------------------------------------------------------
    // 测试图：逐行阶梯斜边
    // ------------------------------------------------------------------
    real    slope  = 0.0;       // tan(theta)
    real    x0r    = 20.0;      // 第 0 行真值位置
    integer hard_mode = 0;      // 0 = 面积覆盖率灰度（默认）1 = 二值阶梯
    integer ang    = 0;         // 当前角度序号

    real    r_slope [0:2];
    real    r_x0    [0:2];
    integer r_ymin  [0:2];
    integer r_ymax  [0:2];
    integer ang_deg [0:2];

    function integer pix;       // 该像素灰度（亮区 = x >= x_true）
        input integer x, y;
        real p, cov;
        begin
            p   = x0r + y * slope;
            cov = (x + 0.5) - p;
            if (cov < 0.0) cov = 0.0;
            if (cov > 1.0) cov = 1.0;
            if (hard_mode != 0) pix = (cov > 0.5) ? 255 : 0;
            else                pix = $rtoi(cov * 255.0 + 0.5);
        end
    endfunction

    // ------------------------------------------------------------------
    // 采集：o_aa 比 e0f/e1f 晚 1 拍（模块内奇像素要等下一拍的 pix0），
    //       列号用 u_aa.m_x（|G| 窗口的 o_x，与 e0f/e1f 同相）打一拍得到，
    //       这样不依赖 TB 自己的计数器，也没有跨 always 的竞争。
    // ------------------------------------------------------------------
    reg        aa_vld = 1'b0;
    reg        line_act = 1'b0;
    reg [9:0]  mx_d;
    reg [11:0] row_d;
    reg [3:0]  aa_d, bb_d;
    integer    col;             // 当前像素对的两个列号 2*mx_d, 2*mx_d+1
    integer    rows_out;        // 本帧已完成的输出行数
    integer    cur_row;
    integer    sw_b, sxw_b, sw_a, sxw_a;
    real       p_acc;

    // 统计
    real    e2b [0:2];
    real    e2a [0:2];
    real    sb  [0:2];
    real    sa  [0:2];
    integer nb  [0:2];
    integer na  [0:2];
    integer nfire [0:2];       // AA 实际点亮半强度像素的行数
    integer meas_on = 0;

    integer fd;
    integer i, f, y, x, a;
    integer dbg = 0;

    // 行结算
    task settle_row;
        input integer row;
        input integer swb, sxwb, swa, sxwa;
        real cb, ca, p, eb, ea;
        begin
            if ((row >= r_ymin[ang]) && (row <= r_ymax[ang])) begin
                p = r_x0[ang] + row * r_slope[ang];
                cb = 0.0; ca = 0.0;
                if (swb > 0) begin
                    cb = sxwb * 1.0 / swb;
                    eb = cb - p;
                    e2b[ang] = e2b[ang] + eb*eb;
                    sb[ang]  = sb[ang]  + eb;
                    nb[ang]  = nb[ang] + 1;
                end
                if (swa > 0) begin
                    ca = sxwa * 1.0 / swa;
                    ea = ca - p;
                    e2a[ang] = e2a[ang] + ea*ea;
                    sa[ang]  = sa[ang]  + ea;
                    na[ang]  = na[ang] + 1;
                end
                if ((fd != 0) && (meas_on != 0))
                    $fwrite(fd, "%0d,%0d,%0.4f,%0.4f,%0.4f,%0d,%0d\n",
                            ang_deg[ang], row, p, cb, ca, swb, swa);
                if (swb > 0 && swa > swb) nfire[ang] = nfire[ang] + 1;
            end
        end
    endtask

    // 第一级：只做打拍（全部用非阻塞），供第二级无竞争读取
    always @(posedge clk) begin
        aa_vld <= a_de;
        mx_d   <= u_aa.m_x;
        row_d  <= u_aa.row_d6;
        aa_d   <= a_aa;
        bb_d   <= b_aa;
    end

    // 第二级：行内累加 / 行末结算（只读已寄存的 mx_d/row_d/aa_d/bb_d）
    always @(posedge clk) begin
        if (!aa_vld) begin
            if (line_act) begin
                settle_row(cur_row, sw_b, sxw_b, sw_a, sxw_a);
                line_act = 1'b0;
                rows_out = rows_out + 1;
            end
            sw_b = 0; sxw_b = 0;
            sw_a = 0; sxw_a = 0;
        end else begin
            if (!line_act) begin
                line_act = 1'b1;
                cur_row  = row_d;
                sw_b = 0; sxw_b = 0;
                sw_a = 0; sxw_a = 0;
            end
            // 偶像素 = aa_d[1:0]，奇像素 = aa_d[3:2]
            // 累加整行，只掐掉行首 10 px 与行尾 20 px：行首/行尾各 2~3 对列的窗口
            // 里混有相邻行的数据（win3x3 的 i_x/i_de 相位差），会在行边界造出
            // 假边缘，属既有现象，与本改动无关
            col   = 2 * mx_d;
            if ((col >= 10) && (col <= (W - 20))) begin
                sw_a  = sw_a  + aa_d[1:0] + aa_d[3:2];
                sxw_a = sxw_a + col * aa_d[1:0] + (col+1) * aa_d[3:2];
                sw_b  = sw_b  + bb_d[1:0] + bb_d[3:2];
                sxw_b = sxw_b + col * bb_d[1:0] + (col+1) * bb_d[3:2];
            end
            if ((dbg != 0) && ((aa_d | bb_d) != 4'd0) && (cur_row == 20))
                $display("  [row20] row=%0d col=%0d aa=%b bb=%b", cur_row, col, aa_d, bb_d);
        end
    end

    // ------------------------------------------------------------------
    // 临时调试：打印 AA 实例内部关键信号（+DBG=1）
    // ------------------------------------------------------------------
    integer dbg2 = 0;
    initial begin
        if (!$value$plusargs("DBG=%d", dbg))  dbg = 0;
    end

    always @(posedge clk) begin
        if ((dbg != 0) && (meas_on != 0) && ((u_aa.G0n != 12'd0) || (u_aa.G1n != 12'd0)))
            $display("  [int] mx=%0d G0n=%h e0f=%b dq0=%h dir0=%0d | G1n=%h e1f=%b dq1=%h dir1=%0d",
                     u_aa.m_x, u_aa.G0n, u_aa.e0f, u_aa.dq0, u_aa.d0n_2,
                     u_aa.G1n, u_aa.e1f, u_aa.dq1, u_aa.d1n_2);
    end

    // ------------------------------------------------------------------
    // 报告
    //   说明：centroid 与真值之间存在一个「与 AA 无关」的固定偏差
    //   （edge 模块的 o_de 比数据通路早 3 拍，实测约 +6 px 横向相位差；
    //     另外 30°/45° 的 NMS 粗方向码会带来每角度不同的系统偏移）。
    //   两路（bin/aa）偏差相同，所以真正衡量亚像素精度的是去掉均值后的
    //   RMS（RMS_c，= 标准差）。下面同时列出 bias / RMS_raw / RMS_c。
    // ------------------------------------------------------------------
    task report;
        input integer ai;
        real rb, ra, b, a2, varb, vara;
        begin
            b    = (nb[ai] > 0) ? (sb[ai] / nb[ai]) : 0.0;
            a2   = (na[ai] > 0) ? (sa[ai] / na[ai]) : 0.0;
            rb   = (nb[ai] > 0) ? $sqrt(e2b[ai] / nb[ai]) : 0.0;
            ra   = (na[ai] > 0) ? $sqrt(e2a[ai] / na[ai]) : 0.0;
            varb = rb*rb - b*b;  if (varb < 0.0) varb = 0.0;
            vara = ra*ra - a2*a2; if (vara < 0.0) vara = 0.0;
            $display("[AA] %2d deg rows bin/aa=%0d/%0d  bias bin/aa=%+0.3f/%+0.3f px  RMS_raw bin/aa=%0.3f/%0.3f  RMS_c bin/aa=%0.3f/%0.3f  improve_c=%0.1f%%  aa_fired=%0d rows",
                     ang_deg[ai], nb[ai], na[ai], b, a2, rb, ra,
                     $sqrt(varb), $sqrt(vara),
                     (varb > 0.0) ? (($sqrt(varb) - $sqrt(vara)) / $sqrt(varb) * 100.0) : 0.0,
                     nfire[ai]);
        end
    endtask

    // ------------------------------------------------------------------
    // 主激励
    // ------------------------------------------------------------------
    real sum_e2b, sum_e2a;
    real sum_sb, sum_sa;
    real sum_wb, sum_wa;
    integer sum_nb, sum_na;

    initial begin
        r_slope[0] = 0.2679491924;   // tan15
        r_slope[1] = 0.5773502692;   // tan30
        r_slope[2] = 1.0000000000;   // tan45
        ang_deg[0] = 15; ang_deg[1] = 30; ang_deg[2] = 45;
        // 起始位置/有效行区间：保证真值落在 x in [10,56]（模块屏蔽行首尾 2 对）
        r_x0[0] = 16.3;  r_ymin[0] = 10; r_ymax[0] = 110;   // 16.3 -> 45.8
        r_x0[1] = 12.3;  r_ymin[1] = 10; r_ymax[1] =  76;   // 12.3 -> 56.2
        r_x0[2] = 10.3;  r_ymin[2] = 10; r_ymax[2] =  46;   // 10.3 -> 56.3

        // +CAL=1：三条垂直边（θ=0，真值恒定），用来标定「输出列号 ↔ 真值」的相位
        if (CAL != 0) begin
            r_slope[0] = 0.0; r_x0[0] = 30.5; r_ymin[0] = 10; r_ymax[0] = 110;
            r_slope[1] = 0.0; r_x0[1] = 40.5; r_ymin[1] = 10; r_ymax[1] = 110;
            r_slope[2] = 0.0; r_x0[2] = 50.5; r_ymin[2] = 10; r_ymax[2] = 110;
        end

        for (a = 0; a < 3; a = a + 1) begin
            e2b[a] = 0.0; e2a[a] = 0.0; sb[a] = 0.0; sa[a] = 0.0; nb[a] = 0; na[a] = 0;
            nfire[a] = 0;
        end

        if (!$value$plusargs("TH=%d", i_th))  i_th = TH;
        if (!$value$plusargs("HARD=%d", hard_mode)) hard_mode = 0;

        fd = $fopen("sim/aa_rows.csv", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open sim/aa_rows.csv");
            $finish;
        end
        $fwrite(fd, "angle_deg,row,x_true,centroid_bin,centroid_aa,w_bin,w_aa\n");

        $display("[AA] cfg: HP=%0d (W=%0dpx) VP=%0d NFR=%0d AA_MAG_TH=%0d TH=%0d pattern=%s",
                 HP, W, VP, NFR, MAGTH, i_th, (hard_mode != 0) ? "HARD-STEP" : "AREA-COVERAGE");

        #100 rst_n = 1'b1;
        #200;
        // vmem 是垂直 IIR 的存储体，清零（层次化引用，与 tb_edge_canny 一致）
        for (i = 0; i < 1024; i = i + 1) begin
            u_bin.vmem[i] = 8'd0;
            u_aa.vmem[i]  = 8'd0;
        end

        for (ang = 0; ang < 3; ang = ang + 1) begin
            slope  = r_slope[ang];
            x0r    = r_x0[ang];
            for (f = 0; f < NFR; f = f + 1) begin
                meas_on = (f == NFR-1) ? 1 : 0;
                for (y = 0; y < VP; y = y + 1) begin
                    if (y == 0) begin
                        i_vs <= 1'b1;
                        repeat (10) @(posedge clk);
                        i_vs <= 1'b0;
                    end
                    i_hs <= 1'b1; @(posedge clk); @(posedge clk); i_hs <= 1'b0;
                    repeat (20) @(posedge clk);
                    for (x = 0; x < HP; x = x + 1) begin
                        @(negedge clk);
                        i_de <= 1'b1;
                        i_g0 <= pix(2*x,     y);
                        i_g1 <= pix(2*x + 1, y);
                        if ((dbg != 0) && (meas_on != 0) && (ang == 0) && (y == 20) &&
                            (x >= 12) && (x <= 20))
                            $display("  [in] y=%0d pair=%0d col=%0d/%0d g0=%0d g1=%0d",
                                     y, x, 2*x, 2*x+1, pix(2*x, y), pix(2*x+1, y));
                    end
                    @(negedge clk);
                    i_de <= 1'b0;
                    repeat (40) @(posedge clk);
                end
            end
            report(ang);
        end

        $fclose(fd);
        fd = 0;

        // 汇总：先把每个角度各自的均值偏差扣掉（不同角度的系统偏差来自 NMS
        // 粗方向码 + o_de/数据通路的拍数差，与 AA 无关），得到「角度内」的
        // 亚像素残差 RMS_within —— 这是衡量 AA 精度的主指标。
        sum_e2b = 0.0; sum_e2a = 0.0; sum_nb = 0; sum_na = 0;
        sum_sb = 0.0; sum_sa = 0.0;
        for (a = 0; a < 3; a = a + 1) begin
            sum_e2b = sum_e2b + e2b[a];
            sum_e2a = sum_e2a + e2a[a];
            sum_sb  = sum_sb  + sb[a];
            sum_sa  = sum_sa  + sa[a];
            sum_nb  = sum_nb + nb[a];
            sum_na  = sum_na + na[a];
        end
        $display("[AA] ALL  rows bin/aa=%0d/%0d  bias bin/aa=%+0.3f/%+0.3f px  RMS_raw bin/aa=%0.3f/%0.3f  RMS_c bin/aa=%0.3f/%0.3f  improve_c=%0.1f%%",
                 sum_nb, sum_na,
                 (sum_nb > 0) ? (sum_sb/sum_nb) : 0.0,
                 (sum_na > 0) ? (sum_sa/sum_na) : 0.0,
                 (sum_nb > 0) ? $sqrt(sum_e2b/sum_nb) : 0.0,
                 (sum_na > 0) ? $sqrt(sum_e2a/sum_na) : 0.0,
                 (sum_nb > 0) ? $sqrt(sum_e2b/sum_nb - (sum_sb/sum_nb)*(sum_sb/sum_nb)) : 0.0,
                 (sum_na > 0) ? $sqrt(sum_e2a/sum_na - (sum_sa/sum_na)*(sum_sa/sum_na)) : 0.0,
                 (sum_nb > 0) ? ((($sqrt(sum_e2b/sum_nb - (sum_sb/sum_nb)*(sum_sb/sum_nb))) -
                                  ($sqrt(sum_e2a/sum_na - (sum_sa/sum_na)*(sum_sa/sum_na)))) /
                                 $sqrt(sum_e2b/sum_nb - (sum_sb/sum_nb)*(sum_sb/sum_nb)) * 100.0) : 0.0);

        // 角度内残差（扣掉每个角度自己的均值偏差）
        sum_wb = 0.0; sum_wa = 0.0;
        for (a = 0; a < 3; a = a + 1) begin
            if (nb[a] > 0) sum_wb = sum_wb + (e2b[a] - sb[a]*sb[a]/nb[a]);
            if (na[a] > 0) sum_wa = sum_wa + (e2a[a] - sa[a]*sa[a]/na[a]);
        end
        sum_wb = (sum_nb > 0) ? $sqrt(sum_wb/sum_nb) : 0.0;
        sum_wa = (sum_na > 0) ? $sqrt(sum_wa/sum_na) : 0.0;
        $display("[AA] WITHIN-ANGLE  RMS bin/aa = %0.3f/%0.3f px   improve = %0.1f%%   (亚像素精度主指标)",
                 sum_wb, sum_wa, (sum_wb > 0.0) ? ((sum_wb - sum_wa)/sum_wb*100.0) : 0.0);
        $display("==== tb_aa done ====");
        $finish;
    end

endmodule
