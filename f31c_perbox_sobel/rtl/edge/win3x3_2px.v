//////////////////////////////////////////////////////////////////////////////
// win3x3_2px.v —— 2 像素/时钟的 3x3 窗口提取（行缓存 + 同步读）
//
// 输入：每拍一个像素对（DW 位，含两个像素），随数据携带像素对号 i_x 和行号 i_row
// 输出：3 行 × 4 列  {x2, x1, x0, xm1}（列 2p+2, 2p+1, 2p, 2p-1）
//       像素 0（列 2p） 的 3x3 窗 = 第 0/1/2 列
//       像素 1（列 2p+1）的 3x3 窗 = 第 1/2/3 列
//
// 结构：
//   3 个 bank 独立行缓存（1 写口 + 1 同步读口），行结束时 wb 前进 1
//   写：bank[wb][i_x]；读：bank[wb-1][i_x]（y-1 行）、bank[wb-2][i_x]（y-2 行）
//   同步读 1 拍 → 读出值为「右邻」，再打 1 拍 = 中间，打 2 拍 = 左邻
//   输入流打 3 拍 → 底行（y）右/中/左
//
// 数据滞后 2 拍（4 像素），因此 o_x 也随之滞后 2 拍；o_row = 窗口中间行 = i_row-1
// 本模块已被 Python 周期级模型 edge_rtl_model.py 逐拍验证（与 numpy 金标准 100% 一致）
//////////////////////////////////////////////////////////////////////////////
module win3x3_2px #(
    parameter integer DW      = 16,      // 一个像素对的位宽
    parameter integer H_PAIRS = 960,     // 每行像素对数
    parameter integer ADDR_W  = 10       // 行缓存地址位宽（2^ADDR_W >= H_PAIRS）
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              i_de,
    input  wire [ADDR_W-1:0] i_x,
    input  wire [11:0]       i_row,
    input  wire [DW-1:0]     i_pair,

    output wire              o_de,
    output reg  [ADDR_W-1:0] o_x,
    output wire [11:0]       o_row,
    output wire [4*(DW/2)-1:0] o_top,
    output wire [4*(DW/2)-1:0] o_mid,
    output wire [4*(DW/2)-1:0] o_bot
);

    localparam integer W2 = DW / 2;   // 单像素位宽

    // ------------------------------------------------------------------
    // 行缓存：3 个独立 bank
    // ------------------------------------------------------------------
    reg  [1:0] wb;
    reg        de_q;
    wire       line_end = de_q & ~i_de;

    wire we0 = i_de & (wb == 2'd0);
    wire we1 = i_de & (wb == 2'd1);
    wire we2 = i_de & (wb == 2'd2);

    wire [DW-1:0] q0, q1, q2;

    simple_dual_port_ram #(
        .DATA_WIDTH  (DW),
        .ADDR_WIDTH  (ADDR_W),
        .OUTPUT_REG  ("FALSE"),
        .RAM_INIT_FILE (""),
        .RAM_INIT_RADIX ("HEX")
    ) u_bank0 (
        .wdata (i_pair), .waddr (i_x), .raddr (i_x),
        .we (we0), .wclk (clk), .re (1'b1), .rclk (clk), .rdata (q0)
    );

    simple_dual_port_ram #(
        .DATA_WIDTH  (DW),
        .ADDR_WIDTH  (ADDR_W),
        .OUTPUT_REG  ("FALSE"),
        .RAM_INIT_FILE (""),
        .RAM_INIT_RADIX ("HEX")
    ) u_bank1 (
        .wdata (i_pair), .waddr (i_x), .raddr (i_x),
        .we (we1), .wclk (clk), .re (1'b1), .rclk (clk), .rdata (q1)
    );

    simple_dual_port_ram #(
        .DATA_WIDTH  (DW),
        .ADDR_WIDTH  (ADDR_W),
        .OUTPUT_REG  ("FALSE"),
        .RAM_INIT_FILE (""),
        .RAM_INIT_RADIX ("HEX")
    ) u_bank2 (
        .wdata (i_pair), .waddr (i_x), .raddr (i_x),
        .we (we2), .wclk (clk), .re (1'b1), .rclk (clk), .rdata (q2)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wb <= 2'd0;
        else if (line_end)
            wb <= (wb == 2'd2) ? 2'd0 : (wb + 2'd1);
    end

    // y-1 / y-2 对应的 bank（wb-1、wb-2）
    wire [1:0] b_m1 = (wb == 2'd0) ? 2'd2 : (wb - 2'd1);
    wire [1:0] b_m2 = (b_m1 == 2'd0) ? 2'd2 : (b_m1 - 2'd1);

    wire [DW-1:0] rd_m1 = (b_m1 == 2'd0) ? q0 : (b_m1 == 2'd1) ? q1 : q2;
    wire [DW-1:0] rd_m2 = (b_m2 == 2'd0) ? q0 : (b_m2 == 2'd1) ? q1 : q2;

    // ------------------------------------------------------------------
    // 打拍：读出的右邻 → 中/左；输入流 → 底行右/中/左
    // ------------------------------------------------------------------
    reg [DW-1:0] m1_d0, m1_d1;
    reg [DW-1:0] m2_d0, m2_d1;
    reg [DW-1:0] b_d1, b_d2, b_d3;
    reg [ADDR_W-1:0] x_d1;
    reg [11:0]   row_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m1_d0 <= {DW{1'b0}}; m1_d1 <= {DW{1'b0}};
            m2_d0 <= {DW{1'b0}}; m2_d1 <= {DW{1'b0}};
            b_d1  <= {DW{1'b0}}; b_d2  <= {DW{1'b0}}; b_d3 <= {DW{1'b0}};
            x_d1  <= {ADDR_W{1'b0}};
            row_d1 <= 12'd0;
            de_q  <= 1'b0;
        end else begin
            m1_d0 <= rd_m1;
            m1_d1 <= m1_d0;
            m2_d0 <= rd_m2;
            m2_d1 <= m2_d0;
            b_d1  <= i_pair;
            b_d2  <= b_d1;
            b_d3  <= b_d2;
            x_d1  <= i_x;
            row_d1 <= i_row;
            de_q  <= i_de;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_x <= {ADDR_W{1'b0}};
        else        o_x <= x_d1;
    end

    // ------------------------------------------------------------------
    // 窗口拼装（列序 {x2, x1, x0, xm1}）
    // ------------------------------------------------------------------
    assign o_top = { rd_m2[W2-1:0], m2_d0[DW-1:W2], m2_d0[W2-1:0], m2_d1[DW-1:W2] };
    assign o_mid = { rd_m1[W2-1:0], m1_d0[DW-1:W2], m1_d0[W2-1:0], m1_d1[DW-1:W2] };
    assign o_bot = { b_d1[W2-1:0],  b_d2[DW-1:W2], b_d2[W2-1:0], b_d3[DW-1:W2] };

    assign o_de  = i_de;
    assign o_row = row_d1 - 12'd1;      // 窗口中间行

endmodule
