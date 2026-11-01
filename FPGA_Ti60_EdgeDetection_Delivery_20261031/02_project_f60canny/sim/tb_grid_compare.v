`timescale 1ns/1ps
module tb_grid_compare;
    localparam integer HP = 960;
    localparam integer VL = 1080;

    reg clk = 0;
    reg rst_n = 0;
    reg i_de = 0;
    reg i_vs = 0;
    reg [7:0] i_g0 = 8'd255;
    reg [7:0] i_g1 = 8'd255;
    reg [7:0] i_ty = 8'd128;

    wire [2:0] n16, n32;
    wire [3:0] v16, v32;
    wire [43:0] b016,b116,y016,y116,b032,b132,y032,y132;
    wire [107:0] sx16,sy16,sx32,sy32;
    wire [63:0] a16,a32;
    wire d16,d32;
    reg done16_seen, done32_seen;
    always @(posedge clk) begin
        if (d16) done16_seen <= 1'b1;
        if (d32) done32_seen <= 1'b1;
    end

    shape_grid_multi_v2 #(
        .H_PAIRS(HP), .V_LINES(VL), .GRID_X(16), .GRID_Y(9),
        .CELL_SEED_MIN(8), .CELL_MERGE_MIN(2), .MIN_AREA(32), .MIN_BBOX(8),
        .FILL_MIN(4), .MERGE_GAP(1)
    ) dut16 (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(i_ty),
        .i_gate_en(1'b0), .i_gx0(11'd0), .i_gx1(11'd0),
        .i_gy0(11'd0), .i_gy1(11'd0),
        .o_num(n16), .o_valid(v16),
        .o_bx0(b016), .o_bx1(b116), .o_by0(y016), .o_by1(y116),
        .o_sx(sx16), .o_sy(sy16), .o_area(a16), .o_done(d16)
    );

    shape_grid_multi_v2 #(
        .H_PAIRS(HP), .V_LINES(VL), .GRID_X(32), .GRID_Y(18),
        .CELL_SEED_MIN(4), .CELL_MERGE_MIN(1), .MIN_AREA(32), .MIN_BBOX(8),
        .FILL_MIN(4), .MERGE_GAP(1)
    ) dut32 (
        .clk(clk), .rst_n(rst_n), .i_de(i_de), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_ty(i_ty),
        .i_gate_en(1'b0), .i_gx0(11'd0), .i_gx1(11'd0),
        .i_gy0(11'd0), .i_gy1(11'd0),
        .o_num(n32), .o_valid(v32),
        .o_bx0(b032), .o_bx1(b132), .o_by0(y032), .o_by1(y132),
        .o_sx(sx32), .o_sy(sy32), .o_area(a32), .o_done(d32)
    );

    always #5 clk = ~clk;

    function in_circle(input integer x, input integer y);
        begin in_circle = ((x-300)*(x-300)+(y-300)*(y-300)) <= 80*80; end
    endfunction
    function in_square(input integer x, input integer y);
        begin in_square = (x>=820)&&(x<=980)&&(y>=220)&&(y<=380); end
    endfunction
    function in_triangle(input integer x, input integer y);
        integer half;
        begin
            half = (y-220)/2;
            in_triangle = (y>=220)&&(y<=380)&&(x>=(1500-half))&&(x<=(1500+half));
        end
    endfunction
    function in_rect(input integer x, input integer y);
        begin in_rect = (x>=200)&&(x<=400)&&(y>=750)&&(y<=850); end
    endfunction
    function in_near_a(input integer x, input integer y);
        begin in_near_a = (x>=500)&&(x<=539)&&(y>=500)&&(y<=539); end
    endfunction
    function in_near_b(input integer x, input integer y);
        begin in_near_b = (x>=556)&&(x<=595)&&(y>=500)&&(y<=539); end
    endfunction
    function in_big(input integer x, input integer y);
        begin in_big = (x>=800)&&(x<=1040)&&(y>=600)&&(y<=840); end
    endfunction
    function in_far_a(input integer x, input integer y);
        begin in_far_a = (x>=300)&&(x<=380)&&(y>=800)&&(y<=880); end
    endfunction
    function in_far_b(input integer x, input integer y);
        begin in_far_b = (x>=420)&&(x<=500)&&(y>=800)&&(y<=880); end
    endfunction
    function in_small(input integer x, input integer y);
        begin in_small = (x>=1160)&&(x<=1199)&&(y>=700)&&(y<=739); end
    endfunction

    function is_noise(input integer x, input integer y);
        begin
            is_noise = ((x==101&&y==101)||(x==303&&y==303)||(x==505&&y==505)||
                        (x==707&&y==707)||(x==909&&y==909)||(x==1111&&y==1111)||
                        (x==1501&&y==401)||(x==1703&&y==903));
        end
    endfunction

    function scene_fg(input integer x, input integer y, input integer scene);
        begin
            case (scene)
            0: scene_fg = in_circle(x,y)||in_square(x,y)||in_triangle(x,y)||in_rect(x,y);
            1: scene_fg = 1'b0;
            2: scene_fg = is_noise(x,y);
            3: scene_fg = in_small(x,y);
            4: scene_fg = in_near_a(x,y)||in_near_b(x,y);
            5: scene_fg = in_big(x,y);
            6: scene_fg = in_far_a(x,y)||in_far_b(x,y);
            default: scene_fg = 1'b0;
            endcase
        end
    endfunction

    task send_frame(input integer scene);
        integer y, c;
        begin
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            for (y=0; y<VL; y=y+1) begin
                for (c=0; c<HP; c=c+1) begin
                    i_de = 1'b1;
                    i_g0 = scene_fg(2*c,   y, scene) ? 8'd0 : 8'd255;
                    i_g1 = scene_fg(2*c+1, y, scene) ? 8'd0 : 8'd255;
                    @(negedge clk);
                end
                i_de = 1'b0;
                i_g0 = 8'd255; i_g1 = 8'd255;
                repeat (40) @(negedge clk);
            end
            done16_seen = 1'b0;
            done32_seen = 1'b0;
            i_vs = 1'b1;
            repeat (5) @(negedge clk);
            i_vs = 1'b0;
            while (!(done16_seen && done32_seen)) @(posedge clk);
            #1;
        end
    endtask

    task dump16(input [8*10:1] tag);
        integer k; reg [10:0] x0,x1,z0,z1; reg [15:0] ar;
        begin
            $display("%0s 16x9 num=%0d valid=%b", tag, n16, v16);
            for (k=0;k<4;k=k+1) begin
                x0=(b016>>(11*k))&11'h7FF; x1=(b116>>(11*k))&11'h7FF;
                z0=(y016>>(11*k))&11'h7FF; z1=(y116>>(11*k))&11'h7FF;
                ar=(a16>>(16*k))&16'hFFFF;
                if (ar!=0) $display("  c%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d ctr=(%0d,%0d)",
                    k,x0,z0,x1,z1,ar,((sx16>>(27*k))&27'h7FFFFFF)/ar,
                    ((sy16>>(27*k))&27'h7FFFFFF)/ar);
            end
        end
    endtask

    task dump32(input [8*10:1] tag);
        integer k; reg [10:0] x0,x1,z0,z1; reg [15:0] ar;
        begin
            $display("%0s 32x18 num=%0d valid=%b", tag, n32, v32);
            for (k=0;k<4;k=k+1) begin
                x0=(b032>>(11*k))&11'h7FF; x1=(b132>>(11*k))&11'h7FF;
                z0=(y032>>(11*k))&11'h7FF; z1=(y132>>(11*k))&11'h7FF;
                ar=(a32>>(16*k))&16'hFFFF;
                if (ar!=0) $display("  c%0d bbox=(%0d,%0d)-(%0d,%0d) area=%0d ctr=(%0d,%0d)",
                    k,x0,z0,x1,z1,ar,((sx32>>(27*k))&27'h7FFFFFF)/ar,
                    ((sy32>>(27*k))&27'h7FFFFFF)/ar);
            end
        end
    endtask

    initial begin
        rst_n=0;
        repeat(10) @(negedge clk);
        rst_n=1;
        repeat(10) @(negedge clk);

        send_frame(0); dump16("FOUR"); dump32("FOUR");
        send_frame(1); dump16("EMPTY"); dump32("EMPTY");
        send_frame(2); dump16("NOISE"); dump32("NOISE");
        send_frame(3); dump16("SMALL"); dump32("SMALL");
        send_frame(4); dump16("NEAR"); dump32("NEAR");
        send_frame(5); dump16("BIG"); dump32("BIG");
        send_frame(6); dump16("FAR"); dump32("FAR");
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
