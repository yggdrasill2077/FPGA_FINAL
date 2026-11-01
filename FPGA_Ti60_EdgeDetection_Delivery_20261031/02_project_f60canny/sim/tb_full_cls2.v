`timescale 1ns/1ps
// tb_full_cls2.v -- 1920x1080 CLASS output verification (never tested before)
//   shape codes: circle=1 square=2 triangle=3 cross=4 unknown=0
module tb_full_cls2;

    localparam integer HP = 960;
    localparam integer VL = 1080;

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
        .TY      (8'd170), .AUTO_TY (1), .TY_MARGIN (8'd60), .TY_CAP (8'd110),
        .A_MIN   (10), .A_MAX (60000), .CELL_MIN (150), .WIN_EN (0), .BOX_ON_ANY (0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1),
        .o_cls(o_cls), .o_upd(o_upd),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_box_en(o_box_en), .o_best_idx(o_best_idx), .o_best_cnt(o_best_cnt)
    );

    function in_shape;
        input [31:0] x;
        input [31:0] y;
        input [31:0] cx;
        input [31:0] cy;
        input [31:0] kind;
        input [31:0] sz;
        reg signed [31:0] dx;
        reg signed [31:0] dy;
        begin
            dx = x - cx; dy = y - cy;
            if (kind == 0) in_shape = ((dx*dx + dy*dy) <= (sz*sz));
            else           in_shape = ((dx <= sz) && (dx >= -sz) && (dy <= sz) && (dy >= -sz));
        end
    endfunction

    task send_frame(input integer cx, input integer cy, input integer kind, input integer sz);
        integer r, c, x;
        begin
            for (r = 0; r < VL; r = r + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1;
                    x = 2*c;
                    i_g0 = in_shape(x,   r, cx, cy, kind, sz) ? 8'd30 : 8'd255;
                    i_g1 = in_shape(x+1, r, cx, cy, kind, sz) ? 8'd30 : 8'd255;
                    @(posedge clk); #1;
                end
                i_de = 0; i_g0 = 8'd0; i_g1 = 8'd0;
                repeat (2) @(posedge clk); #1;
            end
            repeat (8) @(posedge clk); #1;
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

    task wait_upd;
        integer n;
        begin
            n = 0;
            while (!o_upd && n < 40000) begin @(negedge clk); n = n + 1; end
        end
    endtask

    integer errs = 0;
    task run_case(input integer kind, input integer sz, input integer exp_cls);
        begin
            send_frame(960, 540, kind, sz); send_vs(); wait_upd();
            send_frame(960, 540, kind, sz); send_vs(); wait_upd();
            $write("  kind=%0d size=%0d -> cls=%0d exp=%0d bbox=(%0d,%0d)-(%0d,%0d) box_en=%0d",
                   kind, sz, o_cls, exp_cls, o_bx0, o_by0, o_bx1, o_by1, o_box_en);
            if (o_cls !== exp_cls[2:0]) begin
                errs = errs + 1;
                $display("  FAIL");
            end else $display("  PASS");
        end
    endtask

    initial begin
        rst_n = 0; repeat (10) @(posedge clk); #1 rst_n = 1;
        repeat (10) @(posedge clk); #1;
        $display("======================================================");
        $display(" 1920x1080 CLASS output verification (real gates)");
        $display("======================================================");
        send_vs(); wait_upd();
        run_case(0, 300, 1);
        run_case(1, 200, 2);
        run_case(1, 120, 2);
        run_case(0, 120, 1);
        $display("------------------------------------------------------");
        if (errs == 0) $display(" RESULT: ALL PASS");
        else           $display(" RESULT: %0d ERROR(S)", errs);
        $display("======================================================");
        $finish;
    end

endmodule
