`timescale 1ns/1ps
module tb_small_shapes;
    localparam integer HP = 160;
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
    wire o_upd, o_box_en;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire [3:0] o_best_idx;
    wire [13:0] o_best_cnt;
    reg upd_seen;

    always @(posedge clk) begin
        if (o_upd) upd_seen <= 1'b1;
    end

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

    `include "small_cases.vh"
    reg [7:0] img [0:SMALL_NCASES*PPF-1];

    integer f, r, c, n, errs;
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
        for (f = 0; f < SMALL_NCASES; f = f + 1) begin
            $sformat(fn, "sim/small_%0d.hex", f);
            $readmemh(fn, img, f*PPF, f*PPF + PPF - 1);
        end

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("SMALL TARGET TEST");
        for (f = 0; f < SMALL_NCASES; f = f + 1) begin
            send_frame(f);
            upd_seen = 1'b0;
            send_vs();
            n = 0;
            while (!upd_seen && n < 40000) begin
                @(posedge clk); #1;
                n = n + 1;
            end
            if (!upd_seen) begin
                $display("CASE %0d TIMEOUT", f);
                $display("  DBG state=%0d start=%0d i_valid=%0d rej_empty=%0d bbox=(%0d,%0d)-(%0d,%0d) blk=%0d cov=%0d",
                         dut.u_polar.state, dut.start, dut.u_polar.i_valid, dut.rej_empty,
                         dut.s_bx0, dut.s_by0, dut.s_bx1, dut.s_by1,
                         dut.u_polar.blk_cnt_l, dut.u_polar.cov);
                errs = errs + 1;
            end else if ((o_cls !== exp_small_cls[f]) ||
                         (o_box_en !== (exp_small_cls[f] != 0))) begin
                $display("CASE %0d FAIL cls=%0d exp=%0d box=%0d bbox=(%0d,%0d)-(%0d,%0d) blk=%0d cov=%0d",
                         f, o_cls, exp_small_cls[f], o_box_en, o_bx0, o_by0, o_bx1, o_by1,
                         dut.u_polar.blk_cnt_l, dut.u_polar.cov);
                $display("  S=%0d cv=%0d e2=%0d e3=%0d e4=%0d rmin=%0d cent=%0d cxq=%0d cyq=%0d",
                         dut.u_polar.s_total, dut.u_polar.cv_n,
                         dut.u_polar.e2, dut.u_polar.e3, dut.u_polar.e4,
                         dut.u_polar.rmin, dut.u_polar.cent_blk,
                         dut.u_polar.cxq, dut.u_polar.cyq);
                errs = errs + 1;
            end else begin
                $display("CASE %0d PASS cls=%0d box=%0d bbox=(%0d,%0d)-(%0d,%0d) blk=%0d cov=%0d S=%0d cv=%0d e2=%0d e3=%0d e4=%0d",
                         f, o_cls, o_box_en, o_bx0, o_by0, o_bx1, o_by1,
                         dut.u_polar.blk_cnt_l, dut.u_polar.cov,
                         dut.u_polar.s_total, dut.u_polar.cv_n,
                         dut.u_polar.e2, dut.u_polar.e3, dut.u_polar.e4);
            end
            repeat (6) @(posedge clk);
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
