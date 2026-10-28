//==============================================================================
// median3x3_2px.v  —— 3x3 中值滤波（2 像素/时钟）
//   赛题高阶第 1 项：灰度化之后、Sobel 之前，抑制椒盐噪声
//
//   结构说明（1 拍流水）：
//     * 输入每时钟到来一个像素对 (g0,g1)，行内列号 pcol = 0..959
//     * 3 个行缓存 bank（每 bank 1024 x 16bit，一项 = 一个像素对）按行轮换
//       写：当前行；读：y-1 / y-2 两个 bank
//     * 读地址取 pcol+1，配合同步读的 1 拍延迟，在 t+1 时刻同时拿到
//       上一行/上上行的 (pcol-1, pcol, pcol+1) 三个像素对 → 3x3 窗口齐备
//     * 当前行三个像素来自输入寄存器：上一对 g1 / 本对 g0 / 本对 g1 / 下一对 g0
//     * 边界 clamp：行首左邻用自身、行尾右邻用自身；帧内前两行用当前行复制
//     * de/hs/vs/valid 延迟 1 拍与数据对齐
//==============================================================================
module median3x3_2px (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_hs,
    input  wire        i_vs,
    input  wire        i_valid,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_g1,
    output reg         o_de,
    output reg         o_hs,
    output reg         o_vs,
    output reg         o_valid,
    output reg  [7:0]  o_g0,
    output reg  [7:0]  o_g1
);
    // ------------------------------------------------------------------
    // 行内列号 / bank 轮换 / 帧内行号
    // ------------------------------------------------------------------
    reg  [9:0] pcol;
    reg  [1:0] bank;
    reg        de_p;
    reg  [9:0] line_cnt;

    wire line_end = de_p & ~i_de;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol     <= 10'd0;
            bank     <= 2'd0;
            de_p     <= 1'b0;
            line_cnt <= 10'd0;
        end else begin
            de_p <= i_de;
            if (!i_de)
                pcol <= 10'd0;
            else if (pcol == 10'd959)
                pcol <= 10'd0;
            else
                pcol <= pcol + 10'd1;

            if (line_end) begin
                bank     <= (bank == 2'd2) ? 2'd0 : (bank + 2'd1);
                line_cnt <= line_cnt + 10'd1;
            end
            if (i_vs)
                line_cnt <= 10'd0;
        end
    end

    // y-1 / y-2 对应的 bank（与写 bank 相互不同）
    wire [1:0] bank_m1 = (bank == 2'd0) ? 2'd2 : (bank - 2'd1);            // +2 mod 3
    wire [1:0] bank_m2 = (bank_m1 == 2'd0) ? 2'd2 : (bank_m1 - 2'd1);      // +1 mod 3

    // ------------------------------------------------------------------
    // 行缓存（同步读，便于推断 BRAM）
    // ------------------------------------------------------------------
    reg [15:0] lb0 [0:1023];
    reg [15:0] lb1 [0:1023];
    reg [15:0] lb2 [0:1023];

    reg [9:0]  raddr;          // = pcol + 1，打一拍后用
    reg [15:0] rd0, rd1, rd2;  // 三个 bank 的同步读结果

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raddr <= 10'd0;
            rd0 <= 16'd0; rd1 <= 16'd0; rd2 <= 16'd0;
        end else begin
            raddr <= (pcol >= 10'd958) ? 10'd959 : (pcol + 10'd2);
            rd0 <= lb0[raddr];
            rd1 <= lb1[raddr];
            rd2 <= lb2[raddr];
        end
    end

    always @(posedge clk) begin
        if (i_de) begin
            if (bank == 2'd0)      lb0[pcol] <= {i_g1, i_g0};
            else if (bank == 2'd1) lb1[pcol] <= {i_g1, i_g0};
            else                   lb2[pcol] <= {i_g1, i_g0};
        end
    end

    // 选出 y-1 / y-2 的读结果
    wire [15:0] rm1_now = (bank_m1 == 2'd0) ? rd0 : (bank_m1 == 2'd1) ? rd1 : rd2;
    wire [15:0] rm2_now = (bank_m2 == 2'd0) ? rd0 : (bank_m2 == 2'd1) ? rd1 : rd2;

    // ------------------------------------------------------------------
    // 1 拍流水：行缓存读结果的三个列位置 + 当前行像素
    // ------------------------------------------------------------------
    reg [15:0] m1_c1, m1_c0, m1_c2;    // y-1 : pcol-1, pcol, pcol+1
    reg [15:0] m2_c1, m2_c0, m2_c2;    // y-2 : 同上
    reg [7:0]  cur_g0_q, cur_g1_q;     // 本对（打一拍）
    reg [7:0]  prv_g1_q;               // 上一对 g1（x0 左邻）
    reg [7:0]  nxt_g0;                 // 下一对 g0（x1 右邻）—— 直接取当前输入
    reg [9:0]  pcol_q;
    reg [9:0]  line_q;
    reg        de_q, hs_q, vs_q, va_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m1_c1 <= 16'd0; m1_c0 <= 16'd0; m1_c2 <= 16'd0;
            m2_c1 <= 16'd0; m2_c0 <= 16'd0; m2_c2 <= 16'd0;
            cur_g0_q <= 8'd0; cur_g1_q <= 8'd0; prv_g1_q <= 8'd0;
            pcol_q <= 10'd0; line_q <= 10'd0;
            de_q <= 1'b0; hs_q <= 1'b0; vs_q <= 1'b0; va_q <= 1'b0;
        end else begin
            m1_c2 <= rm1_now;  m1_c1 <= m1_c2;  m1_c0 <= m1_c1;
            m2_c2 <= rm2_now;  m2_c1 <= m2_c2;  m2_c0 <= m2_c1;
            prv_g1_q <= cur_g1_q;
            cur_g0_q <= i_g0;
            cur_g1_q <= i_g1;
            pcol_q   <= pcol;
            line_q   <= line_cnt;
            de_q <= i_de; hs_q <= i_hs; vs_q <= i_vs; va_q <= i_valid;
        end
    end

    assign nxt_g0 = i_g0;      // 下一对输入的第一个像素（x1 的右邻）

    // ------------------------------------------------------------------
    // 窗口拼装 + 边界 clamp
    // ------------------------------------------------------------------
    wire at_left  = (pcol_q == 10'd0);
    wire at_right = (pcol_q == 10'd959);
    wire vclamp   = (line_q < 10'd2);

    // 当前行
    wire [7:0] cy_x0_l = at_left  ? cur_g0_q : prv_g1_q;
    wire [7:0] cy_x0_m = cur_g0_q;
    wire [7:0] cy_x0_r = cur_g1_q;
    wire [7:0] cy_x1_l = cur_g0_q;
    wire [7:0] cy_x1_m = cur_g1_q;
    wire [7:0] cy_x1_r = at_right ? cur_g1_q : nxt_g0;

    // 上一行（y-1）
    wire [7:0] r1_x0_l = at_left  ? m1_c2[7:0]   : m1_c1[15:8];
    wire [7:0] r1_x0_m = m1_c2[7:0];
    wire [7:0] r1_x0_r = m1_c2[15:8];
    wire [7:0] r1_x1_l = m1_c2[7:0];
    wire [7:0] r1_x1_m = m1_c2[15:8];
    wire [7:0] r1_x1_r = at_right ? m1_c2[15:8]  : rm1_now[7:0];

    // 上上行（y-2）
    wire [7:0] r2_x0_l = at_left  ? m2_c2[7:0]   : m2_c1[15:8];
    wire [7:0] r2_x0_m = m2_c2[7:0];
    wire [7:0] r2_x0_r = m2_c2[15:8];
    wire [7:0] r2_x1_l = m2_c2[7:0];
    wire [7:0] r2_x1_m = m2_c2[15:8];
    wire [7:0] r2_x1_r = at_right ? m2_c2[15:8]  : rm2_now[7:0];

    // 垂直 clamp：帧内前两行用当前行复制
    wire [7:0] u1_x0_l = vclamp ? cy_x0_l : r1_x0_l;
    wire [7:0] u1_x0_m = vclamp ? cy_x0_m : r1_x0_m;
    wire [7:0] u1_x0_r = vclamp ? cy_x0_r : r1_x0_r;
    wire [7:0] u1_x1_l = vclamp ? cy_x1_l : r1_x1_l;
    wire [7:0] u1_x1_m = vclamp ? cy_x1_m : r1_x1_m;
    wire [7:0] u1_x1_r = vclamp ? cy_x1_r : r1_x1_r;

    wire vclamp2 = (line_q < 10'd2);
    wire [7:0] u2_x0_l = vclamp2 ? cy_x0_l : r2_x0_l;
    wire [7:0] u2_x0_m = vclamp2 ? cy_x0_m : r2_x0_m;
    wire [7:0] u2_x0_r = vclamp2 ? cy_x0_r : r2_x0_r;
    wire [7:0] u2_x1_l = vclamp2 ? cy_x1_l : r2_x1_l;
    wire [7:0] u2_x1_m = vclamp2 ? cy_x1_m : r2_x1_m;
    wire [7:0] u2_x1_r = vclamp2 ? cy_x1_r : r2_x1_r;

    // ------------------------------------------------------------------
    // 中值网络（两个像素各一套，各 19 个比较器）
    // ------------------------------------------------------------------
    wire [7:0] med0, med1;

    median9_net u_med0 (
        .p00(u2_x0_l), .p01(u2_x0_m), .p02(u2_x0_r),
        .p10(u1_x0_l), .p11(u1_x0_m), .p12(u1_x0_r),
        .p20(cy_x0_l), .p21(cy_x0_m), .p22(cy_x0_r),
        .med (med0)
    );

    median9_net u_med1 (
        .p00(u2_x1_l), .p01(u2_x1_m), .p02(u2_x1_r),
        .p10(u1_x1_l), .p11(u1_x1_m), .p12(u1_x1_r),
        .p20(cy_x1_l), .p21(cy_x1_m), .p22(cy_x1_r),
        .med (med1)
    );

    // ------------------------------------------------------------------
    // 输出
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0; o_valid <= 1'b0;
            o_g0 <= 8'd0; o_g1 <= 8'd0;
        end else begin
            o_de    <= de_q;
            o_hs    <= hs_q;
            o_vs    <= vs_q;
            o_valid <= va_q;
            o_g0    <= med0;
            o_g1    <= med1;
        end
    end

endmodule


//==============================================================================
// 3x3 中值：19 比较器并行网络
//   med = median3( max(列最小), median(列中值), min(列最大) )
//==============================================================================
module median9_net (
    input  wire [7:0] p00, p01, p02,
    input  wire [7:0] p10, p11, p12,
    input  wire [7:0] p20, p21, p22,
    output wire [7:0] med
);
    function [7:0] fmax3;
        input [7:0] a, b, c;
        begin
            fmax3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
        end
    endfunction

    function [7:0] fmin3;
        input [7:0] a, b, c;
        begin
            fmin3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
        end
    endfunction

    // 3 数中值（3 个比较器）
    function [7:0] fmed3;
        input [7:0] a, b, c;
        reg   [7:0] h, l, t;
        begin
            h = (a > b) ? a : b;
            l = (a > b) ? b : a;
            t = (h < c) ? h : c;
            fmed3 = (l > t) ? l : t;
        end
    endfunction

    wire [7:0] mx0 = fmax3(p00, p10, p20);
    wire [7:0] mn0 = fmin3(p00, p10, p20);
    wire [7:0] md0 = fmed3(p00, p10, p20);

    wire [7:0] mx1 = fmax3(p01, p11, p21);
    wire [7:0] mn1 = fmin3(p01, p11, p21);
    wire [7:0] md1 = fmed3(p01, p11, p21);

    wire [7:0] mx2 = fmax3(p02, p12, p22);
    wire [7:0] mn2 = fmin3(p02, p12, p22);
    wire [7:0] md2 = fmed3(p02, p12, p22);

    wire [7:0] A = (mn0 > mn1) ? ((mn0 > mn2) ? mn0 : mn2) : ((mn1 > mn2) ? mn1 : mn2);
    wire [7:0] C = (mx0 < mx1) ? ((mx0 < mx2) ? mx0 : mx2) : ((mx1 < mx2) ? mx1 : mx2);
    wire [7:0] B = fmed3(md0, md1, md2);

    assign med = fmed3(A, B, C);

endmodule
