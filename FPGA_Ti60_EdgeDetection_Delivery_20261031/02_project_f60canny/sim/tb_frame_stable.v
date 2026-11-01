//==============================================================================
// sim/tb_frame_stable.v -- frame_info_det 帧长稳定性判断验证
//
// 被测: rtl/frame_buffer_V3/frame_info_det.v
//   修复点: frame_len_d* 原来装的是 1bit 帧结束脉冲 (frame_end_r0)，恒等，
//           所以 frame_stable 永远=1，长度异常的坏帧也会写 DDR。
//           修复后装的是"像素总数"(frame_pix_num_o)，比较连续两帧像素数。
//
// 激励: 4 帧, 每帧 vs 高=消隐 / vs 低=有效, i_de 个数 = 像素数
//   frame1 : 16 像素   -> 与上一帧(0)不同 => frame_stable=0  (第一帧不上屏)
//   frame2 : 16 像素   -> 与 frame1 相同 => frame_stable=1  ★要求
//   frame3 : 15 像素   -> 与 frame2 不同 => frame_stable=0  ★要求(旧代码这里错成 1)
//   frame4 : 15 像素   -> 与 frame3 相同 => frame_stable=1  (恢复)
//
// 用法: vvp tb_frame_stable.vvp
//==============================================================================
`timescale 1ns/1ps

module tb_frame_stable;

reg clk = 1'b0;
always #5 clk = ~clk;

reg  rst_n = 1'b0;
reg  i_vs  = 1'b1;          // active high = 消隐期
reg  i_de  = 1'b0;
reg  [15:0] i_data = 16'd0;

wire [23:0] frame_pix_num_o;
wire        frame_stable;
wire        frame_start;
wire [31:0] ddr_frame_len;
wire        o_pixel_start, o_pixel_end, fifo_rst_p, o_valid;
wire [15:0] o_data;

frame_info_det #(
    .I_VID_WIDTH   (16 ),
    .SIM_EN        (1'b1),
    .AXI_DDR_WIDTH (128)
) dut (
    .clk            (clk            ),
    .rst_n          (rst_n          ),
    .i_vs           (i_vs           ),
    .i_hs           (1'b0           ),
    .i_de           (i_de           ),
    .i_data         (i_data         ),
    .frame_pix_num_o(frame_pix_num_o),
    .frame_stable   (frame_stable   ),
    .frame_start    (frame_start    ),
    .ddr_frame_len  (ddr_frame_len  ),
    .o_pixel_start  (o_pixel_start  ),
    .o_pixel_end    (o_pixel_end    ),
    .fifo_rst_p     (fifo_rst_p     ),
    .o_valid        (o_valid        ),
    .o_data         (o_data         )
);

//------------------------------------------------------------------------------
// 每帧的 pixel_start / pixel_end 脉冲计数 (随 frame_stable 一起看门控效果)
//------------------------------------------------------------------------------
integer ps_cnt = 0;
integer pe_cnt = 0;
always @(posedge clk) begin
    if (o_pixel_start) ps_cnt <= ps_cnt + 1;
    if (o_pixel_end)   pe_cnt <= pe_cnt + 1;
end

//------------------------------------------------------------------------------
// 4 个检查点寄存器
//------------------------------------------------------------------------------
reg [23:0] len_chk  [0:3];
reg        stb_chk  [0:3];
reg [31:0] psd_chk  [0:3];
reg [31:0] ped_chk  [0:3];

integer k;
integer err_cnt = 0;
integer f;

task send_frame;
    input integer n;        // 像素数
    integer j;
    begin
        ps_cnt = 0; pe_cnt = 0;
        // ---- 消隐 ----
        i_vs = 1'b1; i_de = 1'b0;
        repeat (8) @(negedge clk);
        // ---- 帧开始: vs 下降沿 ----
        i_vs = 1'b0;
        repeat (2) @(negedge clk);
        // ---- n 个有效像素 ----
        for (j = 0; j < n; j = j + 1) begin
            i_de   = 1'b1;
            i_data = j[15:0];
            @(negedge clk);
        end
        i_de = 1'b0;
        repeat (3) @(negedge clk);
        // ---- 帧结束: vs 上升沿 ----
        i_vs = 1'b1;
        repeat (8) @(negedge clk);
        // ---- 采样 (frame_stable 在 vs 上升沿后 3 拍更新) ----
        len_chk[f] = frame_pix_num_o;
        stb_chk[f] = frame_stable;
        psd_chk[f] = ps_cnt;
        ped_chk[f] = pe_cnt;
        $display("[FRAME %0d] pixels_in=%0d frame_pix_num_o=%0d frame_stable=%b  pixel_start=%0d pixel_end=%0d  ddr_frame_len=%0d",
                 f + 1, n, frame_pix_num_o, frame_stable, ps_cnt, pe_cnt, ddr_frame_len);
    end
endtask

task check;
    input integer idx;
    input        exp_stb;
    input [23:0] exp_len;
    begin
        if (len_chk[idx] !== exp_len) begin
            $display("   [FAIL] frame%0d frame_pix_num_o=%0d (exp %0d)", idx+1, len_chk[idx], exp_len);
            err_cnt = err_cnt + 1;
        end
        if (stb_chk[idx] !== exp_stb) begin
            $display("   [FAIL] frame%0d frame_stable=%b (exp %b)", idx+1, stb_chk[idx], exp_stb);
            err_cnt = err_cnt + 1;
        end else begin
            $display("   [ OK ] frame%0d frame_stable=%b (exp %b)", idx+1, stb_chk[idx], exp_stb);
        end
    end
endtask

initial begin
    $display("==============================================================");
    $display(" tb_frame_stable : 连续两帧像素总数 == 才 frame_stable=1");
    $display("==============================================================");
    rst_n = 1'b0;
    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    f = 0; send_frame(16);   // frame1
    f = 1; send_frame(16);   // frame2
    f = 2; send_frame(15);   // frame3  <-- 坏帧
    f = 3; send_frame(15);   // frame4

    $display("--------------------------------------------------------------");
    check(0, 1'b0, 24'd16);
    check(1, 1'b1, 24'd16);
    check(2, 1'b0, 24'd15);
    check(3, 1'b1, 24'd15);
    $display("--------------------------------------------------------------");
    if (err_cnt == 0)
        $display("[RESULT] PASS -- 帧长判断按像素总数比较 (16/16 -> stable=1, 16/15 -> stable=0)");
    else
        $display("[RESULT] FAIL -- %0d 处不符", err_cnt);
    $display("==============================================================");
    $finish;
end

endmodule
