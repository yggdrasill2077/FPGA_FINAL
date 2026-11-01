`timescale 1ns/1ps
module tb_shape_polar;
    localparam integer HP = 960;
    localparam integer VL = 1080;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg i_start = 1'b0;
    reg i_roi = 1'b1;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;
    reg [7:0] i_ty = 8'd110;
    reg [26:0] i_sx = 27'd0;
    reg [26:0] i_sy = 27'd0;
    reg [15:0] i_area = 16'd0;
    reg [10:0] i_bx0 = 11'd0;
    reg [10:0] i_bx1 = 11'd0;
    reg [10:0] i_by0 = 11'd0;
    reg [10:0] i_by1 = 11'd0;
    reg i_valid = 1'b0;

    wire [2:0] o_cls;
    wire o_upd;
    wire [7:0] o_cov, o_rmin;
    wire [15:0] o_s;

    shape_polar #(
        .H_PAIRS(HP), .V_LINES(VL), .BLK_SHIFT(3),
        .NRAY(128), .GAP_TOL(3), .MIN_AREA(10), .COV_MIN(96)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_start(i_start), .i_roi(i_roi),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(i_ty),
        .i_sx(i_sx), .i_sy(i_sy), .i_area(i_area),
        .i_bx0(i_bx0), .i_bx1(i_bx1), .i_by0(i_by0), .i_by1(i_by1),
        .i_valid(i_valid),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_dbg_cov(o_cov), .o_dbg_rmin(o_rmin), .o_dbg_s(o_s)
    );

    `include "polar_cases.vh"

    integer errs = 0;
    integer c, n;
    reg [8*80-1:0] fn;

    task run_case(input integer idx);
        begin
            $sformat(fn, "sim/polar_map_%0d.hex", idx);
            $readmemh(fn, dut.bm);

            i_vs = 1'b1; repeat (3) @(posedge clk); #1;
            i_vs = 1'b0; repeat (3) @(posedge clk); #1;

            i_area = exp_area[idx];
            i_sx = exp_sx[idx];
            i_sy = exp_sy[idx];
            i_bx0 = exp_bx0[idx]; i_bx1 = exp_bx1[idx];
            i_by0 = exp_by0[idx]; i_by1 = exp_by1[idx];
            i_valid = 1'b1;
            i_start = 1'b1; @(posedge clk); #1;
            i_start = 1'b0;

            n = 0;
            while (!o_upd && n < 60000) begin
                @(posedge clk); #1;
                n = n + 1;
            end
            if (!o_upd) begin
                $display("CASE %0d TIMEOUT", idx);
                errs = errs + 1;
            end else begin
                if (o_cls !== exp_cls[idx]) begin
                    $display("CASE %0d FAIL cls=%0d exp=%0d cov=%0d rmin=%0d S=%0d cyc=%0d",
                             idx, o_cls, exp_cls[idx], o_cov, o_rmin, o_s, n);
                    $display("  e2=%0d e3=%0d e4=%0d S2=%0d cv=%0d",
                             dut.e2, dut.e3, dut.e4, dut.sq_s, dut.cv_n);
                    errs = errs + 1;
                end else begin
                    $display("CASE %0d PASS cls=%0d cov=%0d rmin=%0d S=%0d cyc=%0d",
                             idx, o_cls, o_cov, o_rmin, o_s, n);
                end
            end
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);
        $display("POLAR CORE TEST");
        for (c = 0; c < POLAR_NCASES; c = c + 1)
            run_case(c);
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
