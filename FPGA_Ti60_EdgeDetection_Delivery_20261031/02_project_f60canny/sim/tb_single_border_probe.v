`timescale 1ns/1ps
module tb_single_border_probe;
    localparam integer HP = 160;
    localparam integer VL = 240;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_de = 1'b0;
    reg i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;

    wire [2:0] w_num;
    wire [3:0] w_valid;
    wire [11:0] w_cls;
    wire [63:0] w_area;
    wire [107:0] w_sx, w_sy;
    wire [43:0] w_bx0, w_bx1, w_by0, w_by1;
    wire w_done;

    shape_multi_recog #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(8), .GRID_Y(6),
        .CELL_SEED_MIN(2), .CELL_MERGE_MIN(1),
        .MIN_AREA(32), .MIN_BBOX(4), .FILL_MIN(2), .MERGE_GAP(1),
        .MAX_BBOX_W(200), .MAX_BBOX_H(200),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(60000), .AUTO_TY(0), .PAPER_GATE_EN(0),
        // This legacy test deliberately checks bbox retention for border
        // fragments, including candidates whose radial class is unknown.
        .KEEP_UNKNOWN(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170), .i_lfg0(1'b0), .i_lfg1(1'b0),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    integer which;
    function scene_fg(input integer x, input integer y);
        begin
            case (which)
            0: scene_fg = (x >= 200) && (x <= 319) && (y >= 80) && (y <= 199); // right edge
            1: scene_fg = (x >= 20) && (x <= 299) && (y >= 20) && (y <= 219); // > max bbox
            default: scene_fg = (x >= 100) && (x <= 111) && (y >= 100) && (y <= 111); // tiny
            endcase
        end
    endfunction

    integer r, c, n, k, errs;
    task send_frame;
        begin
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            for (r=0; r<VL; r=r+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1;
                    i_g0 = scene_fg(2*c,   r) ? 8'd0 : 8'd255;
                    i_g1 = scene_fg(2*c+1, r) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0; i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
            i_vs = 1'b1; repeat (5) @(negedge clk); i_vs = 1'b0;
            repeat (5) @(negedge clk);
        end
    endtask

    initial begin
        errs = 0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        for (which=0; which<3; which=which+1) begin
            send_frame();
            n = 0;
            while (!w_done && n < 200000) begin @(posedge clk); #1; n = n+1; end
            $display("BORDER CASE %0d num=%0d valid=%b cls=%03x cycles=%0d",
                     which, w_num, w_valid, w_cls, n);
            for (k=0;k<4;k=k+1)
                if (w_valid[k])
                    $display("  cand%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d",
                             k, w_bx0[11*k +: 11], w_by0[11*k +: 11],
                             w_bx1[11*k +: 11], w_by1[11*k +: 11],
                             w_area[16*k +: 16]);
            if (!(w_num == 3'd1) || !w_valid[0]) begin
                $display("BORDER CASE %0d FAIL", which);
                errs = errs+1;
            end
            repeat (10) @(negedge clk);
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end
endmodule
