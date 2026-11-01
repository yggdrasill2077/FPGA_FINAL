`timescale 1ns/1ps
module tb_polar_grid_cand;
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
    reg i_start = 1'b0;

    wire [2:0] g_num;
    wire [3:0] g_valid;
    wire [43:0] g_bx0, g_bx1, g_by0, g_by1;
    wire [107:0] g_sx, g_sy;
    wire [63:0] g_area;
    wire g_done;

    wire [2:0] p_cls;
    wire p_upd;
    wire [7:0] p_cov, p_rmin;
    wire [15:0] p_s;

    shape_grid_multi_v2 #(
        .H_PAIRS(HP), .V_LINES(VL), .GRID_X(8), .GRID_Y(6),
        .CELL_SEED_MIN(2), .CELL_MERGE_MIN(1), .MIN_AREA(8), .MIN_BBOX(4),
        .FILL_MIN(2), .MERGE_GAP(1)
    ) u_grid (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170),
        .i_gate_en(1'b0), .i_gx0(11'd0), .i_gx1(11'd0),
        .i_gy0(11'd0), .i_gy1(11'd0),
        .o_num(g_num), .o_valid(g_valid),
        .o_bx0(g_bx0), .o_bx1(g_bx1), .o_by0(g_by0), .o_by1(g_by1),
        .o_sx(g_sx), .o_sy(g_sy), .o_area(g_area), .o_done(g_done)
    );

    shape_polar #(
        .H_PAIRS(HP), .V_LINES(VL), .BLK_SHIFT(2), .NRAY(128),
        .GAP_TOL(3), .MIN_AREA(8), .MIN_BBOX(16), .COV_MIN(80),
        .CAND_MODE(1)
    ) u_polar (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_start(i_start), .i_roi(1'b1), .i_g0(i_g0), .i_g1(i_g1),
        .i_ty(8'd170),
        .i_sx(g_sx[26:0]), .i_sy(g_sy[26:0]), .i_area(g_area[15:0]),
        .i_bx0(g_bx0[10:0]), .i_bx1(g_bx1[10:0]),
        .i_by0(g_by0[10:0]), .i_by1(g_by1[10:0]),
        .i_valid(g_valid[0]),
        .o_cls(p_cls), .o_upd(p_upd),
        .o_blk_cov(), .o_blk_bx0(), .o_blk_bx1(), .o_blk_by0(), .o_blk_by1(),
        .o_dbg_cov(p_cov), .o_dbg_rmin(p_rmin), .o_dbg_s(p_s)
    );

    `include "polar_int_cases.vh"
    reg [7:0] img [0:POLAR_NINT*PPF-1];
    integer f, r, c, n, errs;
    reg [8*80-1:0] fn;

    task send_vs;
        begin
            i_de = 1'b0;
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            repeat (5) @(negedge clk);
        end
    endtask

    task send_frame(input integer idx);
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = img[idx*PPF + r*HP*2 + 2*c];
                    i_g1 = img[idx*PPF + r*HP*2 + 2*c + 1];
                    @(negedge clk);
                end
                i_de = 1'b0;
                i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
        end
    endtask

    initial begin
        errs = 0;
        for (f = 0; f < POLAR_NINT; f = f + 1) begin
            $sformat(fn, "sim/polar_int_%0d.hex", f);
            $readmemh(fn, img, f*PPF, f*PPF + PPF - 1);
        end

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        $display("POLAR GRID CANDIDATE TEST");

        for (f = 0; f < POLAR_NINT; f = f + 1) begin
            send_frame(f);
            send_vs();
            n = 0;
            while (!g_done && n < 20000) begin @(posedge clk); #1; n = n + 1; end
            if (!g_done) begin
                $display("FRAME %0d GRID TIMEOUT", f);
                errs = errs + 1;
            end else if (g_num == 0 || !g_valid[0]) begin
                $display("FRAME %0d NO GRID CANDIDATE", f);
                errs = errs + 1;
            end else begin
                i_start = 1'b1;
                @(posedge clk); #1;
                i_start = 1'b0;
                n = 0;
                while (!p_upd && n < 40000) begin @(posedge clk); #1; n = n + 1; end
                if (!p_upd) begin
                    $display("FRAME %0d POLAR TIMEOUT", f);
                    errs = errs + 1;
                end else if (p_cls !== exp_int_cls[f]) begin
                    $display("FRAME %0d FAIL cls=%0d exp=%0d cov=%0d rmin=%0d S=%0d cyc=%0d area=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                        f, p_cls, exp_int_cls[f], p_cov, p_rmin, p_s, n,
                        g_area[15:0], g_bx0[10:0], g_by0[10:0], g_bx1[10:0], g_by1[10:0]);
                    errs = errs + 1;
                end else begin
                    $display("FRAME %0d PASS cls=%0d cov=%0d cyc=%0d area=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                        f, p_cls, p_cov, n, g_area[15:0],
                        g_bx0[10:0], g_by0[10:0], g_bx1[10:0], g_by1[10:0]);
                end
            end
            repeat (6) @(negedge clk);
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end

    initial begin
        #20000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end
endmodule
