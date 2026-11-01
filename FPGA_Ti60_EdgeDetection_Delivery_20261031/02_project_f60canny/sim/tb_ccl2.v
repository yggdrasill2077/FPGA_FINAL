`timescale 1ns/1ps
// tb_ccl2.v -- verify shape_ccl_v2 largest-blob bbox on synthetic frames (480x270)
module tb_ccl2;
    localparam integer HP = 240;
    localparam integer VL = 270;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        i_de = 0, i_vs = 0;
    reg  [7:0] i_g0 = 0;
    reg  [7:0] i_ty = 8'd110;

    wire [10:0] bx0, bx1, by0, by1;
    wire [15:0] area;
    wire        valid;

    shape_ccl_v2 #(.H_PAIRS(HP), .V_LINES(VL), .NENT(16), .MIN_AREA(12)) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_ty(i_ty),
        .o_bx0(bx0), .o_bx1(bx1), .o_by0(by0), .o_by1(by1),
        .o_area(area), .o_valid(valid)
    );

    integer b0x0, b0x1, b0y0, b0y1;
    integer b1x0, b1x1, b1y0, b1y1;
    integer use1;

    task send_frame;
        integer r, c, x;
        reg dark;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1;
                    x = 2*c;
                    dark = (x >= b0x0) && (x <= b0x1) && (r >= b0y0) && (r <= b0y1);
                    if (use1) dark = dark || ((x >= b1x0) && (x <= b1x1) && (r >= b1y0) && (r <= b1y1));
                    i_g0 = dark ? 8'd30 : 8'd255;
                    @(posedge clk); #1;
                end
                i_de = 0; i_g0 = 8'd0;
                repeat (2) @(posedge clk); #1;
            end
            repeat (4) @(posedge clk); #1;
        end
    endtask

    task send_vs;
        begin
            i_de = 0; i_vs = 1;
            repeat (3) @(posedge clk); #1;
            i_vs = 0;
            repeat (3) @(posedge clk); #1;
        end
    endtask

    integer dbg_n = 0;
    always @(posedge clk) begin
        if (dut.run_end_any && dbg_n < 12) begin
            $display("    RUNEND row=%0d rs=%0d re=%0d len=%0d has0=%b hit0=%0d has_free=%b freesel=%0d valid=%b", dut.row, dut.run_s, dut.run_e, dut.run_len, dut.has0, dut.hit0, dut.has_free, dut.free_idx, dut.a_valid);
            dbg_n <= dbg_n + 1;
        end
    end
    integer errs = 0;
    task check(input integer ex0, input integer ex1, input integer ey0, input integer ey1,
               input integer emin);
        begin
            $write("    got bbox=(%0d,%0d)-(%0d,%0d) area=%0d valid=%0d | exp=(%0d,%0d)-(%0d,%0d) a>=%0d",
                   bx0, by0, bx1, by1, area, valid, ex0, ey0, ex1, ey1, emin);
            if (!valid || (bx0 > ex0 + 16) || (bx1 + 16 < ex1) ||
                (by0 > ey0 + 16) || (by1 + 16 < ey1) || (area < emin)) begin
                errs = errs + 1; $display("  FAIL");
            end else $display("  PASS");
        end
    endtask

    initial begin
        rst_n = 0; repeat (10) @(posedge clk); #1 rst_n = 1;
        repeat (5) @(posedge clk); #1;
        $display("======================================================");
        $display(" shape_ccl_v2 test (480x270, 1/8 grid 60x34)");
        $display("======================================================");

        b0x0=80; b0x1=239; b0y0=60; b0y1=179; use1=0;
        send_frame(); send_vs(); send_frame(); send_vs();
        $display("  probe: smp8_cnt=%0d runend_cnt=%0d validmask=%b", dut.smp8_cnt, dut.re_cnt, dut.a_valid);
        $display(" case1 single 160x120 blob:");
        check(80, 240, 60, 180, 200);

        b0x0=40; b0x1=279; b0y0=40; b0y1=199;
        b1x0=380; b1x1=439; b1y0=40; b1y1=99; use1=1;
        send_frame(); send_vs(); send_frame(); send_vs();
        $display(" case2 big + small:");
        check(40, 280, 40, 200, 500);
        use1=0;

        b0x0=200; b0x1=263; b0y0=100; b0y1=163;
        send_frame(); send_vs(); send_frame(); send_vs();
        $display(" case3 small 64x64 blob:");
        check(200, 264, 100, 164, 40);

        $display("------------------------------------------------------");
        if (errs == 0) $display(" RESULT: ALL PASS");
        else           $display(" RESULT: %0d ERROR(S)", errs);
        $display("======================================================");
        $finish;
    end
endmodule
