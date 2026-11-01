//==============================================================================
// tb_shape_math.v —— shape_math 串行乘除引擎定向对拍（P0-1 回归）
//
//   直接给统计量，绕过像素通路，专门打除法器位宽：
//     1/16 采样后 A 上限 65530 → 除数 A² 最大 4.29e9 > 2^31
//     旧实现 rem[30:0] + b[30:0] → A² > 2^30 就开始错（商偏大 / 直接为 0）
//
//   每个用例比对：a2 / m20 / m02 / m11 / LQ / W / circ / rect / cls
//   期望值由 sim/gen_shape_math_cases.py 用 Python 大整数精确算出，
//   同时给出「旧实现（31bit 余数 + b[30:0]）会算成什么」，用于确认 tb 能抓到这个 bug。
//
//   运行（在 v6_edge 根目录）：
//     iverilog -g2012 -I sim -s tb_shape_math -o sim/tb_shape_math.vvp \
//              sim/tb_shape_math.v rtl/edge/shape_recog.v
//     vvp sim/tb_shape_math.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_shape_math;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg         i_start = 1'b0;
    reg  [15:0] i_area  = 16'd0;
    reg  [26:0] i_sx    = 27'd0;
    reg  [26:0] i_sy    = 27'd0;
    reg  [37:0] i_sxx   = 38'd0;
    reg  [36:0] i_syy   = 37'd0;
    reg  [37:0] i_sxy   = 38'd0;

    wire [1:0] o_cls;
    wire       o_done;

    shape_math dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_start (i_start),
        .i_area  (i_area),
        .i_sx    (i_sx),
        .i_sy    (i_sy),
        .i_sxx   (i_sxx),
        .i_syy   (i_syy),
        .i_sxy   (i_sxy),
        .o_cls   (o_cls),
        .o_done  (o_done)
    );

    `include "shape_math_cases.vh"

    // RTL 里的 rect 是"乘后比较"，这里重建比较右操作数（显式扩到 56bit，避免 32bit 截断）
    wire [55:0] rect_r = {24'd0, dut.a2} * 56'd125112;
    wire        dut_rect = (dut.lq <= rect_r);

    integer errs = 0;
    integer cyc  = 0;

    //--------------------------------------------------------------------------
    task run_case(input integer k);
        integer n;
        begin
            i_area = c_area[k];
            i_sx   = c_sx[k];
            i_sy   = c_sy[k];
            i_sxx  = c_sxx[k];
            i_syy  = c_syy[k];
            i_sxy  = c_sxy[k];
            @(posedge clk); #1;
            i_start = 1'b1;
            @(posedge clk); #1;
            i_start = 1'b0;

            n = 0;
            while (!o_done && n < 4000) begin
                @(negedge clk);
                n = n + 1;
            end
            cyc = n;
            if (!o_done) begin
                $display("  case %0d : TIMEOUT waiting o_done", k);
                errs = errs + 1;
            end
        end
    endtask

    task check(input integer k);
        integer e;
        begin
            e = 0;
            if (dut.a2  !== c_a2[k])  begin $display("    MISMATCH a2  got %0d exp %0d", dut.a2,  c_a2[k]);  e = e + 1; end
            if (dut.m20 !== c_m20[k]) begin $display("    MISMATCH m20 got %0d exp %0d (old-impl would give %0d)", dut.m20, c_m20[k], c_bm20[k]); e = e + 1; end
            if (dut.m02 !== c_m02[k]) begin $display("    MISMATCH m02 got %0d exp %0d (old-impl would give %0d)", dut.m02, c_m02[k], c_bm02[k]); e = e + 1; end
            if (dut.m11 !== c_m11[k]) begin $display("    MISMATCH m11 got %0d exp %0d (old-impl would give %0d)", dut.m11, c_m11[k], c_bm11[k]); e = e + 1; end
            if (dut.lq  !== c_lq[k])  begin $display("    MISMATCH lq  got %0d exp %0d", dut.lq,  c_lq[k]);  e = e + 1; end
            if (dut.w   !== c_w[k])   begin $display("    MISMATCH w   got %0d exp %0d", dut.w,   c_w[k]);   e = e + 1; end
            if (dut.circ !== c_circ[k]) begin $display("    MISMATCH circ got %0d exp %0d", dut.circ, c_circ[k]); e = e + 1; end
            if (dut_rect !== c_rect[k]) begin $display("    MISMATCH rect got %0d exp %0d", dut_rect, c_rect[k]); e = e + 1; end
            if (o_cls !== c_cls[k])   begin $display("    MISMATCH cls got %0d exp %0d", o_cls, c_cls[k]); e = e + 1; end

            errs = errs + e;
            $display("  case %0d : A=%6d A2=%10d %s  m20=%0d  cls=%0d  (%0d cyc)  %s",
                     k, c_area[k], c_a2[k],
                     (c_a2[k] > 32'd2147483648) ? "A2>2^31" : "A2<2^31",
                     dut.m20, o_cls, cyc, (e == 0) ? "PASS" : "FAIL");
        end
    endtask

    //--------------------------------------------------------------------------
    integer k;
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) begin @(posedge clk); #1; end

        $display("");
        $display("======================================================================");
        $display(" shape_math 定向对拍  (%0d cases)   A^2 跨越 2^31 = 2147483648", SM_NCASES);
        $display("======================================================================");
        for (k = 0; k < SM_NCASES; k = k + 1) begin
            run_case(k);
            check(k);
        end
        $display("----------------------------------------------------------------------");
        if (errs == 0)
            $display(" RESULT: ALL PASS  (%0d cases x 9 items)", SM_NCASES);
        else
            $display(" RESULT: %0d ERROR(S)", errs);
        $display("======================================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
