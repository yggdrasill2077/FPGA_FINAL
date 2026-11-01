`timescale 1ns/1ps
// tb_photo.v -- drive the RTL with the 18 real photos (480x270, 18 frames x 2)
//   checks o_cls against human labels; prints accuracy
//   run: iverilog -g2012 -I sim -s tb_photo -o sim/tb_photo.vvp \
//            sim/tb_photo.v rtl/edge/shape_recog.v rtl/edge/shape_tmpl.v
//        vvp sim/tb_photo.vvp
module tb_photo;

    localparam integer HP = 240;      // 480/2
    localparam integer VL = 270;
    localparam integer PIX = HP * 2 * VL;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        i_de = 0, i_vs = 0;
    reg  [7:0] i_g0 = 0, i_g1 = 0;

    wire [2:0]  o_cls;
    wire        o_upd, o_box_en;
    wire [10:0] o_bx0, o_bx1, o_by0, o_by1;
    wire [3:0]  o_best_idx;
    wire [13:0] o_best_cnt;

    shape_recog #(
        .H_PAIRS (HP), .V_LINES (VL),
        .AUTO_TY (1), .TY_MARGIN (8'd60), .TY_CAP (8'd110),
        .A_MIN   (10), .A_MAX (60000), .CELL_MIN (150),
        .WIN_EN  (0), .MARGIN_PCT (8), .BOX_ON_ANY (0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_box_en(o_box_en), .o_best_idx(o_best_idx), .o_best_cnt(o_best_cnt)
    );

    `include "photo_expect.vh"

    reg [7:0] img [0:PHOTO_N*PIX-1];
    integer errs = 0;
    integer hits = 0;
    integer f;
    reg [2:0] got;

    task send_vs;
        begin
            i_de = 0; i_vs = 1;
            repeat (3) @(posedge clk); #1;
            i_vs = 0;
            repeat (3) @(posedge clk); #1;
        end
    endtask

    task send_frame(input integer n);
        integer r, c;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1;
                    i_g0 = img[n*PIX + r*(HP*2) + 2*c];
                    i_g1 = img[n*PIX + r*(HP*2) + 2*c + 1];
                    @(posedge clk); #1;
                end
                i_de = 0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (2) @(posedge clk); #1;
            end
            repeat (8) @(posedge clk); #1;
        end
    endtask

    task wait_upd;
        integer n;
        begin
            n = 0;
            while (!o_upd && n < 40000) begin @(negedge clk); n = n + 1; end
        end
    endtask

    initial begin
        $readmemh("sim/photo_frames.hex", img);
        rst_n = 0; repeat (10) @(posedge clk); #1 rst_n = 1;
        repeat (10) @(posedge clk); #1;
        $display("======================================================");
        $display(" 18 real photos through RTL (480x270)");
        $display("======================================================");
        send_vs(); wait_upd();
        for (f = 0; f < PHOTO_N; f = f + 1) begin
            send_frame(f); send_vs(); wait_upd();
            send_frame(f); send_vs(); wait_upd();
            got = o_cls;
            if (got === exp_cls[f]) hits = hits + 1;
            begin : dbg2
                integer q, nz;
                nz = 0;
                for (q = 0; q < 1024; q = q + 1) if (dut.u_tmpl.grid_ram[q] != 0) nz = nz + 1;
                $write("    grid_nz=%0d", nz);
            end
            if (f == 0 || f == 4) begin : dbg
                integer q;
                for (q = 0; q < 16; q = q + 1)
                    $write("    hdist[%0d]=%0d", q, dut.u_tmpl.hdist[q]);
                $display("");
                $display("    bw=%0d bh=%0d thr=%0d min_d=%0d min_idx=%0d",
                         dut.u_tmpl.bw, dut.u_tmpl.bh, dut.u_tmpl.i_thr,
                         dut.u_tmpl.min_d_r, dut.u_tmpl.min_idx_r);
                $display("    gates: rej=%0d area_ok=%0d frac_ok=%0d fill=%0d asp=%0d cell=%0d A=%0d best_cnt=%0d",
                         dut.rej_all, dut.area_ok, dut.frac_ok, dut.fill_ok_r,
                         dut.asp_ok, dut.cell_ok, dut.s_area, dut.best_cnt);
            end
            $display("  photo %0d : cls=%0d exp=%0d bbox=(%0d,%0d)-(%0d,%0d) box_en=%0d  %s",
                     f, got, exp_cls[f], o_bx0, o_by0, o_bx1, o_by1, o_box_en,
                     (got === exp_cls[f]) ? "OK" : "X");
        end
        $display("------------------------------------------------------");
        $display(" RTL accuracy: %0d/%0d = %0d%%", hits, PHOTO_N, (hits*100)/PHOTO_N);
        $display("======================================================");
        $finish;
    end

endmodule
