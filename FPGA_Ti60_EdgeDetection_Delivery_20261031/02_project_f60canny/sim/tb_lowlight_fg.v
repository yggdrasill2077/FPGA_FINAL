`timescale 1ns/1ps
// F33 low-light front-end regression.
// Continuous-video timing: one VS pulse per frame, data follows immediately.
//   LOW-CONTRAST: paper=125, ink=100 (global threshold is 101)
//   DARK:         paper=40,  ink=20 (max_l < 60 exercises the underflow guard)
module tb_lowlight_fg;
    localparam integer HP = 960;   // 1920 px
    localparam integer VL = 240;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg i_hs = 1'b0;
    reg [7:0] i_g0 = 8'd125;
    reg [7:0] i_g1 = 8'd125;

    wire        m_de, m_hs, m_vs, m_va;
    wire [7:0]  m_g0, m_g1;
    wire        m_lfg0, m_lfg1;

    median3x3_2px u_med (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_hs(i_hs), .i_vs(i_vs), .i_valid(i_de),
        .i_g0(i_g0), .i_g1(i_g1),
        .o_de(m_de), .o_hs(m_hs), .o_vs(m_vs), .o_valid(m_va),
        .o_g0(m_g0), .o_g1(m_g1), .o_lfg0(m_lfg0), .o_lfg1(m_lfg1)
    );

    wire [2:0]  w_num;
    wire [3:0]  w_valid;
    wire [11:0] w_cls;
    wire [63:0] w_area;
    wire [107:0] w_sx, w_sy;
    wire [43:0] w_bx0, w_bx1, w_by0, w_by1;
    wire w_done;

    shape_multi_recog #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(32), .GRID_Y(18),
        .CELL_SEED_MIN(4), .CELL_MERGE_MIN(1),
        .MIN_AREA(24), .MIN_BBOX(8), .FILL_MIN(4), .MERGE_GAP(1),
        .GLOBAL_ROI_PCT(8), .GLOBAL_MIN_BLOCKS(8),
        .GLOBAL_MIN_BBOX(8), .GLOBAL_FILL_MIN(24),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(1),
        .TY_MIN_MARGIN(12), .TY_FLOOR(24),
        .LOCAL_FG_EN(0), .LOCAL_GATE_MAX(96), .PAPER_GATE_EN(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(m_de), .i_vs(m_vs),
        .i_g0(m_g0), .i_g1(m_g1), .i_ty(8'd170),
        .i_lfg0(m_lfg0), .i_lfg1(m_lfg1),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    integer paper_g, ink_g;
    integer r, c, n, errs;

    function scene_ink(input integer x, input integer y);
        integer dx, dy;
        begin
            dx = x - 960;
            dy = y - 120;
            scene_ink = (dx >= -52) && (dx <= 52) && (dy >= -52) && (dy <= 52) &&
                        !((dx >= -47) && (dx <= 47) && (dy >= -47) && (dy <= 47));
        end
    endfunction

    task send_frame;
        begin
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1; i_hs = 1'b1;
                    i_g0 = scene_ink(2*c,   r) ? ink_g[7:0] : paper_g[7:0];
                    i_g1 = scene_ink(2*c+1, r) ? ink_g[7:0] : paper_g[7:0];
                    @(negedge clk);
                end
                i_de = 1'b0; i_hs = 1'b0;
                repeat (100) @(negedge clk);
            end
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            repeat (10) @(negedge clk);
        end
    endtask

    task wait_done;
        begin
            n = 0;
            while (!w_done && n < 250000) begin @(posedge clk); #1; n=n+1; end
            $display("  num=%0d valid=%b cls=%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d ty=%0d max_l=%0d cycles=%0d",
                     w_num, w_valid, w_cls[2:0],
                     w_bx0[10:0], w_by0[10:0], w_bx1[10:0], w_by1[10:0],
                     w_area[15:0], dut.ty_eff, dut.max_y_l, n);
            if (!w_done) begin
                $display("  TIMEOUT"); errs = errs + 1;
            end
            repeat (10) @(negedge clk);
        end
    endtask

    initial begin
        errs = 0;
        repeat (12) @(negedge clk);
        rst_n = 1'b1;
        repeat (12) @(negedge clk);

        // Bootstrap VS, then a prime frame so the next frame has a valid max_l.
        i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
        repeat (5) @(negedge clk);

        paper_g = 125; ink_g = 100;
        $display("LOW-CONTRAST PRIME");
        send_frame(); wait_done();
        $display("LOW-CONTRAST TEST");
        send_frame(); wait_done();
        if (!w_valid[0] || (w_cls[2:0] != 3'd2)) begin
            $display("LOW-CONTRAST FAIL"); errs = errs + 1;
        end

        paper_g = 40; ink_g = 20;
        $display("DARK PRIME");
        send_frame(); wait_done();
        $display("DARK UNDERFLOW TEST");
        send_frame(); wait_done();
        if (!w_valid[0] || (w_cls[2:0] != 3'd2)) begin
            $display("DARK UNDERFLOW FAIL"); errs = errs + 1;
        end

        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
