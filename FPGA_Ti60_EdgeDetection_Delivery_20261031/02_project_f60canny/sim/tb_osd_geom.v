`timescale 1ns/1ps

module tb_osd_geom;
  reg clk = 0;
  reg rst_n = 0;
  reg i_vs = 0;
  reg [10:0] i_x = 0;
  reg [11:0] i_y = 0;
  reg [3:0]  i_valid = 4'b0001;
  reg [11:0] i_cls = 12'd1;
  reg [43:0] i_bx0 = 44'd0;
  reg [43:0] i_bx1 = 44'd0;
  reg [43:0] i_by0 = 44'd0;
  reg [43:0] i_by1 = 44'd0;
  reg [5:0]  i_xoff = 6'd0;
  reg [4:0]  i_yoff = 5'd0;

  wire [7:0] o_r, o_g, o_b;
  wire o_on;

  integer errors = 0;

  shape_multi_osd_v2 dut (
    .clk(clk), .rst_n(rst_n), .i_vs(i_vs),
    .i_x(i_x), .i_y(i_y), .i_valid(i_valid), .i_cls(i_cls),
    .i_bx0(i_bx0), .i_bx1(i_bx1), .i_by0(i_by0), .i_by1(i_by1),
    .i_xoff(i_xoff), .i_yoff(i_yoff),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_on(o_on)
  );

  always #5 clk = ~clk;

  task check_on;
    input [10:0] x;
    input [11:0] y;
    input exp;
    begin
      i_x = x; i_y = y; #20;
      if (o_on !== exp) begin
        $display("FAIL (%0d,%0d) on=%b expected=%b", x, y, o_on, exp);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    i_bx0[10:0] = 11'd500;  i_bx1[10:0] = 11'd900;
    i_by0[10:0] = 11'd100;  i_by1[10:0] = 11'd300;

    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk); i_vs = 1;
    repeat (3) @(negedge clk);
    i_vs = 0;
    repeat (2) @(negedge clk);

    // ox0=23 ox1=423 oy0=101 oy1=301
    check_on(11'd23, 12'd200, 1'b1);   // left edge
    check_on(11'd423,12'd200, 1'b1);   // right edge
    check_on(11'd200,12'd101, 1'b1);   // top edge
    check_on(11'd200,12'd301, 1'b1);   // bottom edge
    check_on(11'd200,12'd200, 1'b0);   // interior, not an edge
    check_on(11'd460,12'd400, 1'b0);   // outside

    // badge x 389..420, y 104..135; circle icon is white
    check_on(11'd400,12'd120, 1'b1);
    if (o_r !== 8'hFF || o_g !== 8'hFF || o_b !== 8'hFF) begin
      $display("FAIL badge icon rgb=%h/%h/%h expected FFFFFF", o_r, o_g, o_b);
      errors = errors + 1;
    end
    check_on(11'd390,12'd105, 1'b1);   // dark tile corner
    if (o_r !== 8'h10 || o_g !== 8'h10 || o_b !== 8'h10) begin
      $display("FAIL badge tile rgb=%h/%h/%h expected 101010", o_r, o_g, o_b);
      errors = errors + 1;
    end

    // invalid box (right edge left of the crop) must never draw
    i_bx0[10:0] = 11'd100; i_bx1[10:0] = 11'd300;
    repeat (2) @(negedge clk); i_vs = 1;
    repeat (3) @(negedge clk);
    i_vs = 0; repeat (2) @(negedge clk);
    check_on(11'd200,12'd200, 1'b0);

    // unknown class (cls=0) must not draw a box at all
    i_bx0[10:0] = 11'd500; i_bx1[10:0] = 11'd900;
    i_by0[10:0] = 11'd100; i_by1[10:0] = 11'd300;
    i_cls = 12'd0;
    repeat (2) @(negedge clk); i_vs = 1;
    repeat (3) @(negedge clk);
    i_vs = 0; repeat (2) @(negedge clk);
    check_on(11'd23, 12'd200, 1'b0);
    i_cls = 12'd1;
    repeat (2) @(negedge clk); i_vs = 1;
    repeat (3) @(negedge clk);
    i_vs = 0; repeat (2) @(negedge clk);
    check_on(11'd23, 12'd200, 1'b1);

    if (errors == 0) $display("PASS osd_geom");
    $finish;
  end
endmodule
