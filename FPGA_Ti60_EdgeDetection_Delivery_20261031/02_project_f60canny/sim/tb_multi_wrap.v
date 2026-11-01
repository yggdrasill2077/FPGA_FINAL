`timescale 1ns/1ps
module tb_multi_wrap;
    localparam integer HP = 160;      // 320 px
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
        .MIN_AREA(8), .MIN_BBOX(4), .FILL_MIN(2), .MERGE_GAP(1),
        .POLAR_NRAY(128), .POLAR_GAP_TOL(3), .POLAR_MIN_AREA(8),
        .POLAR_MIN_BBOX(16), .POLAR_COV_MIN(80), .POLAR_MAX_R(160),
        .SCHED_TIMEOUT(24000), .PAPER_GATE_EN(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_vs(i_vs), .i_g0(i_g0), .i_g1(i_g1), .i_ty(8'd170), .i_lfg0(1'b0), .i_lfg1(1'b0),
        .o_num(w_num), .o_valid(w_valid), .o_cls(w_cls),
        .o_area(w_area), .o_sx(w_sx), .o_sy(w_sy),
        .o_bx0(w_bx0), .o_bx1(w_bx1), .o_by0(w_by0), .o_by1(w_by1),
        .o_done(w_done)
    );

    function in_circle(input integer x, input integer y);
        begin in_circle = ((x-50)*(x-50)+(y-60)*(y-60) <= 22*22); end
    endfunction
    function in_square(input integer x, input integer y);
        begin in_square = (x>=92)&&(x<=132)&&(y>=30)&&(y<=70); end
    endfunction
    function in_triangle(input integer x, input integer y);
        integer half;
        begin
            half = (y-25)*45/60;
            in_triangle = (y>=25)&&(y<=85)&&(x>=(230-half))&&(x<=(230+half));
        end
    endfunction
    function in_rect(input integer x, input integer y);
        begin in_rect = (x>=30)&&(x<=120)&&(y>=150)&&(y<=195); end
    endfunction
    function scene_fg(input integer x, input integer y);
        begin scene_fg = in_circle(x,y)||in_square(x,y)||in_triangle(x,y)||in_rect(x,y); end
    endfunction

    integer r, c, n, k, errs;
    reg got1, got2, got3, got5;

    task send_frame;
        begin
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
        errs = 0; got1 = 0; got2 = 0; got3 = 0; got5 = 0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        send_frame();

        n = 0;
        while (!w_done && n < 200000) begin @(posedge clk); #1; n = n + 1; end
        if (!w_done) begin
            $display("MULTI WRAP TIMEOUT");
            errs = errs + 1;
        end else begin
            $display("MULTI WRAP num=%0d valid=%b cls=%03x cycles=%0d",
                     w_num, w_valid, w_cls, n);
            for (k=0; k<4; k=k+1) begin
                if (w_valid[k]) begin
                    $display("  cand%0d cls=%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d",
                             k, w_cls[3*k +: 3],
                             w_bx0[11*k +: 11], w_by0[11*k +: 11],
                             w_bx1[11*k +: 11], w_by1[11*k +: 11],
                             w_area[16*k +: 16]);
                    case (w_cls[3*k +: 3])
                    3'd1: got1 = 1'b1;
                    3'd2: got2 = 1'b1;
                    3'd3: got3 = 1'b1;
                    3'd5: got5 = 1'b1;
                    endcase
                end
            end
            if (!(got1 && got2 && got3 && got5 && (w_num == 3'd4))) begin
                $display("MULTI WRAP CLASS SET FAIL");
                errs = errs + 1;
            end
        end
        $display("RESULT: %0d ERROR(S)", errs);
        $finish;
    end

    initial begin
        #50000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end
endmodule
