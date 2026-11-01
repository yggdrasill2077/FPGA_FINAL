//==============================================================================
// tb_vs_tick.v —— P1-1 回归：rgb_vs 是「5 行电平」而不是「单拍脉冲」
//
//   顶层 ti60f225_oob_top.v 的四段 always（hold_frm / freeze_on / play_cnt / rp_arm）
//   被原样复制成两个小模块，分别对应
//       tick_old : 直接用 rgb_vs 当 enable（改前）
//       tick_new : 用 rgb_vs_rise 当 enable（改后）
//   两个模块吃同一份 rgb_vs 激励（真实 1080p60：1125 行/帧、1100 拍/行、vs 高 5 行），
//   各自在 freeze_on 上升后自动按下 KEY1 打开自动回放，量化三个指标：
//       (1) 双键按住后多久 freeze_on 翻转   —— 应 48 帧 ≈ 0.80s，而不是 48 拍
//       (2) auto_step 的平均间隔            —— 应 6 帧(≈10fps)，而不是 6 拍
//       (3) 冻结后多久 rp_arm 到 2          —— 应 2 帧，而不是 2 拍
//
//   注意：这里验证的是「拍数语义」；顶层其余部分（CSI/DDR/PLL/IP）不可整机仿真。
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -s tb_vs_tick -o sim/tb_vs_tick.vvp sim/tb_vs_tick.v
//     vvp sim/tb_vs_tick.vvp
//==============================================================================
`timescale 1ns/1ps

//------------------------------------------------------------------ 改前
module tick_old (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       both_key,
    input  wire       auto_press,
    input  wire       rgb_vs,
    output reg        freeze_on,
    output reg  [1:0] replay_idx,
    output reg  [1:0] rp_arm,
    output reg  [7:0] hold_frm,
    output wire       auto_step
);
    wire frz_tog = (hold_frm == 8'd48) && rgb_vs;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )                             hold_frm <= 8'd0;
      else if( !both_key )                     hold_frm <= 8'd0;
      else if( rgb_vs && hold_frm != 8'd255 )  hold_frm <= hold_frm + 8'd1;
    end
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )      freeze_on <= 1'b0;
      else if( frz_tog ) freeze_on <= ~freeze_on;
    end
    reg auto_play;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )          auto_play <= 1'b0;
      else if( !freeze_on ) auto_play <= 1'b0;
      else if( auto_press ) auto_play <= ~auto_play;
    end
    localparam [7:0] PLAY_DIV = 8'd6;
    reg  [7:0] play_cnt;
    wire       play_vs   = rgb_vs;
    wire       play_tick = (play_cnt == (PLAY_DIV - 8'd1));
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )                    play_cnt <= 8'd0;
      else if( !freeze_on || !auto_play ) play_cnt <= 8'd0;
      else if( play_vs )              play_cnt <= play_tick ? 8'd0 : play_cnt + 8'd1;
    end
    assign auto_step = auto_play && freeze_on && play_vs && play_tick;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )       replay_idx <= 2'd0;
      else if( !freeze_on )  replay_idx <= 2'd0;
      else if( auto_step )   replay_idx <= (replay_idx == 2'd2) ? 2'd0 : replay_idx + 2'd1;
    end
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )                           rp_arm <= 2'd0;
      else if( !freeze_on )                  rp_arm <= 2'd0;
      else if( rgb_vs && (rp_arm != 2'd2) )  rp_arm <= rp_arm + 2'd1;
    end
endmodule

//------------------------------------------------------------------ 改后
module tick_new (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       both_key,
    input  wire       auto_press,
    input  wire       rgb_vs,
    output reg        freeze_on,
    output reg  [1:0] replay_idx,
    output reg  [1:0] rp_arm,
    output reg  [7:0] hold_frm,
    output wire       auto_step
);
    // ---- 边沿检测：rgb_vs 来自 data_tx 的 S_V_SYNC 状态，是持续 VSP=5 行的电平 ----
    reg rgb_vs_d;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n ) rgb_vs_d <= 1'b0;
      else         rgb_vs_d <= rgb_vs;
    end
    wire rgb_vs_rise = rgb_vs & ~rgb_vs_d;

    // 第 48 个帧沿触发：这一拍 hold_frm 还是 47（本拍才 +1），所以判 47
    wire frz_tog = (hold_frm == 8'd47) && rgb_vs_rise;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )                                  hold_frm <= 8'd0;
      else if( !both_key )                          hold_frm <= 8'd0;
      else if( rgb_vs_rise && hold_frm != 8'd255 )  hold_frm <= hold_frm + 8'd1;
    end
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )      freeze_on <= 1'b0;
      else if( frz_tog ) freeze_on <= ~freeze_on;
    end
    reg auto_play;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )          auto_play <= 1'b0;
      else if( !freeze_on ) auto_play <= 1'b0;
      else if( auto_press ) auto_play <= ~auto_play;
    end
    localparam [7:0] PLAY_DIV = 8'd6;
    reg  [7:0] play_cnt;
    wire       play_vs   = rgb_vs_rise;
    wire       play_tick = (play_cnt == (PLAY_DIV - 8'd1));
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )                    play_cnt <= 8'd0;
      else if( !freeze_on || !auto_play ) play_cnt <= 8'd0;
      else if( play_vs )              play_cnt <= play_tick ? 8'd0 : play_cnt + 8'd1;
    end
    assign auto_step = auto_play && freeze_on && play_vs && play_tick;
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )       replay_idx <= 2'd0;
      else if( !freeze_on )  replay_idx <= 2'd0;
      else if( auto_step )   replay_idx <= (replay_idx == 2'd2) ? 2'd0 : replay_idx + 2'd1;
    end
    always @( posedge clk or negedge rst_n ) begin
      if( !rst_n )                               rp_arm <= 2'd0;
      else if( !freeze_on )                      rp_arm <= 2'd0;
      else if( rgb_vs_rise && (rp_arm != 2'd2) ) rp_arm <= rp_arm + 2'd1;
    end
endmodule

//------------------------------------------------------------------ 激励
module tb_vs_tick;
    localparam integer LINE_CLK   = 11;      // 真实 1100；仿真按等比缩小（结论与拍数无关）
    localparam integer FRAME_LINE = 112;     // 真实 1125
    localparam integer VS_LINES   = 5;
    localparam integer NFRAME     = 62;
    localparam real    TCLK       = 13.468;
    localparam real    FRAME_NS   = 1.0 * LINE_CLK * FRAME_LINE * 13.468;   // ns（缩放后）
    localparam real    FRAME_CYC  = 1.0 * LINE_CLK * FRAME_LINE;            // 拍

    reg clk = 1'b0;
    always #(13.468/2.0) clk = ~clk;
    reg rst_n = 1'b0;

    reg both_key = 1'b0;
    reg rgb_vs = 1'b0;
    reg ap_old = 1'b0, ap_new = 1'b0;

    wire        frz_o, frz_n;
    wire [1:0]  idx_o, idx_n, arm_o, arm_n;
    wire [7:0]  hold_o, hold_n;
    wire        step_o, step_n;

    tick_old u_old (.clk(clk), .rst_n(rst_n), .both_key(both_key), .auto_press(ap_old),
        .rgb_vs(rgb_vs), .freeze_on(frz_o), .replay_idx(idx_o), .rp_arm(arm_o),
        .hold_frm(hold_o), .auto_step(step_o));
    tick_new u_new (.clk(clk), .rst_n(rst_n), .both_key(both_key), .auto_press(ap_new),
        .rgb_vs(rgb_vs), .freeze_on(frz_n), .replay_idx(idx_n), .rp_arm(arm_n),
        .hold_frm(hold_n), .auto_step(step_n));

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // 冻结后自动按一次 KEY1（两版各自按自己的 freeze 边沿，激励等价）
    reg fq_o = 1'b0, fq_n = 1'b0;
    always @(posedge clk) begin
        fq_o <= frz_o;  fq_n <= frz_n;
        ap_old <= (frz_o & ~fq_o);
        ap_new <= (frz_n & ~fq_n);
    end

    integer c_frz_o = -1, c_frz_n = -1, c_arm_o = -1, c_arm_n = -1;
    integer n_step_o = 0, n_step_n = 0;
    integer c_s1_o = -1, c_s2_o = -1, c_s1_n = -1, c_s2_n = -1;

    always @(posedge clk) begin
        if (frz_o && c_frz_o < 0) c_frz_o = cyc;
        if (frz_n && c_frz_n < 0) c_frz_n = cyc;
        if (arm_o == 2'd2 && c_arm_o < 0) c_arm_o = cyc;
        if (arm_n == 2'd2 && c_arm_n < 0) c_arm_n = cyc;
        if (step_o) begin
            n_step_o = n_step_o + 1;
            if (c_s1_o < 0) c_s1_o = cyc; else c_s2_o = cyc;
        end
        if (step_n) begin
            n_step_n = n_step_n + 1;
            if (c_s1_n < 0) c_s1_n = cyc; else c_s2_n = cyc;
        end
    end

    integer k, f;
    real int_o, int_n;
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (4) @(posedge clk);

        both_key = 1'b1;
        for (f = 0; f < NFRAME; f = f + 1)
            for (k = 0; k < FRAME_LINE*LINE_CLK; k = k + 1) begin
                rgb_vs = (k < VS_LINES*LINE_CLK);   // vs 高 5 行 = 5500 拍
                @(posedge clk); #1;
            end

        // 平均步进间隔 = (末次 - 首次) / (次数 - 1)
        int_o = (n_step_o > 1) ? (1.0*(c_s2_o - c_s1_o))/(n_step_o-1) : 0.0;
        int_n = (n_step_n > 1) ? (1.0*(c_s2_n - c_s1_n))/(n_step_n-1) : 0.0;

        $display("");
        $display("======================================================================");
        $display(" P1-1  rgb_vs 当脉冲 vs 加边沿检测   %0d 帧（1125 行/帧, 1100 拍/行, vs 高 %0d 行）",
                 NFRAME, VS_LINES);
        $display("======================================================================");
        $display("                                  改前(rgb_vs)          改后(rgb_vs_rise)");
        $display("  freeze_on 首次翻转        : %8d 拍           %8d 拍", c_frz_o, c_frz_n);
        $display("  折合帧数                  : %8.4f               %8.2f", 
                 c_frz_o/FRAME_CYC, c_frz_n/FRAME_CYC);
        $display("  真实时间                  : %8.3f us            %8.3f us",
                 c_frz_o*TCLK/1000.0, c_frz_n*TCLK/1000.0);
        $display("  rp_arm 到 2               : %8d 拍           %8d 拍", c_arm_o, c_arm_n);
        $display("  折合帧数                  : %8.4f               %8.2f",
                 c_arm_o/FRAME_CYC, c_arm_n/FRAME_CYC);
        $display("  auto_step 次数            : %8d               %8d", n_step_o, n_step_n);
        $display("  auto_step 平均间隔        : %8.1f 拍           %8.1f 拍", int_o, int_n);
        $display("  折合帧数                  : %8.4f               %8.3f", 
                 int_o/FRAME_CYC, int_n/FRAME_CYC);
        $display("----------------------------------------------------------------------");
        $display("  期望：freeze = 48 个帧沿；rp_arm 冻结后 2 帧；auto_step 间隔 6 帧(10fps)");
        $display("  真实时间折算：改前 48 拍 = %.2f us；改后 48 帧 x 16.674ms = %.2f ms", 48.0*TCLK/1000.0, 48.0*16.674);
        if (c_frz_o >= 0 && c_frz_o < 200 &&
            c_frz_n > 47*FRAME_CYC && c_frz_n < 49*FRAME_CYC &&
            int_n > 5.5*FRAME_CYC && int_n < 6.5*FRAME_CYC)
            $display("  RESULT: PASS —— 改前 48 拍就翻转/每 6 拍步进；改后 48 帧/每 6 帧");
        else
            $display("  RESULT: CHECK —— 数值不在预期区间");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #2_500_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end
endmodule
