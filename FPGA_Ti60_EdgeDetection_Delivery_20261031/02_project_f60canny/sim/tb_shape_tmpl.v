//==============================================================================
// tb_shape_tmpl.v —— 64 例模板匹配验证（4 类 × 4 角度 × 2 尺度 × 2 噪声）
//
//   每例发两帧：
//     第 1 帧：建立 bbox（上一帧 bbox 从无到有）
//     第 2 帧：用第 1 帧 bbox 归一化计数并分类，检查 o_cls
//
//   运行（v6_edge 根目录）：
//     iverilog -g2012 -I sim -s tb_shape_tmpl -o sim/tb_shape_tmpl.vvp \
//              sim/tb_shape_tmpl.v rtl/edge/shape_recog.v rtl/edge/shape_tmpl.v
//     vvp sim/tb_shape_tmpl.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_shape_tmpl;

    localparam integer HP = 120;          // 240/2
    localparam integer VL = 160;
    localparam integer W  = HP * 2;
    localparam integer H  = VL;
    localparam integer PIX = W * H;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        i_de = 1'b0;
    reg        i_vs = 1'b0;
    reg  [7:0] i_g0 = 8'd0;
    reg  [7:0] i_g1 = 8'd0;

    wire [2:0] o_cls;
    wire       o_upd;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire        o_box_en;
    wire [3:0]  o_best_idx;
    wire [13:0] o_best_cnt;

    shape_recog #(
        .H_PAIRS  (HP),
        .V_LINES  (VL),
        .THAM     (256),
        .TMPL_MIN (32),
        .A_MIN    (10),
        .A_MAX    (60000)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_de       (i_de),
        .i_vs       (i_vs),
        .i_g0       (i_g0),
        .i_g1       (i_g1),
        .o_cls      (o_cls),
        .o_upd      (o_upd),
        .o_bx0      (o_bx0),
        .o_bx1      (o_bx1),
        .o_by0      (o_by0),
        .o_by1      (o_by1),
        .o_box_en   (o_box_en),
        .o_best_idx (o_best_idx),
        .o_best_cnt (o_best_cnt)
    );

    `include "shape_tmpl_expect.vh"

    reg [7:0] img [0:TMPL_NCASES*PIX-1];

    integer errs = 0;
    integer f, n;
    integer dc, ds, dt, dx;

    task send_vs;
        begin
            i_de = 1'b0;
            i_vs = 1'b1;
            repeat (3) begin @(posedge clk); #1; end
            i_vs = 1'b0;
            repeat (3) begin @(posedge clk); #1; end
        end
    endtask

    task send_frame(input integer fi);
        integer r, c;
        begin
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = img[fi*PIX + r*W + 2*c];
                    i_g1 = img[fi*PIX + r*W + 2*c + 1];
                    @(posedge clk); #1;
                end
                i_de = 1'b0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (40) begin @(posedge clk); #1; end
            end
            repeat (8) begin @(posedge clk); #1; end
        end
    endtask

    // 等模板引擎完成（~1062 拍）+ 清 RAM（1024 拍），固定 2400 拍足够
    task wait_done;
        begin
            repeat (2400) begin @(posedge clk); #1; end
        end
    endtask

    task print_dists(input integer fi);
        begin
            dc = dut.u_tmpl.hdist[0];
            if (dut.u_tmpl.hdist[1] < dc) dc = dut.u_tmpl.hdist[1];
            if (dut.u_tmpl.hdist[2] < dc) dc = dut.u_tmpl.hdist[2];
            if (dut.u_tmpl.hdist[3] < dc) dc = dut.u_tmpl.hdist[3];
            ds = dut.u_tmpl.hdist[4];
            if (dut.u_tmpl.hdist[5] < ds) ds = dut.u_tmpl.hdist[5];
            if (dut.u_tmpl.hdist[6] < ds) ds = dut.u_tmpl.hdist[6];
            if (dut.u_tmpl.hdist[7] < ds) ds = dut.u_tmpl.hdist[7];
            dt = dut.u_tmpl.hdist[8];
            if (dut.u_tmpl.hdist[9] < dt) dt = dut.u_tmpl.hdist[9];
            if (dut.u_tmpl.hdist[10] < dt) dt = dut.u_tmpl.hdist[10];
            if (dut.u_tmpl.hdist[11] < dt) dt = dut.u_tmpl.hdist[11];
            dx = dut.u_tmpl.hdist[12];
            if (dut.u_tmpl.hdist[13] < dx) dx = dut.u_tmpl.hdist[13];
            if (dut.u_tmpl.hdist[14] < dx) dx = dut.u_tmpl.hdist[14];
            if (dut.u_tmpl.hdist[15] < dx) dx = dut.u_tmpl.hdist[15];
        end
    endtask

    integer k;
    initial begin
        $readmemh("sim/shape_tmpl_frames.hex", img);
        if (^img[0] === 1'bx) begin
            $display("ERROR: shape_tmpl_frames.hex not loaded");
            $finish;
        end

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (1200) @(posedge clk);       // 等复位清 RAM 完成

        $display("");
        $display("==========================================================================================");
        $display(" shape_tmpl 64 cases  (4 classes x 4 angles x 2 scales x 2 noise)");
        $display("==========================================================================================");
        $display(" #  class     ang scale n   exp got  dmin  dc  ds  dt  dx  bw  bh  A   result");
        $display("------------------------------------------------------------------------------------------");

        for (f = 0; f < TMPL_NCASES; f = f + 1) begin
            // 第一帧：建立 bbox
            send_frame(f);
            send_vs();
            wait_done();

            // 第二帧：检查
            send_frame(f);
            send_vs();
            wait_done();

            print_dists(f);

            if (o_cls !== exp_cls[f]) begin
                errs = errs + 1;
                $display(" %2d  %-9s %3d %5d %1d   %0d   %0d  %4d  %3d %3d %3d %3d  %3d %3d %4d  FAIL",
                         f, (exp_cls[f]==1)?"circle":(exp_cls[f]==2)?"square":
                            (exp_cls[f]==3)?"triangle":"cross",
                         exp_ang[f], exp_scale[f], exp_noise[f], exp_cls[f], o_cls,
                         dut.u_tmpl.min_d_r, dc, ds, dt, dx,
                         dut.u_tmpl.bw, dut.u_tmpl.bh, dut.s_area);
            end else begin
                $display(" %2d  %-9s %3d %5d %1d   %0d   %0d  %4d  %3d %3d %3d %3d  %3d %3d %4d  PASS",
                         f, (exp_cls[f]==1)?"circle":(exp_cls[f]==2)?"square":
                            (exp_cls[f]==3)?"triangle":"cross",
                         exp_ang[f], exp_scale[f], exp_noise[f], exp_cls[f], o_cls,
                         dut.u_tmpl.min_d_r, dc, ds, dt, dx,
                         dut.u_tmpl.bw, dut.u_tmpl.bh, dut.s_area);
            end
        end

        $display("------------------------------------------------------------------------------------------");
        if (errs == 0)
            $display(" RESULT: ALL PASS  (%0d cases)", TMPL_NCASES);
        else
            $display(" RESULT: %0d ERROR(S)", errs);
        $display("==========================================================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
