//==============================================================================
// shape_multi_osd.v -- four-candidate box overlay for the left grayscale half
//
//  The camera is centre-cropped to x=480..1439 before being displayed on the
//  left half.  The existing single-target OSD uses the empirically aligned
//  -477 offset; this module keeps the same offset and additionally clamps each
//  box to the left-half visible range.  Box colour encodes the class:
//    circle=white, square=cyan, triangle=yellow, cross=green, rect=magenta.
//==============================================================================
module shape_multi_osd (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire [10:0] i_x,
    input  wire [11:0] i_y,
    input  wire [3:0]  i_valid,
    input  wire [11:0] i_cls,
    input  wire [43:0] i_bx0,
    input  wire [43:0] i_bx1,
    input  wire [43:0] i_by0,
    input  wire [43:0] i_by1,
    input  wire [5:0]  i_xoff,
    input  wire [4:0]  i_yoff,
    output reg  [7:0]  o_r,
    output reg  [7:0]  o_g,
    output reg  [7:0]  o_b,
    output reg         o_on
);

    reg [3:0]  vld_l;
    reg [11:0] cls_l;
    reg [10:0] bx0_l [0:3];
    reg [10:0] bx1_l [0:3];
    reg [10:0] by0_l [0:3];
    reg [10:0] by1_l [0:3];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_l <= 4'd0;
            cls_l <= 12'd0;
            for (k=0; k<4; k=k+1) begin
                bx0_l[k] <= 11'd0; bx1_l[k] <= 11'd0;
                by0_l[k] <= 11'd0; by1_l[k] <= 11'd0;
            end
        end else if (i_vs) begin
            vld_l <= i_valid;
            cls_l <= i_cls;
            for (k=0; k<4; k=k+1) begin
                bx0_l[k] <= i_bx0[11*k +: 11];
                bx1_l[k] <= i_bx1[11*k +: 11];
                by0_l[k] <= i_by0[11*k +: 11];
                by1_l[k] <= i_by1[11*k +: 11];
            end
        end
    end

    function [23:0] cls_color;
        input [2:0] c;
        begin
            case (c)
            3'd1: cls_color = 24'hFF_FF_FF; // circle
            3'd2: cls_color = 24'h00_FF_FF; // square
            3'd3: cls_color = 24'hFF_FF_00; // triangle
            3'd4: cls_color = 24'h00_FF_00; // cross
            3'd5: cls_color = 24'hFF_00_FF; // rectangle
            default: cls_color = 24'h80_80_80;
            endcase
        end
    endfunction

    wire [3:0] cand_on;
    wire [23:0] cand_rgb [0:3];
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : G_BOX
            wire [10:0] b0 = bx0_l[gi];
            wire [10:0] b1 = bx1_l[gi];
            wire [10:0] c0 = by0_l[gi];
            wire [10:0] c1 = by1_l[gi];

            // Horizontal centre crop: camera 480..1439 -> output 0..959.
            wire [11:0] raw0 = (b0 < 11'd480) ? 12'd0 :
                               ({1'b0,b0} - 12'd480 + 12'd3);
            wire [11:0] raw1 = (b1 > 11'd1439) ? 12'd959 :
                               ({1'b0,b1} - 12'd480 + 12'd3);
            wire [11:0] sub0 = (raw0 > {6'd0,i_xoff}) ? (raw0 - {6'd0,i_xoff}) : 12'd0;
            wire [11:0] sub1 = (raw1 > {6'd0,i_xoff}) ? (raw1 - {6'd0,i_xoff}) : 12'd0;
            wire [11:0] ox0 = (sub0 > 12'd959) ? 12'd959 : sub0;
            wire [11:0] ox1 = (sub1 > 12'd959) ? 12'd959 : sub1;
            wire [11:0] oy0 = ({1'b0,c0} + 12'd1 > {6'd0,i_yoff}) ?
                              ({1'b0,c0} + 12'd1 - {6'd0,i_yoff}) : 12'd0;
            wire [11:0] oy1 = ({1'b0,c1} + 12'd1 > {6'd0,i_yoff}) ?
                              ({1'b0,c1} + 12'd1 - {6'd0,i_yoff}) : 12'd0;

            wire box_ok = (b1 > b0) && (c1 > c0) &&
                          (b1 >= 11'd480) && (b0 <= 11'd1439) &&
                          (ox1 > ox0) && ({1'b0,i_y} > oy0) && ({1'b0,i_y} < oy1);
            wire in_box = ({1'b0,i_x} >= ox0) && ({1'b0,i_x} <= ox1) &&
                          ({1'b0,i_y} >= oy0) && ({1'b0,i_y} <= oy1);
            wire edge_px = ({1'b0,i_x} <= ox0 + 12'd1) ||
                          ({1'b0,i_x} + 12'd1 >= ox1) ||
                          ({1'b0,i_y} <= oy0 + 12'd1) ||
                          ({1'b0,i_y} + 12'd1 >= oy1);

            assign cand_on[gi] = vld_l[gi] && box_ok && in_box && edge_px;
            assign cand_rgb[gi] = cls_color(cls_l[3*gi +: 3]);
        end
    endgenerate

    // Lowest candidate index has priority if boxes overlap.
    always @* begin
        o_r = 8'd0; o_g = 8'd0; o_b = 8'd0; o_on = 1'b0;
        if (cand_on[3]) begin o_r = cand_rgb[3][23:16]; o_g = cand_rgb[3][15:8]; o_b = cand_rgb[3][7:0]; o_on = 1'b1; end
        if (cand_on[2]) begin o_r = cand_rgb[2][23:16]; o_g = cand_rgb[2][15:8]; o_b = cand_rgb[2][7:0]; o_on = 1'b1; end
        if (cand_on[1]) begin o_r = cand_rgb[1][23:16]; o_g = cand_rgb[1][15:8]; o_b = cand_rgb[1][7:0]; o_on = 1'b1; end
        if (cand_on[0]) begin o_r = cand_rgb[0][23:16]; o_g = cand_rgb[0][15:8]; o_b = cand_rgb[0][7:0]; o_on = 1'b1; end
    end

endmodule
