//////////////////////////////////////////////////////////////////////////////
// display_composer.v —— 显示合成（像素时钟域，1 像素/时钟）
//
// 三种模式：
//   0 = 分屏：左半 = 灰度全图（2 源像素平均后 1:1 铺满 960 列）
//              右半 = 边缘全图（2 源像素取"或"，红/黑）
//   1 = 全屏边缘（红/黑，1:1）
//   2 = 红边缘叠加彩色原图（1:1）
//
// 行缓存：960 × 9bit（{edge, gray8}）× 2 bank，写本行、读上一行
//   → 由 LUT/FF 改为 BRAM，避免占用逻辑资源
//   2:1 用"成对平均"而不是抽点，消除锯齿
//////////////////////////////////////////////////////////////////////////////
module display_composer #(
    parameter integer H_ACTIVE   = 1920,
    parameter integer SPLIT_X    = 960,
    parameter integer SMP_ADDR_W = 10,
    parameter integer RED_R      = 8'hFF,
    parameter integer RED_G      = 8'h20,
    parameter integer RED_B      = 8'h20
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_de,
    input  wire        i_hs,
    input  wire        i_vs,

    input  wire [9:0]  i_smp,        // {raw, edge, gray8}：一个 vid 拍（2 源像素）= 1 个样本
    input  wire        i_smp_en,     // 每个 vid 拍一个脉冲
    input  wire [23:0] i_rgb,        // {b,g,r}
    input  wire        i_edge,
    input  wire        i_raw,        // 去孤立点之前的原始边缘（诊断）
    input  wire [1:0]  i_mode,

    output reg         o_de,
    output reg         o_hs,
    output reg         o_vs,
    output reg  [7:0]  o_r,
    output reg  [7:0]  o_g,
    output reg  [7:0]  o_b
);

    localparam integer H_PAIRS = H_ACTIVE / 2;

    // ------------------------------------------------------------------
    // 写侧：样本号 0..H_PAIRS-1，行结束翻 bank
    // ------------------------------------------------------------------
    reg  [SMP_ADDR_W-1:0] wr_addr;
    reg  [SMP_ADDR_W-1:0] rd_addr;
    reg  [10:0]           x;
    reg                   bank;
    reg                   de_q;
    reg                   half_r;
    reg  [1:0]            mode_d;

    wire line_end = de_q & ~i_de;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= {SMP_ADDR_W{1'b0}};
            bank    <= 1'b0;
            de_q    <= 1'b0;
        end else begin
            de_q <= i_de;
            if (i_de && i_smp_en)
                wr_addr <= (wr_addr == (H_PAIRS - 1)) ? {SMP_ADDR_W{1'b0}}
                                                      : (wr_addr + 1'b1);
            if (line_end) begin
                bank    <= ~bank;
                wr_addr <= {SMP_ADDR_W{1'b0}};
            end
        end
    end

    // ------------------------------------------------------------------
    // 读侧：显示列 x（0..1919）→ 样本号 (x<960 ? x : x-960)，读上一行
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x      <= 11'd0;
            rd_addr <= {SMP_ADDR_W{1'b0}};
            half_r  <= 1'b0;
            mode_d  <= 2'd0;
        end else begin
            mode_d <= i_mode;
            if (!i_de) begin
                x      <= 11'd0;
                rd_addr <= {SMP_ADDR_W{1'b0}};
                half_r  <= 1'b0;
            end else begin
                x <= x + 11'd1;
                if (x < SPLIT_X) begin
                    rd_addr <= x[SMP_ADDR_W-1:0];
                    half_r  <= 1'b0;
                end else begin
                    rd_addr <= (x - SPLIT_X);
                    half_r  <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 双 bank 行缓存
    // ------------------------------------------------------------------
    wire [9:0] bank0_q, bank1_q;

    simple_dual_port_ram #(
        .DATA_WIDTH (10), .ADDR_WIDTH (SMP_ADDR_W),
        .OUTPUT_REG ("FALSE"), .RAM_INIT_FILE (""), .RAM_INIT_RADIX ("HEX")
    ) u_bank0 (
        .wdata (i_smp), .waddr (wr_addr), .raddr (rd_addr),
        .we (i_de & i_smp_en & ~bank), .wclk (clk), .re (1'b1), .rclk (clk),
        .rdata (bank0_q)
    );

    simple_dual_port_ram #(
        .DATA_WIDTH (10), .ADDR_WIDTH (SMP_ADDR_W),
        .OUTPUT_REG ("FALSE"), .RAM_INIT_FILE (""), .RAM_INIT_RADIX ("HEX")
    ) u_bank1 (
        .wdata (i_smp), .waddr (wr_addr), .raddr (rd_addr),
        .we (i_de & i_smp_en &  bank), .wclk (clk), .re (1'b1), .rclk (clk),
        .rdata (bank1_q)
    );

    wire [9:0] rd_word = bank ? bank0_q : bank1_q;   // 读另一个 bank（上一行）

    // ------------------------------------------------------------------
    // 第一级打拍：RAM 输出与实时路径对齐
    // ------------------------------------------------------------------
    reg        de_d1, hs_d1, vs_d1;
    reg        half_d1;
    reg [1:0]  mode_d1;
    reg [9:0]  word_d1;
    reg [23:0] rgb_d1;
    reg        edge_d1;
    reg        raw_d1;
    reg [10:0] col_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d1 <= 1'b0; hs_d1 <= 1'b0; vs_d1 <= 1'b0;
            half_d1 <= 1'b0; mode_d1 <= 2'd0;
            word_d1 <= 10'd0; rgb_d1 <= 24'd0; edge_d1 <= 1'b0; raw_d1 <= 1'b0; col_d1 <= 11'd0;
        end else begin
            de_d1   <= i_de;
            hs_d1   <= i_hs;
            vs_d1   <= i_vs;
            half_d1 <= half_r;
            mode_d1 <= mode_d;
            word_d1 <= rd_word;
            rgb_d1  <= i_rgb;
            edge_d1 <= i_edge;
            raw_d1  <= i_raw;
            col_d1  <= x;
        end
    end

    // ------------------------------------------------------------------
    // 第二级：模式选择 + 输出寄存
    // ------------------------------------------------------------------
    wire [7:0] spl_gray = word_d1[7:0];
    wire       spl_edge = word_d1[8];
    wire       spl_raw  = word_d1[9];

    wire [23:0] EDGE_RED = {RED_R, RED_G, RED_B};
    wire [23:0] EDGE_GRN = 24'h00E000;      // 原始边缘但被孤立点过滤掉 → 绿

    wire [23:0] px_split = half_d1 ? (spl_edge ? EDGE_RED :
                                      (spl_raw ? EDGE_GRN : 24'd0))
                                   : {spl_gray, spl_gray, spl_gray};
    wire [23:0] px_edge  = edge_d1 ? EDGE_RED : (raw_d1 ? EDGE_GRN : 24'd0);
    wire [23:0] px_over  = edge_d1 ? EDGE_RED : (raw_d1 ? EDGE_GRN : rgb_d1);

    // mode 3：自检彩条（不依赖相机 / 流水线，用于验证显示通路是否导通）
    wire [2:0]  bar_sel = col_d1[10:8];
    reg  [23:0] px_diag;
    always @(*) begin
        case (bar_sel)
            3'd0: px_diag = 24'hFFFFFF;   // 白
            3'd1: px_diag = 24'hFFFF00;   // 黄
            3'd2: px_diag = 24'h00FFFF;   // 青
            3'd3: px_diag = 24'h00FF00;   // 绿
            3'd4: px_diag = 24'hFF00FF;   // 品红
            3'd5: px_diag = 24'hFF0000;   // 红
            3'd6: px_diag = 24'h0000FF;   // 蓝
            default: px_diag = 24'h000000;
        endcase
    end

    wire [23:0] px_sel = (mode_d1 == 2'd0) ? px_split :
                         (mode_d1 == 2'd1) ? px_edge  :
                         (mode_d1 == 2'd2) ? px_over  : px_diag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0;
            o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
        end else begin
            o_de <= de_d1;
            o_hs <= hs_d1;
            o_vs <= vs_d1;
            o_r  <= px_sel[23:16];
            o_g  <= px_sel[15:8];
            o_b  <= px_sel[7:0];
        end
    end

endmodule
