//////////////////////////////////////////////////////////////////////////////
// auto_thr_2px.v —— 逐帧直方图自动阈值（光照自适应，2026-10-27）
//
//   目的：解决「固定阈值对光照/对比度敏感」——每帧统计 NMS 后幅值的分布，
//         取「从高到低累计到 (非零样本 × PCT_NUM/PCT_DEN) 的那个 bin」作为
//         下一帧的阈值。整体亮/暗、对比度变化时阈值同比跟随。
//
//   数据流：
//     i_mag {pix1[11:0], pix0[11:0]}（NMS 后幅值）
//        └─ 每 4 个像素对采样 1 个 pixel0（2bit 计数器 == 0 时采样）
//             idx = i_mag[11:4]  → 256 bin × 16bit 直方图（simple_dual_port_ram）
//             idx != 0 → cnt_nz++（32bit）
//
//   帧末（i_vs 上升沿后，垂直消隐期）：
//     target = cnt_nz × PCT_NUM / PCT_DEN
//              （定点近似：PCT_NUM×4096/PCT_DEN = 123 → 123/4096 = 0.03003）
//     从 bin 255 往下扫到 0：acc += hist[b]，第一个 acc >= target 的 b
//        → o_thr = b << 4
//     cnt_nz == 0（整帧无边缘）→ o_thr = 56（保底值）
//     扫完用 256 拍逐 bin 写 0 清直方图；上电复位后也先清一遍（BOOT），
//     保证仿真/硬件初始直方图为 0。
//
//   读改写时序（simple_dual_port_ram，OUTPUT_REG="TRUE" = 2 拍输出延迟）：
//     拍 m   : 采样，raddr = idx，re = 1
//     拍 m+1 : RAM 采样地址（r_rdata_1P）
//     拍 m+2 : rdata 有效（r_rdata_2P）；idx/valid 同步延迟 2 拍 → 对齐
//     拍 m+3 : 写端口寄一拍（we / waddr / wdata = rdata+1）
//     拍 m+4 : RAM 写入
//     下一次采样在拍 m+4 发出，RAM 在拍 m+5 采样地址 → 读到的已是写回值，
//     因此采样间隔 4 拍（2bit 计数器）刚好给读改写留出 2 拍 + 写回 1 拍，
//     同一 bin 连续命中也不会丢计数。
//
//   扫描阶段只读不写：每拍发一个地址（256 拍），数据晚 2 拍对齐累加；
//   扫完再等 2 拍把流水排空，然后进入清 0（只写不读），读写端口互不冲突。
//
//   注意：bin 计数器固定 16bit（按需求）；1080p 下 1/4 对采样 ≈ 26 万样本，
//         若某个 bin 独占 >25% 的样本会溢出。正常自然图像分布远低于此。
//////////////////////////////////////////////////////////////////////////////
module auto_thr_2px #(
    parameter integer PCT_NUM = 3,          // 目标百分比分子（默认 3%）
    parameter integer PCT_DEN = 100         // 目标百分比分母
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [23:0] i_mag,               // {pix1[11:0], pix0[11:0]} NMS 后幅值
    output reg  [11:0] o_thr,               // 上一帧统计出的阈值（帧末更新）
    output reg         o_valid              // 本帧统计有效（首帧统计完成前为 0）
);

    // ------------------------------------------------------------------
    // 常量
    // ------------------------------------------------------------------
    localparam integer HIST_DW  = 16;       // 每 bin 计数位宽
    localparam integer HIST_AW  = 8;        // 256 bin
    localparam integer TGT_FRAC = 12;       // 百分比定点小数位
    // PCT_NUM/PCT_DEN 的定点近似（3/100 → 123/4096 = 0.030029，误差 +0.10%）
    localparam integer TGT_MUL  = (PCT_NUM * (1 << TGT_FRAC) + (PCT_DEN / 2)) / PCT_DEN;
    localparam [11:0]  THR_FLOOR = 12'd56;  // 无边缘帧的保底阈值

    // ------------------------------------------------------------------
    // 状态机
    // ------------------------------------------------------------------
    localparam [2:0] S_BOOT  = 3'd0,        // 上电清直方图（256 拍）
                     S_IDLE  = 3'd1,        // 帧内统计
                     S_PREP  = 3'd2,        // 帧末等待读改写流水排空
                     S_SCAN  = 3'd3,        // 255 → 0 扫描
                     S_CLEAR = 3'd4;        // 清直方图

    reg  [2:0] st;
    reg  [7:0] ccnt;                        // 清 0 的 bin 序号
    reg  [8:0] scnt;                        // 扫描节拍 0..259
    reg  [2:0] prep_cnt;
    reg  [1:0] smp_cnt;                     // 2bit 采样计数器（==0 采样）
    reg        vs_q;

    reg  [31:0] cnt_nz;                     // 本帧非零样本数
    reg  [31:0] target;                     // 帧末目标计数
    reg  [31:0] acc;                        // 扫描累加
    reg         found;

    // ------------------------------------------------------------------
    // 采样 / 非零计数
    // ------------------------------------------------------------------
    wire        vs_rise  = i_vs & ~vs_q;
    wire [7:0]  smp_idx  = i_mag[11:4];     // 只统计 pixel0
    wire        smp_tick = i_de && (smp_cnt == 2'd0) && (st == S_IDLE) && !vs_rise;

    // ------------------------------------------------------------------
    // 读地址：扫描（每拍一个，255→0）或采样（每 4 个像素对一个）
    // ------------------------------------------------------------------
    wire        scan_act = (st == S_SCAN) && (scnt < 9'd256);
    wire [7:0]  scan_idx = 8'd255 - scnt[7:0];
    wire        rd_req   = scan_act | smp_tick;
    wire [7:0]  rd_addr  = scan_act ? scan_idx : smp_idx;

    // 读数据有效/索引流水：拍 m 发地址 → 拍 m+2 数据有效（2 拍）
    reg  [7:0]  p1_idx, p2_idx;
    reg         p1_v,   p2_v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_idx <= 8'd0; p1_v <= 1'b0;
            p2_idx <= 8'd0; p2_v <= 1'b0;
        end else begin
            p1_idx <= rd_addr; p1_v <= rd_req;
            p2_idx <= p1_idx;  p2_v <= p1_v;
        end
    end

    // ------------------------------------------------------------------
    // 直方图 RAM（必须用原语，避免综合器把 256×16 推断成触发器）
    // ------------------------------------------------------------------
    reg         we_r;
    reg  [7:0]  waddr_r;
    reg  [15:0] wdata_r;

    wire        clear_on    = (st == S_BOOT) || (st == S_CLEAR);
    wire [7:0]  ram_we_addr = clear_on ? ccnt : waddr_r;
    wire [15:0] ram_we_data = clear_on ? {HIST_DW{1'b0}} : wdata_r;
    wire        ram_we      = clear_on | we_r;
    wire [15:0] hist_q;

    simple_dual_port_ram #(
        .DATA_WIDTH (HIST_DW),
        .ADDR_WIDTH (HIST_AW),
        .OUTPUT_REG ("TRUE")
    ) u_hist (
        .wdata (ram_we_data),
        .waddr (ram_we_addr),
        .we    (ram_we),
        .wclk  (clk),
        .raddr (rd_addr),
        .re    (rd_req),
        .rclk  (clk),
        .rdata (hist_q)
    );

    // 写端口寄一拍：读数据在拍 m+2 有效 → 拍 m+3 寄存 → 拍 m+4 落 RAM；
    // 下一次采样的地址在拍 m+5 被 RAM 采样，读到的已是写回值（不丢更新）。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            we_r <= 1'b0; waddr_r <= 8'd0; wdata_r <= 16'd0;
        end else begin
            we_r    <= p2_v && ((st == S_IDLE) || (st == S_PREP));
            waddr_r <= p2_idx;
            wdata_r <= hist_q + {{(HIST_DW-1){1'b0}}, 1'b1};
        end
    end

    // ------------------------------------------------------------------
    // 帧末：target 与 255→0 扫描
    // ------------------------------------------------------------------
    wire [31:0] tgt_raw = (cnt_nz * TGT_MUL) >> TGT_FRAC;
    wire        scan_data = p2_v && (st == S_SCAN);
    wire [31:0] acc_n     = acc + {16'd0, hist_q};

    // ------------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_BOOT;
            ccnt     <= 8'd0;
            scnt     <= 9'd0;
            prep_cnt <= 3'd0;
            smp_cnt  <= 2'd0;
            vs_q     <= 1'b0;
            cnt_nz   <= 32'd0;
            target   <= 32'd0;
            acc      <= 32'd0;
            found    <= 1'b0;
            o_thr    <= 12'd0;
            o_valid  <= 1'b0;
        end else begin
            vs_q <= i_vs;

            // 采样节拍：只在 S_IDLE 内随 i_de 推进，离开 IDLE 归零
            if (st != S_IDLE) smp_cnt <= 2'd0;
            else if (i_de)   smp_cnt <= smp_cnt + 2'd1;

            // 非零样本计数（idx != 0）
            if (smp_tick && (smp_idx != 8'd0))
                cnt_nz <= cnt_nz + 32'd1;

            // 扫描累加：acc += hist[b]，第一个 acc >= target 的 b 出阈值
            if (scan_data) begin
                acc <= acc_n;
                if (!found && (acc_n >= target)) begin
                    found <= 1'b1;
                    o_thr <= {p2_idx, 4'b0000};
                end
            end

            case (st)
                // ---- 上电清直方图（保证仿真/硬件 RAM 初值为 0）----
                S_BOOT: begin
                    if (ccnt == 8'd255) begin
                        ccnt <= 8'd0;
                        st   <= S_IDLE;
                    end else ccnt <= ccnt + 8'd1;
                end

                // ---- 帧内统计 ----
                S_IDLE: begin
                    if (vs_rise) begin
                        smp_cnt <= 2'd0;
                        cnt_nz  <= 32'd0;           // 本帧计数已锁存到 target
                        if (cnt_nz == 32'd0) begin
                            // 整帧无边缘：保底阈值
                            o_thr   <= THR_FLOOR;
                            o_valid <= 1'b1;
                            ccnt    <= 8'd0;
                            st      <= S_CLEAR;
                        end else begin
                            // cnt_nz 很小（<34）时定点结果可能为 0，钳到 1：
                            // 即退化为「最高非空 bin」，不会误取 bin 255。
                            target   <= (tgt_raw == 32'd0) ? 32'd1 : tgt_raw;
                            acc      <= 32'd0;
                            found    <= 1'b0;
                            prep_cnt <= 3'd0;
                            st       <= S_PREP;
                        end
                    end
                end

                // ---- 等读改写流水排空（最后一笔写回落在此时）----
                S_PREP: begin
                    if (prep_cnt == 3'd3) begin
                        scnt <= 9'd0;
                        st   <= S_SCAN;
                    end else prep_cnt <= prep_cnt + 3'd1;
                end

                // ---- 255 → 0 扫描（只读）----
                S_SCAN: begin
                    if (scnt < 9'd259)
                        scnt <= scnt + 9'd1;        // 256 拍发地址 + 3 拍排空
                    else begin
                        if (!found) o_thr <= THR_FLOOR;  // 理论不可达，兜底
                        ccnt <= 8'd0;
                        st   <= S_CLEAR;
                    end
                end

                // ---- 逐 bin 写 0（只写）----
                S_CLEAR: begin
                    if (ccnt == 8'd255) begin
                        ccnt    <= 8'd0;
                        o_valid <= 1'b1;
                        st      <= S_IDLE;
                    end else ccnt <= ccnt + 8'd1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
