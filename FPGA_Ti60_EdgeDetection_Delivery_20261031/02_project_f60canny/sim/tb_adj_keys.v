//==============================================================================
// tb_adj_keys.v —— 顶层"补偿值按键微调"逻辑的定向自检（force 内部消抖脉冲）
//
//   为什么用 force：
//     板上按键的 20ms 消抖要跑 1.5M 个 74.25MHz 周期，全设计仿真的代价太大；
//     Key 消抖本身是既有模块（key_debounce），这里只验证新增的映射逻辑：
//       KEY2 短按 → xoff += 2（62→0） / KEY1 短按 → yoff += 1（31→0）
//       KEY1+KEY2 同按 → 22 / 3 / 冻结态不响应 / 跨域同步
//   所以直接 force 顶层内部已消抖的单拍脉冲 key2_press / auto_press /
//   adj_both_press，以及 freeze_on / 复位。
//
//   依赖：iverilog 不能编译厂家加密 IP，编译时需带 sim/ip_stubs_for_iverilog.v
//   （见 sim/run_adjust_checks.ps1）。本 TB 只跑几百个时钟，输出波形不用 dump。
//==============================================================================
`timescale 1ns/1ps

module tb_adj_keys;

    // ---------------- 时钟 ----------------
    reg core_clk      = 1'b0;   // 100 MHz
    reg vid_clk       = 1'b0;   // 74.25 MHz（= vid_clk_dvi2 / hdmi_tx_slow_clk）
    reg mipi_pclk     = 1'b0;
    reg clk5m         = 1'b0;
    reg clk25m        = 1'b0;

    // 按键原脚（低有效，默认松开）——只用于检查"两键同按"合成键的真值表
    reg key2_n        = 1'b1;   // KEY2 @GPIOR_21
    reg key1_n        = 1'b1;   // KEY1 @GPIOR_22

    always #5.000  core_clk  = ~core_clk;
    always #6.734  vid_clk   = ~vid_clk;
    always #6.734  mipi_pclk = ~mipi_pclk;
    always #100.0  clk5m     = ~clk5m;
    always #20.0   clk25m    = ~clk25m;

    // ---------------- 顶层例化（只连需要的输入，其余悬空） ----------------
    ti60f225_oob_top dut (
        .i_arstn             (1'b1),
        .i_key0_n            (1'b1),
        .i_key1_n            (1'b1),
        .i_key2_n            (key2_n),
        .i_auto_n            (key1_n),
        .i_pll_locked        (1'b1),
        .pll_locked          (1'b1),
        .pll_inst4_LOCKED    (1'b1),
        .user_pll_locked     (1'b1),
        .core_clk            (core_clk),
        .vid_clk_dvi2        (vid_clk),
        .hdmi_tx_slow_clk    (vid_clk),
        .i_mipi_rx_pclk      (mipi_pclk),
        .i_mipi_tx_pclk      (mipi_pclk),
        .CLK_5M              (clk5m),
        .CLK_25M             (clk25m),
        .sdram_clk           (1'b0),
        .tx_cal_clk          (1'b0),
        .rx_cal_clk          (1'b0),
        .tx_cal_clk_90edge   (1'b0),
        .i_cam_ck_CLKOUT     (1'b0)
    );

    integer errors = 0;

    task chk_x;
        input [5:0] exp;
        begin
            if (dut.osd_xoff_r !== exp) begin
                $display("  FAIL: xoff = %0d, expect %0d (t=%0t)", dut.osd_xoff_r, exp, $time);
                errors = errors + 1;
            end
        end
    endtask

    task chk_y;
        input [4:0] exp;
        begin
            if (dut.osd_yoff_r !== exp) begin
                $display("  FAIL: yoff = %0d, expect %0d (t=%0t)", dut.osd_yoff_r, exp, $time);
                errors = errors + 1;
            end
        end
    endtask

    // 一个 vid 周期宽的 force 脉冲（跨过至少一个 posedge vid_clk）
    task pulse_x;                       // KEY2 短按
        begin
            @(negedge vid_clk); force dut.key2_press = 1'b1;
            @(negedge vid_clk); release dut.key2_press;
            @(negedge vid_clk);
        end
    endtask

    task pulse_y;                       // KEY1 短按
        begin
            @(negedge vid_clk); force dut.auto_press = 1'b1;
            @(negedge vid_clk); release dut.auto_press;
            @(negedge vid_clk);
        end
    endtask

    task pulse_both;                    // KEY1+KEY2 同按
        begin
            @(negedge vid_clk); force dut.adj_both_press = 1'b1;
            @(negedge vid_clk); release dut.adj_both_press;
            @(negedge vid_clk);
        end
    endtask

    integer i;

    initial begin
        // 绕过板级 PLL / 复位计数（否则 vid_rst_n 要等 2^27 拍）
        // 先真正拉低复位两个 vid 拍，让新增寄存器进默认值，再释放
        force dut.w_arstn   = 1'b1;
        force dut.vid_rst_n = 1'b0;
        force dut.freeze_on = 1'b0;
        @(negedge vid_clk); @(negedge vid_clk);
        release dut.vid_rst_n;
        force dut.vid_rst_n = 1'b1;
        #200;

        $display("==============================================================");
        $display(" C) ti60f225_oob_top : key -> osd_xoff_r / osd_yoff_r");
        $display("==============================================================");

        // ---- 1. 复位默认值 ----
        chk_x(6'd22);
        chk_y(5'd3);
        $display("  reset default   : xoff=%0d yoff=%0d (expect 22/3)", dut.osd_xoff_r, dut.osd_yoff_r);

        // ---- 1b. 两键同按合成键真值表（低有效：只有 0/0 才是"按下"）----
        //         这条防的是把合成逻辑写成相与（单键按下也会触发 both → 每次都复位）
        key2_n = 1'b1; key1_n = 1'b1; #20;
        if (dut.adj_both_key_n !== 1'b1) begin $display("  FAIL: both-key (released/released) = %b", dut.adj_both_key_n); errors=errors+1; end
        key2_n = 1'b0; key1_n = 1'b1; #20;
        if (dut.adj_both_key_n !== 1'b1) begin $display("  FAIL: both-key (KEY2 only) = %b", dut.adj_both_key_n); errors=errors+1; end
        key2_n = 1'b1; key1_n = 1'b0; #20;
        if (dut.adj_both_key_n !== 1'b1) begin $display("  FAIL: both-key (KEY1 only) = %b", dut.adj_both_key_n); errors=errors+1; end
        key2_n = 1'b0; key1_n = 1'b0; #20;
        if (dut.adj_both_key_n !== 1'b0) begin $display("  FAIL: both-key (both pressed) = %b", dut.adj_both_key_n); errors=errors+1; end
        key2_n = 1'b1; key1_n = 1'b1; #20;
        $display("  both-key truth  : released/single/single/both = 1/1/1/0 OK");

        // ---- 2. 单次 +2 / +1 ----
        pulse_x; chk_x(6'd24);
        pulse_y; chk_y(5'd4);
        $display("  one press each  : xoff=%0d yoff=%0d (expect 24/4)", dut.osd_xoff_r, dut.osd_yoff_r);

        // ---- 3. 同按恢复默认 ----
        pulse_both;
        chk_x(6'd22); chk_y(5'd3);
        $display("  both pressed    : xoff=%0d yoff=%0d (expect 22/3)", dut.osd_xoff_r, dut.osd_yoff_r);

        // ---- 3b. 最坏时序：两键的真实按下时刻差 < 1 拍，后按那个键的 press
        //          与 adj_both_press 同拍。此时 both 分支必须优先，不能残留 +2/+1 ----
        pulse_x; pulse_y;                       // 先做成 24/4
        @(negedge vid_clk);
        force dut.key2_press = 1'b1;
        force dut.auto_press = 1'b1;
        force dut.adj_both_press = 1'b1;
        @(negedge vid_clk);
        release dut.key2_press;
        release dut.auto_press;
        release dut.adj_both_press;
        @(negedge vid_clk);
        chk_x(6'd22); chk_y(5'd3);
        $display("  both same-cycle : xoff=%0d yoff=%0d (expect 22/3)", dut.osd_xoff_r, dut.osd_yoff_r);

        // ---- 4. xoff 回绕：22 + 2*20 = 62，再来一次 → 0 ----
        for (i = 0; i < 20; i = i + 1) pulse_x;
        chk_x(6'd62);
        $display("  xoff after 20   : %0d (expect 62)", dut.osd_xoff_r);
        pulse_x;
        chk_x(6'd0);
        $display("  xoff wrap       : %0d (expect 0)", dut.osd_xoff_r);

        // ---- 5. yoff 回绕：3 + 28 = 31，再来一次 → 0 ----
        for (i = 0; i < 28; i = i + 1) pulse_y;
        chk_y(5'd31);
        $display("  yoff after 28   : %0d (expect 31)", dut.osd_yoff_r);
        pulse_y;
        chk_y(5'd0);
        $display("  yoff wrap       : %0d (expect 0)", dut.osd_yoff_r);

        // ---- 6. 跨域同步：等 3 个 hdmi 时钟，xoff_sync/yoff_sync 应一致 ----
        @(negedge vid_clk); @(negedge vid_clk); @(negedge vid_clk);
        if (dut.xoff_sync !== dut.osd_xoff_r || dut.yoff_sync !== dut.osd_yoff_r) begin
            $display("  FAIL: hdmi-domain sync %0d/%0d != vid %0d/%0d",
                     dut.xoff_sync, dut.yoff_sync, dut.osd_xoff_r, dut.osd_yoff_r);
            errors = errors + 1;
        end else begin
            $display("  hdmi sync       : %0d/%0d OK", dut.xoff_sync, dut.yoff_sync);
        end

        // ---- 7. 冻结态不响应（KEY1/KEY2 在冻结态保持原回放语义）----
        force dut.freeze_on = 1'b1;
        pulse_x; pulse_y; pulse_both;
        chk_x(6'd0); chk_y(5'd0);
        $display("  frozen (ignore) : xoff=%0d yoff=%0d (expect 0/0)", dut.osd_xoff_r, dut.osd_yoff_r);
        force dut.freeze_on = 1'b0;

        // ---- 8. 复位恢复默认 ----
        force dut.vid_rst_n = 1'b0;
        @(negedge vid_clk); @(negedge vid_clk);
        release dut.vid_rst_n;
        force dut.vid_rst_n = 1'b1;
        @(negedge vid_clk);
        chk_x(6'd22); chk_y(5'd3);
        $display("  re-reset        : xoff=%0d yoff=%0d (expect 22/3)", dut.osd_xoff_r, dut.osd_yoff_r);

        $display("==============================================================");
        if (errors == 0)
            $display(" RESULT: PASS  (key mapping / wrap / reset / sync all OK)");
        else
            $display(" RESULT: FAIL  (%0d error(s))", errors);
        $display("==============================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display(" RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
