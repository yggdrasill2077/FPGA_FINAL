// tb_w1_shape.v —— shape_recog W1（白底）对拍测试平台
//   与 sim/tb_shape_recog.v 同构，但：
//     * 激励/金标准改为 sim/w1_frames.hex + sim/w1_expect.vh（白底、fg=gray<TY）
//     * 不再检查 W（RTL 已改为"乘后比较"，w 仅残留寄存器）
//   运行：
//     iverilog -g2012 -I sim -s tb_w1_shape -o sim/tb_w1_shape.vvp \
//              sim/tb_w1_shape.v rtl/edge/shape_recog.v
//     vvp sim/tb_w1_shape.vvp
`timescale 1ns/1ps
module tb_w1_shape;

    localparam integer HP = 120;
    localparam integer VL = 160;
    localparam integer PIX_PER_FRAME = HP * 2 * VL;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        i_de = 1'b0;
    reg        i_vs = 1'b0;
    reg  [7:0] i_g0 = 8'd0;
    reg  [7:0] i_g1 = 8'd0;

    wire [1:0]  o_cls;
    wire        o_upd;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire        o_box_en;
    wire [3:0]  o_best_idx;
    wire [13:0] o_best_cnt;

    shape_recog #(
        .H_PAIRS  (HP),
        .V_LINES  (VL)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .i_de      (i_de),
        .i_vs      (i_vs),
        .i_g0      (i_g0),
        .i_g1      (i_g1),
        .o_cls     (o_cls),
        .o_upd     (o_upd),
        .o_bx0     (o_bx0),
        .o_bx1     (o_bx1),
        .o_by0     (o_by0),
        .o_by1     (o_by1),
        .o_box_en  (o_box_en),
        .o_best_idx(o_best_idx),
        .o_best_cnt(o_best_cnt)
    );

    `include "w1_expect.vh"

    reg [7:0] img [0:SHAPE_NFRAMES*PIX_PER_FRAME-1];
    integer errs = 0;
    integer cyc  = 0;

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

    wire [32:0] dut_tr   = {1'b0, dut.u_math.m20} + {1'b0, dut.u_math.m02};
    wire [55:0] dut_recr = {24'd0, dut.u_math.a2} * 56'd125112;
    wire        dut_rect = (dut.u_math.lq <= dut_recr);

    task check(input integer f);
        integer e;
        begin
            e = 0;
            if (dut.s_area !== exp_a[f])   begin $display("    MISMATCH area got %0d exp %0d", dut.s_area, exp_a[f]); e=e+1; end
            if (dut.s_sx   !== exp_sx[f])  begin $display("    MISMATCH sx   got %0d exp %0d", dut.s_sx,   exp_sx[f]);  e=e+1; end
            if (dut.s_sy   !== exp_sy[f])  begin $display("    MISMATCH sy   got %0d exp %0d", dut.s_sy,   exp_sy[f]);  e=e+1; end
            if (dut.s_sxx  !== exp_sxx[f]) begin $display("    MISMATCH sxx  got %0d exp %0d", dut.s_sxx,  exp_sxx[f]); e=e+1; end
            if (dut.s_syy  !== exp_syy[f]) begin $display("    MISMATCH syy  got %0d exp %0d", dut.s_syy,  exp_syy[f]); e=e+1; end
            if (dut.s_sxy  !== exp_sxy[f]) begin $display("    MISMATCH sxy  got %0d exp %0d", dut.s_sxy,  exp_sxy[f]); e=e+1; end
            // A=0（空场景）时除数 a2=0，除法器输出饱和值 → m20/m02/m11/tr/rect 为 don't-care；
            // 类别由 A_MIN 门控强制为 0，功能上无影响
            if (exp_a[f] != 0) begin
                if (dut.u_math.a2  !== exp_a2[f])  begin $display("    MISMATCH a2  got %0d exp %0d", dut.u_math.a2,  exp_a2[f]);  e=e+1; end
                if (dut.u_math.m20 !== exp_m20[f]) begin $display("    MISMATCH m20 got %0d exp %0d", dut.u_math.m20, exp_m20[f]); e=e+1; end
                if (dut.u_math.m02 !== exp_m02[f]) begin $display("    MISMATCH m02 got %0d exp %0d", dut.u_math.m02, exp_m02[f]); e=e+1; end
                if (dut.u_math.m11 !== exp_m11[f]) begin $display("    MISMATCH m11 got %0d exp %0d", dut.u_math.m11, exp_m11[f]); e=e+1; end
                if (dut_tr        !== exp_tr[f])   begin $display("    MISMATCH tr  got %0d exp %0d", dut_tr,        exp_tr[f]);   e=e+1; end
                if (dut.u_math.lq !== exp_LQ[f])   begin $display("    MISMATCH lq  got %0d exp %0d", dut.u_math.lq, exp_LQ[f]);   e=e+1; end
                if (dut.u_math.circ !== exp_circ[f]) begin $display("    MISMATCH circ got %0d exp %0d", dut.u_math.circ, exp_circ[f]); e=e+1; end
                if (dut_rect      !== exp_rect[f]) begin $display("    MISMATCH rect got %0d exp %0d", dut_rect,      exp_rect[f]); e=e+1; end
            end
            // 类别检查已移出：分类决策改由 u_tmpl（64 例 tb_shape_tmpl 覆盖 1/2/3/4 类）

            errs = errs + e;
            $display("  frame %0d : A=%0d bbox=(%0d,%0d,%0d,%0d) m20=%0d m02=%0d m11=%0d tr=%0d LQ=%0d circ=%0d rect=%0d best_idx=%0d best_cnt=%0d box_en=%0d cls=%0d  %s  (%0d cyc)",
                     f, dut.s_area, dut.s_bx0, dut.s_bx1, dut.s_by0, dut.s_by1,
                     dut.u_math.m20, dut.u_math.m02, dut.u_math.m11, dut_tr, dut.u_math.lq,
                     dut.u_math.circ, dut_rect, o_best_idx, o_best_cnt, o_box_en, o_cls,
                     (e == 0) ? "PASS" : "FAIL", cyc);
        end
    endtask

    integer f;
    initial begin
        $readmemh("sim/w1_frames.hex", img);
        if (^img[0] === 1'bx) begin
            $display("ERROR: w1_frames.hex not loaded");
            $finish;
        end

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (10) begin @(posedge clk); #1; end

        $display("");
        $display("======================================================================");
        $display(" shape_recog W1 对拍（白底 fg=gray<TY)  %0d frames  %0dx%0d", SHAPE_NFRAMES, HP*2, VL);
        $display("======================================================================");

        send_vs();
        wait_done();

        for (f = 0; f < SHAPE_NFRAMES; f = f + 1) begin
            send_frame(f);
            send_vs();
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

    initial begin
        #50_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
