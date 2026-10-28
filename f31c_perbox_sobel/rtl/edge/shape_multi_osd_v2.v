//==============================================================================
// shape_multi_osd_v2.v -- per-box detection frame + result badge
//
//  Pipeline visualisation: every candidate owns one scan box; the class result
//  is drawn as a small colour-coded icon in the upper-right corner of that box.
//  No global/fixed-position class icon is used, so multiple results cannot be
//  confused with one another.
//
//  Colour: circle=white, square=cyan, triangle=yellow, cross=green,
//          rectangle=magenta, unknown=grey.
//==============================================================================
module shape_multi_osd_v2 (
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
            for (k = 0; k < 4; k = k + 1) begin
                bx0_l[k] <= 11'd0; bx1_l[k] <= 11'd0;
                by0_l[k] <= 11'd0; by1_l[k] <= 11'd0;
            end
        end else if (i_vs) begin
            vld_l <= i_valid;
            cls_l <= i_cls;
            for (k = 0; k < 4; k = k + 1) begin
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
            default: cls_color = 24'hC0_C0_C0; // unknown
            endcase
        end
    endfunction

    // 3x5 pixel letters, rendered as 8x4 cells.  This deliberately avoids
    // multipliers: the OSD sits directly on the 148.5 MHz pixel path.
    //   C=circle S=square T=triangle X=cross R=rectangle ?=unknown
    function [2:0] glyph_row;
        input [2:0] c;
        input [2:0] row;
        begin
            case (c)
            3'd1: case (row) 3'd0:glyph_row=3'b111; 3'd1:glyph_row=3'b100;
                             3'd2:glyph_row=3'b100; 3'd3:glyph_row=3'b100;
                             default:glyph_row=3'b111; endcase
            3'd2: case (row) 3'd0:glyph_row=3'b111; 3'd1:glyph_row=3'b100;
                             3'd2:glyph_row=3'b111; 3'd3:glyph_row=3'b001;
                             default:glyph_row=3'b111; endcase
            3'd3: case (row) 3'd0:glyph_row=3'b111; 3'd1:glyph_row=3'b010;
                             3'd2:glyph_row=3'b010; 3'd3:glyph_row=3'b010;
                             default:glyph_row=3'b010; endcase
            3'd4: case (row) 3'd0:glyph_row=3'b101; 3'd1:glyph_row=3'b101;
                             3'd2:glyph_row=3'b010; 3'd3:glyph_row=3'b101;
                             default:glyph_row=3'b101; endcase
            3'd5: case (row) 3'd0:glyph_row=3'b110; 3'd1:glyph_row=3'b101;
                             3'd2:glyph_row=3'b110; 3'd3:glyph_row=3'b101;
                             default:glyph_row=3'b101; endcase
            default: case (row) 3'd0:glyph_row=3'b111; 3'd1:glyph_row=3'b001;
                             3'd2:glyph_row=3'b010; 3'd3:glyph_row=3'b000;
                             default:glyph_row=3'b010; endcase
            endcase
        end
    endfunction

    function glyph_px;
        input [2:0] c;
        input [2:0] row;
        input [1:0] col;
        reg [2:0] pat;
        begin
            pat = glyph_row(c, row);
            case (col)
            2'd0: glyph_px = pat[2];
            2'd1: glyph_px = pat[1];
            default: glyph_px = pat[0];
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

            // Camera centre crop x=480..1439 -> output x=0..959.
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
                          (ox1 > ox0) && (oy1 > oy0) && (i_x < 11'd960);
            wire in_box = ({1'b0,i_x} >= ox0) && ({1'b0,i_x} <= ox1) &&
                          ({1'b0,i_y} >= oy0) && ({1'b0,i_y} <= oy1);
            wire edge_px = ({1'b0,i_x} <= ox0 + 12'd1) ||
                           ({1'b0,i_x} + 12'd1 >= ox1) ||
                           ({1'b0,i_y} <= oy0 + 12'd1) ||
                           ({1'b0,i_y} + 12'd1 >= oy1);

            // Badge sits inside the top-right corner; a dark tile keeps the
            // coloured icon readable on both white paper and dark objects.
            wire [11:0] bxi0 = (ox1 >= 12'd35) ? (ox1 - 12'd34) : 12'd2;
            wire [11:0] byi0 = oy0 + 12'd3;
            wire [11:0] idx  = {1'b0,i_x} - bxi0;
            wire [11:0] idy  = {1'b0,i_y} - byi0;
            wire badge_px = ({1'b0,i_x} >= bxi0) && ({1'b0,i_x} < bxi0 + 12'd32) &&
                            ({1'b0,i_y} >= byi0) && ({1'b0,i_y} < byi0 + 12'd32);
            wire badge_frame = badge_px &&
                               ((idx == 12'd0) || (idx == 12'd31) ||
                                (idy == 12'd0) || (idy == 12'd31));
            wire [11:0] gx = idx - 12'd8;
            wire [11:0] gy = idy - 12'd6;
            wire icon_px = badge_px && (gx < 12'd24) && (gy < 12'd20) &&
                           glyph_px(cls_l[3*gi +: 3], gy[4:2], gx[4:3]);

            assign cand_on[gi] = vld_l[gi] && box_ok &&
                                 ((in_box && edge_px) || badge_px);
            assign cand_rgb[gi] = (badge_px && !icon_px && !badge_frame) ?
                                  24'h10_10_10 : cls_color(cls_l[3*gi +: 3]);
        end
    endgenerate

    // Lowest candidate index has priority if boxes overlap.
    always @* begin
        o_r = 8'd0; o_g = 8'd0; o_b = 8'd0; o_on = 1'b0;
        if (cand_on[3]) begin o_r=cand_rgb[3][23:16]; o_g=cand_rgb[3][15:8]; o_b=cand_rgb[3][7:0]; o_on=1'b1; end
        if (cand_on[2]) begin o_r=cand_rgb[2][23:16]; o_g=cand_rgb[2][15:8]; o_b=cand_rgb[2][7:0]; o_on=1'b1; end
        if (cand_on[1]) begin o_r=cand_rgb[1][23:16]; o_g=cand_rgb[1][15:8]; o_b=cand_rgb[1][7:0]; o_on=1'b1; end
        if (cand_on[0]) begin o_r=cand_rgb[0][23:16]; o_g=cand_rgb[0][15:8]; o_b=cand_rgb[0][7:0]; o_on=1'b1; end
    end

endmodule
