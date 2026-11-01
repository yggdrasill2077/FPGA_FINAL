`timescale 1ns/1ps
module tb_sched_unknown_F36;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg i_grid_done = 1'b0;
    reg [2:0] i_num = 3'd4;
    reg [3:0] i_valid = 4'b0000;
    reg [63:0] i_area = 64'd0;
    reg [107:0] i_sx = 108'd0, i_sy = 108'd0;
    reg [43:0] i_bx0 = 44'd0, i_bx1 = 44'd0, i_by0 = 44'd0, i_by1 = 44'd0;
    reg i_pol_upd = 1'b0;
    reg [2:0] i_pol_cls = 3'd0;

    wire o_start;
    wire [1:0] o_sel;
    wire [2:0] o_num;
    wire [3:0] o_valid;
    wire [11:0] o_cls;
    wire o_done;
    wire [63:0] o_area;
    wire [107:0] o_sx, o_sy;
    wire [43:0] o_bx0, o_bx1, o_by0, o_by1;
    wire [15:0] sel_area;
    wire [26:0] sel_sx, sel_sy;
    wire [10:0] sel_bx0, sel_bx1, sel_by0, sel_by1;

    shape_multi_sched #(.MAX_CAND(4), .TIMEOUT(1000), .KEEP_UNKNOWN(0)) dut (
        .clk(clk), .rst_n(rst_n),
        .i_grid_done(i_grid_done), .i_num(i_num), .i_valid(i_valid),
        .i_area(i_area), .i_sx(i_sx), .i_sy(i_sy),
        .i_bx0(i_bx0), .i_bx1(i_bx1), .i_by0(i_by0), .i_by1(i_by1),
        .i_pol_upd(i_pol_upd), .i_pol_cls(i_pol_cls),
        .o_start(o_start), .o_sel(o_sel), .o_num(o_num), .o_valid(o_valid), .o_cls(o_cls),
        .o_area(o_area), .o_sx(o_sx), .o_sy(o_sy),
        .o_bx0(o_bx0), .o_bx1(o_bx1), .o_by0(o_by0), .o_by1(o_by1),
        .o_sel_area(sel_area), .o_sel_sx(sel_sx), .o_sel_sy(sel_sy),
        .o_sel_bx0(sel_bx0), .o_sel_bx1(sel_bx1),
        .o_sel_by0(sel_by0), .o_sel_by1(sel_by1),
        .o_done(o_done)
    );

    integer n;
    initial begin #200000; $display("GLOBAL TIMEOUT state=%0d valid=%b start=%b", dut.state, o_valid, o_start); $finish; end
    reg [2:0] classes [0:3];
    initial begin
        classes[0]=3'd0; classes[1]=3'd2; classes[2]=3'd0; classes[3]=3'd0;
        repeat(10) @(negedge clk);
        rst_n=1'b1;
        repeat(5) @(negedge clk);
        i_valid=4'b1111;
        i_grid_done=1'b1; @(negedge clk); i_grid_done=1'b0;

        for (n=0; n<4; n=n+1) begin
            while (!o_start) @(negedge clk);
            $display("LOOP n=%0d sel=%0d valid=%b state=%0d", n, o_sel, o_valid, dut.state);
            @(negedge clk);

            i_pol_cls = classes[n];
            i_pol_upd = 1'b1;
            @(negedge clk);
            i_pol_upd = 1'b0;
            $display("  sent n=%0d sel=%0d cls=%0d valid=%b", n, o_sel, classes[n], o_valid);
        end
        while (!o_done) @(negedge clk);
        @(negedge clk);
        $display("SCHED num=%0d valid=%b cls=%03x", o_num, o_valid, o_cls);
        if ((o_num == 3'd1) && (o_valid == 4'b0010) && (o_cls[5:3] == 3'd2))
            $display("SCHED UNKNOWN FILTER PASS");
        else
            $display("SCHED UNKNOWN FILTER FAIL");
        $finish;
    end
endmodule









