//==============================================================================
// sim/tb_vid_order.v -- CSI RAW10 四像素组序判定 (把"哪种拼法对"一次测清楚)
//
// 被测链路 (与 rtl/ti60f225_oob_top.v:603 的 vin 拼接 + frame_buffer_V3 一致):
//
//   raw40 = {P4[39:30],P3[29:20],P2[19:10],P1[9:0]}   // CSI 每拍 4 个 RAW10 像素
//      -> vin = 候选拼法 (每段取 [9:2] 高 8bit, 8bit 灰度通路)
//      -> ser2par_v1   32b -> 128b   (4 拍拼成 1 个 128bit DDR 字, 首拍在最高字节)
//      -> DDR/AXI 字节透传 (wdata[8i+:8] 落在第 i 个字节地址, 读回同一字节)
//      -> vid_par2ser 128b -> 16b    (MSB 先出, 每拍 2 个像素)
//      -> 顶层 vout({ch0_g,ch0_b}) -> debayer raw_datax4_i({ch0_b,ch0_g})   <- 一次字节交换
//      -> debayer 2 像素/拍
//
// 唯一不确定的就是"16bit 字里哪个字节是这一拍的第一个像素"。本 TB 两种解码都跑：
//   DEC_LOW  : 低字节先 (debayer 认为低字节 = 第一个像素, 且顶层没有那次交换)
//   DEC_HIGH : 高字节先 (等价于 debayer 低字节优先 + 顶层那次字节交换, 也就是本工程的真实接线)
// 于是 3 种候选拼法 x 2 种解码 = 6 行结果，哪一行等于 01..10 就是本工程该用的拼法。
//
// 用法:
//   vvp tb_vid_order.vvp            -> 打印 6 行判定表 + 11/22/33/44 样例
//   vvp tb_vid_order.vvp +BUGGY     -> 只看原始拼法 {P4,P3,P2,P1}
//==============================================================================
`timescale 1ns/1ps

module tb_vid_order;

reg clk = 1'b0;
always #5 clk = ~clk;                 // 100 MHz

reg rst_n      = 1'b0;
reg only_buggy = 1'b0;

//------------------------------------------------------------------------------
// 1) RAW10 40bit 字 + 候选 vin 拼法
//------------------------------------------------------------------------------
reg  [7:0]  p1_8 = 8'h00, p2_8 = 8'h00, p3_8 = 8'h00, p4_8 = 8'h00;
wire [39:0] raw40 = { p4_8,2'b00, p3_8,2'b00, p2_8,2'b00, p1_8,2'b00 };  // P4,P3,P2,P1
wire [7:0]  b1 = raw40[9:2];     // P1 (取 10bit 的高 8bit)
wire [7:0]  b2 = raw40[19:12];   // P2
wire [7:0]  b3 = raw40[29:22];   // P3
wire [7:0]  b4 = raw40[39:32];   // P4

reg  [1:0]  cand = 2'd0;
reg  [31:0] vin_sel;
always @(*) begin
    case (cand)
        2'd0:    vin_sel = { b4, b3, b2, b1 };   // 原始 {P4,P3,P2,P1}
        2'd1:    vin_sel = { b2, b1, b4, b3 };   // 参考报告的修复 {P2,P1,P4,P3}
        default: vin_sel = { b1, b2, b3, b4 };   // 完全倒序 {P1,P2,P3,P4}
    endcase
end

//------------------------------------------------------------------------------
// 2) 写侧 ser2par_v1 : 32b -> 128b  (= AXI_DATA_WIDTH 128)
//------------------------------------------------------------------------------
reg          i_valid       = 1'b0;
reg          i_frame_start = 1'b0;
reg          i_frame_end   = 1'b0;
wire         ser_o_valid, ser_o_fstart, ser_o_fend;
wire [127:0] ser_o_data;

ser2par_v1 #(
    .I_VID_WIDTH (32 ),
    .O_VID_WIDTH (128)
) u_ser2par (
    .clk           (clk           ),
    .rst_n         (rst_n         ),
    .i_valid       (i_valid       ),
    .i_frame_start (i_frame_start ),
    .i_frame_end   (i_frame_end   ),
    .frame_stable  (1'b1          ),
    .frame_pix_num (24'd16        ),
    .i_data        (vin_sel       ),
    .o_valid       (ser_o_valid   ),
    .o_data        (ser_o_data    ),
    .o_frame_start (ser_o_fstart  ),
    .o_frame_end   (ser_o_fend    )
);

//------------------------------------------------------------------------------
// 3) 读侧 vid_par2ser : 128b -> 16b,  MSB 先出
//------------------------------------------------------------------------------
reg          frame_period    = 1'b0;
reg          rd_fifo_rdvalid = 1'b1;   // 该口在 vid_par2ser 内部未使用
reg          read_phase      = 1'b0;
reg          fetch_done      = 1'b0;
reg  [127:0] ddr_word        = 128'd0;
wire         rd_fifo_rden, tx_fifo_valid, rd_fifo_rdempty;
wire [15:0]  tx_fifo_wrdata;

assign rd_fifo_rdempty = ~read_phase | fetch_done;   // 单字 FIFO 模型: 取一次就空
always @(posedge clk) if (rd_fifo_rden) fetch_done <= 1'b1;

vid_par2ser #(
    .I_VID_WIDTH (128),
    .O_VID_WIDTH (16 )
) u_par2ser (
    .clk            (clk            ),
    .rst_n          (rst_n          ),
    .frame_period   (frame_period   ),
    .rd_fifo_rdvalid(rd_fifo_rdvalid),
    .rd_fifo_rddata (ddr_word       ),
    .rd_fifo_rdempty(rd_fifo_rdempty),
    .rd_fifo_rden   (rd_fifo_rden   ),
    .tx_fifo_valid  (tx_fifo_valid  ),
    .wr_fifo_full   (1'b0           ),
    .tx_fifo_wrdata (tx_fifo_wrdata )
);

//------------------------------------------------------------------------------
// 4) 采集
//------------------------------------------------------------------------------
reg  [15:0] cap [0:63];
reg  [7:0]  got [0:63];
reg  [7:0]  v   [0:3];
integer     nw = 0;
integer     i, g, k, err;

always @(posedge clk) begin
    if (ser_o_valid) ddr_word <= ser_o_data;
    if (tx_fifo_valid && nw < 64) begin
        cap[nw] <= tx_fifo_wrdata;
        nw      <= nw + 1;
    end
end

task do_reset;
    begin
        rst_n = 1'b0;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask

// 跑一遍 4 拍 vin (16 像素), 像素值由 mode 决定: 0 -> 11,22,33,44 循环; 1 -> 1..16
task run_chain;
    input integer mode;
    integer to;
    begin
        nw = 0; read_phase = 0; fetch_done = 0; frame_period = 0;
        i_valid = 0; i_frame_start = 0; i_frame_end = 0;
        do_reset;
        for (g = 0; g < 4; g = g + 1) begin
            for (k = 0; k < 4; k = k + 1)
                v[k] = (mode == 0) ? (8'h11 * (((4*g+k) % 4) + 1)) : (4*g + k + 1);
            p1_8 = v[0]; p2_8 = v[1]; p3_8 = v[2]; p4_8 = v[3];
            @(negedge clk);
            i_valid = 1'b1; i_frame_start = (g == 0) ? 1'b1 : 1'b0;
            @(negedge clk);
            i_valid = 1'b0; i_frame_start = 1'b0;
        end
        to = 0;
        while (!ser_o_valid && to < 32) begin @(negedge clk); to = to + 1; end
        if (to >= 32) $display("[ERR] ser2par_v1 o_valid 超时");
        @(negedge clk);
        read_phase = 1'b1; fetch_done = 1'b0;
        @(negedge clk);
        frame_period = 1'b1; @(negedge clk); frame_period = 1'b0;
        to = 0;
        while (nw < 16 && to < 400) begin @(negedge clk); to = to + 1; end
        repeat (4) @(negedge clk);
    end
endtask

function [7:0] exp_pix;
    input integer mode;
    input integer idx;
    begin
        exp_pix = (mode == 0) ? (8'h11 * ((idx % 4) + 1)) : (idx + 1);
    end
endfunction

// 解码 8 个 16bit 字 -> 16 个像素字节; first_low=1 表示低字节是第一个像素
task decode;
    input first_low;
    integer j;
    begin
        for (j = 0; j < 32; j = j + 1) got[j] = 8'hxx;
        for (j = 0; j < 16; j = j + 1) begin
            if (j < nw) begin
                got[2*j]   = first_low ? cap[j][7:0]  : cap[j][15:8];
                got[2*j+1] = first_low ? cap[j][15:8] : cap[j][7:0];
            end
        end
    end
endtask

task show_two;
    input integer mode;
    integer j;
    begin
        $write("     got :");
        for (j = 0; j < 16; j = j + 1) $write(" %02h", got[j]);
        err = 0;
        for (j = 0; j < 16; j = j + 1) if (got[j] !== exp_pix(mode, j)) err = err + 1;
        if (err == 0) $write("   <= 与期望一致 (0 错位)\n");
        else          $write("   <= %0d/16 像素错位\n", err);
    end
endtask

task show_exp;
    input integer mode;
    integer j;
    begin
        $write("     exp :");
        for (j = 0; j < 16; j = j + 1) $write(" %02h", exp_pix(mode, j));
        $write("\n");
    end
endtask

integer c;

initial begin
    if ($test$plusargs("BUGGY")) only_buggy = 1'b1;
    $display("==============================================================================");
    $display(" tb_vid_order : CSI RAW10 4像素/40bit 组序判定表");
    $display("   链路: ser2par_v1(32->128) -> [DDR 字节透传] -> vid_par2ser(128->16)");
    $display("   输入: 16 个像素 = 01,02,...,10 (递增, 组边界/对边界错位一眼可见)");
    $display("==============================================================================");

    // ---- 判定表: 3 种拼法 x 2 种解码 ----
    for (c = 0; c < 3; c = c + 1) begin
        cand = c[1:0];
        run_chain(1);
        case (c)
            0: $display("[C%0d] vin = {P4,P3,P2,P1}  (原始/改前)", c);
            1: $display("[C%0d] vin = {P2,P1,P4,P3}  (参考报告的修复)", c);
            default: $display("[C%0d] vin = {P1,P2,P3,P4}  (完全倒序)", c);
        endcase
        decode(1'b1); $write("   DEC_LOW  (低字节=第一像素)"); $write("\n"); show_exp(1); show_two(1);
        decode(1'b0); $write("   DEC_HIGH (高字节=第一像素 = 低字节优先+顶层字节交换)\n"); show_exp(1); show_two(1);
        if (only_buggy && c > 0) c = 99;   // +BUGGY 只看 C0
    end

    // ---- 规格样例: {P4,P3,P2,P1} 编码成 11,22,33,44 ----
    $display("------------------------------------------------------------------------------");
    $display("[样例] raw40={P4,P3,P2,P1}=44/33/22/11, vin={P2,P1,P4,P3} (本次生效的修复)");
    cand = 2'd1;
    run_chain(0);
    decode(1'b1); $write("   DEC_LOW :"); show_two(0);
    decode(1'b0); $write("   DEC_HIGH:"); show_two(0);

    $display("------------------------------------------------------------------------------");
    $display(" [怎么读这张表] 只有一行能等于 01..10，那一行才是本工程真实链路 + 正确拼法：");
    $display("   * 真实解码 = 低字节先(参考报告的说法)      -> 用 C1 {P2,P1,P4,P3}  (本次已生效)");
    $display("   * 真实解码 = 高字节先(debayer 低字节优先 + 顶层那次 ch0_g/ch0_b 交换)");
    $display("                                              -> 用 C2 {P1,P2,P3,P4}");
    $display("   反过来读: C0/DEC_LOW  错位 = 相邻两像素互换(周期 2)");
    $display("             C0/DEC_HIGH 错位 = 组内 4 像素倒序(周期 4)");
    $display("   上板看到的是哪种周期，就知道该用 C1 还是 C2。");
    $display("==============================================================================");
    $finish;
end

endmodule
