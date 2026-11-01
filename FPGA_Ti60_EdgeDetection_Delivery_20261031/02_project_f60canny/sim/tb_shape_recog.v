//==============================================================================
// tb_shape_recog.v —— shape_recog 对拍测试平台
//
//   小帧 240x160（H_PAIRS=120, V_LINES=160），7 帧：
//     圆 / 方 / 三角 / 长矩 / 超小(面积<150) / 超大(面积>30720) / 靠角的圆
//   像素与期望值都由 sim/gen_shape_frames.py 生成，保证两边看到的是同一份掩膜。
//
//   逐项比对（16 项）：A / Σx / Σy / Σxx / Σyy / Σxy / A² / m20 / m02 / m11 / tr / LQ / W
//             / circ / rect / cls
//   其中 tr 与 rect 在 RTL 里不是寄存器（tr 是判圆时的一级加法、rect 是乘后比较），
//   这里用层次引用的组合式重建，保证「金标准里的 16 个量」每一项都有 RTL 对应物。
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -I sim -s tb_shape_recog -o sim/tb_shape_recog.vvp \
//              sim/tb_shape_recog.v rtl/edge/shape_recog.v
//     vvp sim/tb_shape_recog.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_shape_recog;

    localparam integer HP = 120;          // 行内像素对数
    localparam integer VL = 160;          // 行数
    localparam integer PIX_PER_FRAME = HP * 2 * VL;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        i_de = 1'b0;
    reg        i_vs = 1'b0;
    reg  [7:0] i_g0 = 8'd0;
    reg  [7:0] i_g1 = 8'd0;

    wire [1:0] o_cls;
    wire       o_upd;

    shape_recog #(
        .H_PAIRS  (HP),
        .V_LINES  (VL),
        .THRESH   (8'd128),
        .POLARITY (1'b0)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .i_de  (i_de),
        .i_vs  (i_vs),
        .i_g0  (i_g0),
        .i_g1  (i_g1),
        .o_cls (o_cls),
        .o_upd (o_upd)
    );

    //--------------------------------------------------------------------------
    // 金标准（由 gen_shape_frames.py 生成；含 SHAPE_NFRAMES 与 exp_* 数组）
    //--------------------------------------------------------------------------
    `include "shape_expect.vh"

    reg [7:0] img [0:SHAPE_NFRAMES*PIX_PER_FRAME-1];

    integer errs = 0;
    integer cyc  = 0;

    //--------------------------------------------------------------------------
    // 激励：所有输入都在时钟沿之后 1ns 才改变，避免与 DUT 采样竞争
    //--------------------------------------------------------------------------
    task send_vs;
        begin
            i_de = 1'b0;
            i_vs = 1'b1;
            repeat (3) begin @(posedge clk); #1; end
            i_vs = 1'b0;
            repeat (3) begin @(posedge clk); #1; end
        end
    endtask

    task send_frame(input integer f);
        integer r, c;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = img[f*PIX_PER_FRAME + r*(HP*2) + 2*c];
                    i_g1 = img[f*PIX_PER_FRAME + r*(HP*2) + 2*c + 1];
                    @(posedge clk); #1;
                end
                i_de = 1'b0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (2) begin @(posedge clk); #1; end
            end
            repeat (8) begin @(posedge clk); #1; end
        end
    endtask

    // 等 o_upd（类别更新脉冲），同时统计数学引擎拍了多少拍
    task wait_done;
        integer n;
        begin
            n = 0;
            while (!o_upd && n < 20000) begin
                @(negedge clk);
                n = n + 1;
            end
            cyc = n;
            if (!o_upd) begin
                $display("  ERROR: timeout waiting o_upd (n=%0d)", n);
                errs = errs + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // RTL 里的两个"非寄存器"量：tr = m20+m02（扩展 1 位），rect = (LQ <= 125112·A²)
    //   a2 是 32bit、125112 是 17bit，直接相乘会按 32bit 截断，必须显式扩到 56bit
    //--------------------------------------------------------------------------
    wire [32:0] dut_tr   = {1'b0, dut.u_math.m20} + {1'b0, dut.u_math.m02};
    wire [55:0] dut_recr = {24'd0, dut.u_math.a2} * 56'd125112;
    wire        dut_rect = (dut.u_math.lq <= dut_recr);

    //--------------------------------------------------------------------------
    task check(input integer f);
        integer e;
        begin
            e = 0;
            if (dut.s_area !== exp_a[f])   begin $display("    MISMATCH area  got %0d exp %0d", dut.s_area,  exp_a[f]);  e = e + 1; end
            if (dut.s_sx   !== exp_sx[f])  begin $display("    MISMATCH sx    got %0d exp %0d", dut.s_sx,    exp_sx[f]); e = e + 1; end
            if (dut.s_sy   !== exp_sy[f])  begin $display("    MISMATCH sy    got %0d exp %0d", dut.s_sy,    exp_sy[f]); e = e + 1; end
            if (dut.s_sxx  !== exp_sxx[f]) begin $display("    MISMATCH sxx   got %0d exp %0d", dut.s_sxx,   exp_sxx[f]); e = e + 1; end
            if (dut.s_syy  !== exp_syy[f]) begin $display("    MISMATCH syy   got %0d exp %0d", dut.s_syy,   exp_syy[f]); e = e + 1; end
            if (dut.s_sxy  !== exp_sxy[f]) begin $display("    MISMATCH sxy   got %0d exp %0d", dut.s_sxy,   exp_sxy[f]); e = e + 1; end
            if (dut.u_math.a2  !== exp_a2[f])  begin $display("    MISMATCH a2   got %0d exp %0d", dut.u_math.a2,  exp_a2[f]);  e = e + 1; end
            if (dut.u_math.m20 !== exp_m20[f]) begin $display("    MISMATCH m20  got %0d exp %0d", dut.u_math.m20, exp_m20[f]); e = e + 1; end
            if (dut.u_math.m02 !== exp_m02[f]) begin $display("    MISMATCH m02  got %0d exp %0d", dut.u_math.m02, exp_m02[f]); e = e + 1; end
            if (dut.u_math.m11 !== exp_m11[f]) begin $display("    MISMATCH m11  got %0d exp %0d", dut.u_math.m11, exp_m11[f]); e = e + 1; end
            if (dut_tr        !== exp_tr[f])   begin $display("    MISMATCH tr   got %0d exp %0d", dut_tr,        exp_tr[f]);   e = e + 1; end
            if (dut.u_math.lq  !== exp_LQ[f])  begin $display("    MISMATCH lq   got %0d exp %0d", dut.u_math.lq,  exp_LQ[f]);  e = e + 1; end
            if (dut.u_math.w   !== exp_w[f])   begin $display("    MISMATCH w    got %0d exp %0d", dut.u_math.w,   exp_w[f]);   e = e + 1; end
            if (dut.u_math.circ !== exp_circ[f]) begin $display("    MISMATCH circ got %0d exp %0d", dut.u_math.circ, exp_circ[f]); e = e + 1; end
            if (dut_rect      !== exp_rect[f]) begin $display("    MISMATCH rect got %0d exp %0d", dut_rect,      exp_rect[f]); e = e + 1; end
            if (o_cls !== exp_cls[f]) begin $display("    MISMATCH cls  got %0d exp %0d", o_cls, exp_cls[f]); e = e + 1; end

            errs = errs + e;
            $display("  frame %0d : A=%0d m20=%0d m02=%0d m11=%0d tr=%0d LQ=%0d W=%0d circ=%0d rect=%0d cls=%0d  %s  (%0d cyc)",
                     f, dut.s_area, dut.u_math.m20, dut.u_math.m02, dut.u_math.m11,
                     dut_tr, dut.u_math.lq, dut.u_math.w, dut.u_math.circ, dut_rect, o_cls,
                     (e == 0) ? "PASS" : "FAIL", cyc);
        end
    endtask

    //--------------------------------------------------------------------------
    integer f;
    initial begin
        $readmemh("sim/shape_frames.hex", img);
        if (^img[0] === 1'bx) begin
            $display("ERROR: shape_frames.hex not loaded");
            $finish;
        end

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (10) begin @(posedge clk); #1; end

        $display("");
        $display("======================================================================");
        $display(" shape_recog 对拍  (%0d frames, %0dx%0d, %0d px/frame)", SHAPE_NFRAMES, HP*2, VL, PIX_PER_FRAME);
        $display("======================================================================");

        send_vs();                       // 清空统计并触发一次空帧数学（结果丢弃）
        wait_done();

        for (f = 0; f < SHAPE_NFRAMES; f = f + 1) begin
            send_frame(f);
            send_vs();                   // 触发第 f 帧的数学引擎
            wait_done();
            check(f);
        end

        $display("----------------------------------------------------------------------");
        if (errs == 0)
            $display(" RESULT: ALL PASS  (%0d frames)", SHAPE_NFRAMES);
        else
            $display(" RESULT: %0d ERROR(S)", errs);
        $display("======================================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
