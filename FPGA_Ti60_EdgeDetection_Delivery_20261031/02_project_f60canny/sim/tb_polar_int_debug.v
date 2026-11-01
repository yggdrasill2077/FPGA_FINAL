`timescale 1ns/1ps
module tb_polar_int_debug;
    localparam integer HP = 160;       // 320 pixels
    localparam integer VL = 240;
    localparam integer PPF = HP * 2 * VL;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;

    wire [2:0] o_cls;
    wire o_upd;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire o_box_en;
    wire [3:0] o_best_idx;
    wire [13:0] o_best_cnt;

    shape_recog #(
        .H_PAIRS(HP), .V_LINES(VL),
        .TY(8'd170), .TMPL_MIN(32), .CELL_W(80), .CELL_H(60),
        .CELL_MIN(40), .MARGIN_PCT(5), .WIN_EN(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_box_en(o_box_en), .o_best_idx(o_best_idx), .o_best_cnt(o_best_cnt)
    );

    `include "polar_int_cases.vh"
    reg [7:0] img [0:POLAR_NINT*PPF-1];

    integer f, r, c, n, errs;
    integer bx, by, smapcnt, smapx, smapy, sminx, smaxx, sminy, smaxy;
    integer mfd;

    reg [8*80-1:0] fn;

    task send_vs;
        begin
            i_de = 1'b0;
            i_vs = 1'b1;
            repeat (3) @(posedge clk); #1;
            i_vs = 1'b0;
            repeat (3) @(posedge clk); #1;
        end
    endtask

    task send_frame(input integer idx);
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = img[idx*PPF + r*HP*2 + 2*c];
                    i_g1 = img[idx*PPF + r*HP*2 + 2*c + 1];
                    @(posedge clk); #1;
                end
                i_de = 1'b0;
                repeat (2) @(posedge clk); #1;
            end
            repeat (8) @(posedge clk); #1;
        end
    endtask

    initial begin
        errs = 0;
        for (f = 0; f < POLAR_NINT; f = f + 1) begin
            $sformat(fn, "sim/polar_int_%0d.hex", f);
            $readmemh(fn, img, f*PPF, f*PPF + PPF - 1);
        end

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("POLAR INTEGRATION TEST");
        for (f = 0; f < POLAR_NINT; f = f + 1) begin
            send_frame(f);
            send_vs();
            smapcnt = 0; smapx = 0; smapy = 0;
            sminx = 999; smaxx = -1; sminy = 999; smaxy = -1;
            for (by = 0; by < 60; by = by + 1)
                for (bx = 0; bx < 80; bx = bx + 1)
                    if (dut.u_polar.bm[by*(HP/2)+bx]) begin
                        smapcnt = smapcnt + 1;
                        smapx = smapx + bx;
                        smapy = smapy + by;
                        if (bx < sminx) sminx = bx;
                        if (bx > smaxx) smaxx = bx;
                        if (by < sminy) sminy = by;
                        if (by > smaxy) smaxy = by;
                    end
            $display("  MAP cnt=%0d sumx=%0d sumy=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                     smapcnt, smapx, smapy, sminx, sminy, smaxx, smaxy);
            if (f == 0) begin
                mfd = $fopen("sim/map_rtl0.txt", "w");
                for (by = 0; by < 60; by = by + 1) begin
                    for (bx = 0; bx < 80; bx = bx + 1)
                        $fwrite(mfd, "%0d", dut.u_polar.bm[by*(HP/2)+bx]);
                    $fwrite(mfd, "\n");
                end
                $fclose(mfd);
            end
            n = 0;
            while (!o_upd && n < 40000) begin
                @(posedge clk); #1;
                n = n + 1;
            end
            if (!o_upd) begin
                $display("FRAME %0d TIMEOUT", f);
                errs = errs + 1;
            end else if (o_cls !== exp_int_cls[f]) begin
                $display("FRAME %0d FAIL cls=%0d exp=%0d bbox=(%0d,%0d)-(%0d,%0d) cnt=%0d cyc=%0d",
                         f, o_cls, exp_int_cls[f], o_bx0, o_by0, o_bx1, o_by1,
                         o_best_cnt, n);
                $display("  POLAR cov=%0d S=%0d cv=%0d e2=%0d e3=%0d e4=%0d cent=%0d cxq=%0d cyq=%0d blk=%0d sumx=%0d sumy=%0d",
                         dut.u_polar.cov, dut.u_polar.s_total, dut.u_polar.cv_n,
                         dut.u_polar.e2, dut.u_polar.e3, dut.u_polar.e4,
                         dut.u_polar.cent_blk, dut.u_polar.cxq, dut.u_polar.cyq,
                         dut.u_polar.blk_cnt_l, dut.u_polar.blk_sumx_l, dut.u_polar.blk_sumy_l);
                errs = errs + 1;
            end else begin
                $display("FRAME %0d PASS cls=%0d bbox=(%0d,%0d)-(%0d,%0d) cnt=%0d cyc=%0d",
                         f, o_cls, o_bx0, o_by0, o_bx1, o_by1, o_best_cnt, n);
            end
            repeat (6) @(posedge clk);
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
