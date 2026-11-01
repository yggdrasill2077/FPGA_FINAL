`timescale 1ns/1ps
module tb_grid_multi;
    localparam integer HP = 960;
    localparam integer VL = 1080;

    reg clk = 0;
    reg rst_n = 0;
    reg i_de = 0;
    reg i_vs = 0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;
    reg [7:0] i_ty = 8'd128;

    wire [2:0] o_num;
    wire [3:0] o_valid;
    wire [43:0] o_bx0, o_bx1, o_by0, o_by1;
    wire [107:0] o_sx, o_sy;
    wire [63:0] o_area;
    wire o_done;

    shape_grid_multi #(
        .H_PAIRS(HP), .V_LINES(VL),
        .GRID_X(16), .GRID_Y(9),
        .CELL_SEED_MIN(8), .CELL_MERGE_MIN(2),
        .MIN_AREA(32), .MIN_BBOX(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(i_ty),
        .o_num(o_num), .o_valid(o_valid),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_sx(o_sx), .o_sy(o_sy), .o_area(o_area), .o_done(o_done)
    );

    always #5 clk = ~clk;

    reg [3:0] last_c;
    integer cyc;
    integer dbgcnt;
    integer dbg2;
    always @(posedge clk) begin
        cyc <= cyc + 1;
    end

    function in_circle(input integer x, input integer y);
        begin
            in_circle = ((x-300)*(x-300) + (y-300)*(y-300)) <= (80*80);
        end
    endfunction

    function in_square(input integer x, input integer y);
        begin
            in_square = (x >= 820) && (x <= 980) && (y >= 220) && (y <= 380);
        end
    endfunction

    function in_triangle(input integer x, input integer y);
        integer half;
        begin
            half = (y - 220) / 2;
            in_triangle = (y >= 220) && (y <= 380) &&
                          (x >= (1500 - half)) && (x <= (1500 + half));
        end
    endfunction

    function in_rect(input integer x, input integer y);
        begin
            in_rect = (x >= 200) && (x <= 400) && (y >= 750) && (y <= 850);
        end
    endfunction

    function is_fg(input integer x, input integer y);
        begin
            is_fg = in_circle(x,y) || in_square(x,y) || in_triangle(x,y) || in_rect(x,y);
        end
    endfunction

    function is_noise(input integer x, input integer y);
        begin
            is_noise = ((x==101 && y==101) || (x==303 && y==303) ||
                        (x==505 && y==505) || (x==707 && y==707) ||
                        (x==909 && y==909) || (x==1111 && y==1111));
        end
    endfunction

    function is_small(input integer x, input integer y);
        begin
            is_small = (x >= 1160) && (x <= 1199) && (y >= 700) && (y <= 739);
        end
    endfunction

    task send_line(input integer y);
        integer c;
        begin
            for (c = 0; c < HP; c = c + 1) begin
                i_de = 1'b1;
                i_g0 = is_fg(2*c, y) ? 8'd0 : 8'd255;
                i_g1 = is_fg(2*c+1, y) ? 8'd0 : 8'd255;
                @(negedge clk);
            end
            i_de = 1'b0;
            i_g0 = 8'd255; i_g1 = 8'd255;
            repeat (40) @(negedge clk);
        end
    endtask

    task send_frame_shapes;
        integer y;
        begin
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            for (y = 0; y < VL; y = y + 1) send_line(y);
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            while (!o_done) @(posedge clk);
        end
    endtask

    task send_frame_empty;
        integer y;
        integer c;
        begin
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            for (y = 0; y < VL; y = y + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1; i_g0 = 8'd255; i_g1 = 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0;
                i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            while (!o_done) @(posedge clk);
        end
    endtask

    task send_frame_noise;
        integer y;
        integer c;
        begin
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            for (y = 0; y < VL; y = y + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = is_noise(2*c, y) ? 8'd0 : 8'd255;
                    i_g1 = is_noise(2*c+1, y) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0;
                i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            while (!o_done) @(posedge clk);
        end
    endtask

    task send_frame_small;
        integer y;
        integer c;
        begin
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            for (y = 0; y < VL; y = y + 1) begin
                for (c = 0; c < HP; c = c + 1) begin
                    i_de = 1'b1;
                    i_g0 = is_small(2*c, y) ? 8'd0 : 8'd255;
                    i_g1 = is_small(2*c+1, y) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0;
                i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            while (!o_done) @(posedge clk);
        end
    endtask

    integer k;
    reg [10:0] bx0, bx1, by0, by1;
    reg [15:0] ar;
    reg [26:0] sxv, syv;
    initial begin
        rst_n = 0;
        last_c = 4'hF; cyc = 0;
        dbgcnt = 0;
        dbg2 = 0;
        repeat (10) @(negedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        send_frame_shapes;
        #1;
        $display("SHAPES: num=%0d valid=%b", o_num, o_valid);
        for (k = 0; k < 4; k = k + 1) begin
            bx0 = (o_bx0 >> (11*k)) & 11'h7FF;
            bx1 = (o_bx1 >> (11*k)) & 11'h7FF;
            by0 = (o_by0 >> (11*k)) & 11'h7FF;
            by1 = (o_by1 >> (11*k)) & 11'h7FF;
            ar  = (o_area >> (16*k)) & 16'hFFFF;
            sxv = (o_sx >> (27*k)) & 27'h7FFFFFF;
            syv = (o_sy >> (27*k)) & 27'h7FFFFFF;
            $display("  cand%0d: bbox=(%0d,%0d)-(%0d,%0d) area=%0d ctr=(%0d,%0d)",
                     k, bx0, by0, bx1, by1, ar,
                     (ar != 0) ? (sxv/ar) : 0, (ar != 0) ? (syv/ar) : 0);
        end

        send_frame_empty;
        #1;
        $display("EMPTY: num=%0d valid=%b", o_num, o_valid);

        send_frame_noise;
        #1;
        $display("NOISE: num=%0d valid=%b", o_num, o_valid);

        send_frame_small;
        #1;
        $display("SMALL: num=%0d valid=%b", o_num, o_valid);
        for (k = 0; k < 4; k = k + 1) begin
            bx0 = (o_bx0 >> (11*k)) & 11'h7FF;
            bx1 = (o_bx1 >> (11*k)) & 11'h7FF;
            by0 = (o_by0 >> (11*k)) & 11'h7FF;
            by1 = (o_by1 >> (11*k)) & 11'h7FF;
            ar  = (o_area >> (16*k)) & 16'hFFFF;
            if (ar != 0) $display("  small cand%0d: bbox=(%0d,%0d)-(%0d,%0d) area=%0d",
                                  k, bx0, by0, bx1, by1, ar);
        end

        $finish;
    end

    initial begin
        #120000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
