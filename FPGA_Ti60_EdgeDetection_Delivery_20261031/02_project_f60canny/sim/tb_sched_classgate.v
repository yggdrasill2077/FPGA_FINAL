`timescale 1ns/1ps
module tb_sched_classgate;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        i_grid_done = 1'b0;
    reg [2:0]  i_num = 3'd0;
    reg [3:0]  i_valid = 4'd0;
    reg [63:0] i_area = 64'd0;
    reg [107:0] i_sx = 108'd0;
    reg [107:0] i_sy = 108'd0;
    reg [43:0] i_bx0 = 44'd0;
    reg [43:0] i_bx1 = 44'd0;
    reg [43:0] i_by0 = 44'd0;
    reg [43:0] i_by1 = 44'd0;
    reg        i_pol_upd = 1'b0;
    reg [2:0]  i_pol_cls = 3'd0;

    wire        o_start;
    wire [1:0]  o_sel;
    wire [2:0]  o_num;
    wire [3:0]  o_valid;
    wire [3:0]  o_show;
    wire [11:0] o_cls;
    wire        o_done;

    shape_multi_sched #(.MAX_CAND(4), .TIMEOUT(12)) dut (
        .clk(clk), .rst_n(rst_n),
        .i_grid_done(i_grid_done), .i_num(i_num), .i_valid(i_valid),
        .i_area(i_area), .i_sx(i_sx), .i_sy(i_sy),
        .i_bx0(i_bx0), .i_bx1(i_bx1), .i_by0(i_by0), .i_by1(i_by1),
        .i_pol_upd(i_pol_upd), .i_pol_cls(i_pol_cls),
        .o_start(o_start), .o_sel(o_sel),
        .o_num(o_num), .o_valid(o_valid), .o_show(o_show), .o_cls(o_cls),
        .o_area(), .o_sx(), .o_sy(),
        .o_bx0(), .o_bx1(), .o_by0(), .o_by1(),
        .o_sel_area(), .o_sel_sx(), .o_sel_sy(),
        .o_sel_bx0(), .o_sel_bx1(), .o_sel_by0(), .o_sel_by1(),
        .o_done(o_done)
    );

    integer errors = 0;

    task pulse_grid;
        begin
            @(negedge clk);
            i_grid_done = 1'b1;
            @(negedge clk);
            i_grid_done = 1'b0;
        end
    endtask

    task answer_candidate(input [2:0] cls);
        begin
            wait (o_start);
            if (o_show !== 4'b0000) begin
                $display("FAIL: o_show became visible before frame done: %b", o_show);
                errors = errors + 1;
            end
            @(negedge clk);
            i_pol_cls = cls;
            i_pol_upd = 1'b1;
            @(negedge clk);
            i_pol_upd = 1'b0;
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        // Four candidates: classes 1, 0, 2, 0 -> only candidates 0 and 2 display.
        i_num = 3'd4;
        i_valid = 4'b1111;
        pulse_grid();
        answer_candidate(3'd1);
        answer_candidate(3'd0);
        answer_candidate(3'd2);
        answer_candidate(3'd0);
        wait (o_done);
        @(negedge clk);
        $display("CLASS GATE A valid=%b show=%b cls=%03x", o_valid, o_show, o_cls);
        if (o_valid !== 4'b1111) begin $display("FAIL: internal valid mask modified"); errors=errors+1; end
        if (o_show !== 4'b0101) begin $display("FAIL: expected show=0101"); errors=errors+1; end
        if (o_cls !== 12'h081) begin $display("FAIL: expected cls=081"); errors=errors+1; end

        // All candidates unknown -> no visible box.
        i_num = 3'd2;
        i_valid = 4'b0011;
        pulse_grid();
        answer_candidate(3'd0);
        answer_candidate(3'd0);
        wait (o_done);
        @(negedge clk);
        $display("CLASS GATE B valid=%b show=%b", o_valid, o_show);
        if (o_show !== 4'b0000) begin $display("FAIL: unknown candidates are visible"); errors=errors+1; end

        // Classifier timeout -> candidate remains internal, never visible.
        i_num = 3'd1;
        i_valid = 4'b0001;
        pulse_grid();
        wait (o_done);
        @(negedge clk);
        $display("CLASS GATE T valid=%b show=%b", o_valid, o_show);
        if (o_valid !== 4'b0001) begin $display("FAIL: timeout lost internal candidate"); errors=errors+1; end
        if (o_show !== 4'b0000) begin $display("FAIL: timeout candidate is visible"); errors=errors+1; end

        if (errors == 0) $display("RESULT: 0 ERROR(S)");
        else             $display("RESULT: %0d ERROR(S)", errors);
        $finish;
    end
endmodule
