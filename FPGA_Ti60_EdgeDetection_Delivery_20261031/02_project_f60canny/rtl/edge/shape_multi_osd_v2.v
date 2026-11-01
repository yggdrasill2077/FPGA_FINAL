//==============================================================================
// shape_multi_osd_v2.v -- per-box detection frame + result badge
//
//  Class map (5 bits):
//    0 unknown, 1 circle, 2 square, 3 triangle, 4 cross, 5 rectangle,
//    6..31 = A..Z.
//
//  The badge uses a preloaded 5x7 glyph per candidate, so the 148.5 MHz pixel
//  path contains only geometry comparators and a five-way bit select.
//==============================================================================
module shape_multi_osd_v2 #(
    parameter integer SHOW_UNKNOWN = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire [10:0] i_x,
    input  wire [11:0] i_y,
    input  wire [3:0]  i_valid,
    input  wire [19:0] i_cls,
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
    reg [19:0] cls_l;
    reg [11:0] ox0_l [0:3];
    reg [11:0] ox1_l [0:3];
    reg [11:0] oy0_l [0:3];
    reg [11:0] oy1_l [0:3];
    reg [11:0] bxi0_l[0:3];
    reg [11:0] bxi1_l[0:3];
    reg [11:0] byi0_l[0:3];
    reg [11:0] byi1_l[0:3];
    reg [3:0]  bok_l;
    reg [34:0] glyph_l [0:3];

    // ---- frame-level geometry -------------------------------------------
    function [11:0] geo_ox0;
        input [10:0] b0;
        input [5:0]  xoff;
        reg [11:0] raw;
        reg [11:0] sub;
        begin
            raw = (b0 < 11'd480) ? 12'd0 : ({1'b0,b0} - 12'd480 + 12'd3);
            sub = (raw > {6'd0,xoff}) ? (raw - {6'd0,xoff}) : 12'd0;
            geo_ox0 = (sub > 12'd959) ? 12'd959 : sub;
        end
    endfunction

    function [11:0] geo_ox1;
        input [10:0] b1;
        input [5:0]  xoff;
        reg [11:0] raw;
        reg [11:0] sub;
        begin
            raw = (b1 > 11'd1439) ? 12'd959 : ({1'b0,b1} - 12'd480 + 12'd3);
            sub = (raw > {6'd0,xoff}) ? (raw - {6'd0,xoff}) : 12'd0;
            geo_ox1 = (sub > 12'd959) ? 12'd959 : sub;
        end
    endfunction

    function [11:0] geo_oy0;
        input [10:0] c0;
        input [4:0]  yoff;
        begin
            geo_oy0 = ({1'b0,c0} + 12'd1 > {7'd0,yoff}) ?
                      ({1'b0,c0} + 12'd1 - {7'd0,yoff}) : 12'd0;
        end
    endfunction

    function [11:0] geo_oy1;
        input [10:0] c1;
        input [4:0]  yoff;
        begin
            geo_oy1 = ({1'b0,c1} + 12'd1 > {7'd0,yoff}) ?
                      ({1'b0,c1} + 12'd1 - {7'd0,yoff}) : 12'd0;
        end
    endfunction

    function [11:0] geo_bxi0;
        input [11:0] ox1;
        begin
            geo_bxi0 = (ox1 >= 12'd35) ? (ox1 - 12'd34) : 12'd2;
        end
    endfunction

    // ---- 5x7 font ----------------------------------------------------------
    // Shape codes reuse C/S/T/X/R; letter codes 6..31 are A..Z.
    function [4:0] font_row;
        input [4:0] c;
        input [2:0] row;
        begin
            case (c)
            5'd1: case (row) // C
                3'd0: font_row=5'b01111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b10000;
                3'd4: font_row=5'b10000; 3'd5: font_row=5'b10000;
                default: font_row=5'b01111; endcase
            5'd2: case (row) // S
                3'd0: font_row=5'b01111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b01110;
                3'd4: font_row=5'b00001; 3'd5: font_row=5'b00001;
                default: font_row=5'b11110; endcase
            5'd3: case (row) // T
                3'd0: font_row=5'b11111; 3'd1: font_row=5'b00100;
                3'd2: font_row=5'b00100; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b00100; 3'd5: font_row=5'b00100;
                default: font_row=5'b00100; endcase
            5'd4: case (row) // X
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b01010; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b01010; 3'd5: font_row=5'b10001;
                default: font_row=5'b10001; endcase
            5'd5: case (row) // R
                3'd0: font_row=5'b11110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b11110;
                3'd4: font_row=5'b10100; 3'd5: font_row=5'b10010;
                default: font_row=5'b10001; endcase
            5'd6: case (row) // A
                3'd0: font_row=5'b01110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b11111;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b10001; endcase
            5'd7: case (row) // B
                3'd0: font_row=5'b11110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b11110;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b11110; endcase
            5'd8: case (row) // C
                3'd0: font_row=5'b01111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b10000;
                3'd4: font_row=5'b10000; 3'd5: font_row=5'b10000;
                default: font_row=5'b01111; endcase
            5'd9: case (row) // D
                3'd0: font_row=5'b11110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b10001;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b11110; endcase
            5'd10: case (row) // E
                3'd0: font_row=5'b11111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b11110;
                3'd4: font_row=5'b10000; 3'd5: font_row=5'b10000;
                default: font_row=5'b11111; endcase
            5'd11: case (row) // F
                3'd0: font_row=5'b11111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b11110;
                3'd4: font_row=5'b10000; 3'd5: font_row=5'b10000;
                default: font_row=5'b10000; endcase
            5'd12: case (row) // G
                3'd0: font_row=5'b01111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b10111;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b01111; endcase
            5'd13: case (row) // H
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b11111;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b10001; endcase
            5'd14: case (row) // I
                3'd0: font_row=5'b01110; 3'd1: font_row=5'b00100;
                3'd2: font_row=5'b00100; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b00100; 3'd5: font_row=5'b00100;
                default: font_row=5'b01110; endcase
            5'd15: case (row) // J
                3'd0: font_row=5'b00111; 3'd1: font_row=5'b00010;
                3'd2: font_row=5'b00010; 3'd3: font_row=5'b00010;
                3'd4: font_row=5'b00010; 3'd5: font_row=5'b10010;
                default: font_row=5'b01100; endcase
            5'd16: case (row) // K
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10010;
                3'd2: font_row=5'b10100; 3'd3: font_row=5'b11000;
                3'd4: font_row=5'b10100; 3'd5: font_row=5'b10010;
                default: font_row=5'b10001; endcase
            5'd17: case (row) // L
                3'd0: font_row=5'b10000; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b10000;
                3'd4: font_row=5'b10000; 3'd5: font_row=5'b10000;
                default: font_row=5'b11111; endcase
            5'd18: case (row) // M
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b11011;
                3'd2: font_row=5'b10101; 3'd3: font_row=5'b10101;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b10001; endcase
            5'd19: case (row) // N
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b11001;
                3'd2: font_row=5'b10101; 3'd3: font_row=5'b10011;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b10001; endcase
            5'd20: case (row) // O
                3'd0: font_row=5'b01110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b10001;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b01110; endcase
            5'd21: case (row) // P
                3'd0: font_row=5'b11110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b11110;
                3'd4: font_row=5'b10000; 3'd5: font_row=5'b10000;
                default: font_row=5'b10000; endcase
            5'd22: case (row) // Q
                3'd0: font_row=5'b01110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b10001;
                3'd4: font_row=5'b10101; 3'd5: font_row=5'b10010;
                default: font_row=5'b01101; endcase
            5'd23: case (row) // R
                3'd0: font_row=5'b11110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b11110;
                3'd4: font_row=5'b10100; 3'd5: font_row=5'b10010;
                default: font_row=5'b10001; endcase
            5'd24: case (row) // S
                3'd0: font_row=5'b01111; 3'd1: font_row=5'b10000;
                3'd2: font_row=5'b10000; 3'd3: font_row=5'b01110;
                3'd4: font_row=5'b00001; 3'd5: font_row=5'b00001;
                default: font_row=5'b11110; endcase
            5'd25: case (row) // T
                3'd0: font_row=5'b11111; 3'd1: font_row=5'b00100;
                3'd2: font_row=5'b00100; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b00100; 3'd5: font_row=5'b00100;
                default: font_row=5'b00100; endcase
            5'd26: case (row) // U
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b10001;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b10001;
                default: font_row=5'b01110; endcase
            5'd27: case (row) // V
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b10001;
                3'd4: font_row=5'b10001; 3'd5: font_row=5'b01010;
                default: font_row=5'b00100; endcase
            5'd28: case (row) // W
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b10001; 3'd3: font_row=5'b10101;
                3'd4: font_row=5'b10101; 3'd5: font_row=5'b10101;
                default: font_row=5'b01010; endcase
            5'd29: case (row) // X
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b01010; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b01010; 3'd5: font_row=5'b10001;
                default: font_row=5'b10001; endcase
            5'd30: case (row) // Y
                3'd0: font_row=5'b10001; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b01010; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b00100; 3'd5: font_row=5'b00100;
                default: font_row=5'b00100; endcase
            5'd31: case (row) // Z
                3'd0: font_row=5'b11111; 3'd1: font_row=5'b00001;
                3'd2: font_row=5'b00010; 3'd3: font_row=5'b00100;
                3'd4: font_row=5'b01000; 3'd5: font_row=5'b10000;
                default: font_row=5'b11111; endcase
            default: case (row) // ?
                3'd0: font_row=5'b01110; 3'd1: font_row=5'b10001;
                3'd2: font_row=5'b00001; 3'd3: font_row=5'b00010;
                3'd4: font_row=5'b00100; 3'd5: font_row=5'b00000;
                default: font_row=5'b00100; endcase
            endcase
        end
    endfunction

    // 7 rows x 5 columns packed into 35 bits ([4:0] = row 0).
    // NOTE: the return width must be [34:0]; a 5-bit return silently kept only
    // row 0, which is why the badge showed a single dash.
    function [34:0] glyph_bits;
        input [4:0] c;
        begin
            glyph_bits = {font_row(c,3'd6), font_row(c,3'd5),
                          font_row(c,3'd4), font_row(c,3'd3),
                          font_row(c,3'd2), font_row(c,3'd1),
                          font_row(c,3'd0)};
        end
    endfunction

    function [2:0] div3;
        input [4:0] v;
        begin
            if      (v < 5'd3)  div3 = 3'd0;
            else if (v < 5'd6)  div3 = 3'd1;
            else if (v < 5'd9)  div3 = 3'd2;
            else if (v < 5'd12) div3 = 3'd3;
            else if (v < 5'd15) div3 = 3'd4;
            else if (v < 5'd18) div3 = 3'd5;
            else                div3 = 3'd6;
        end
    endfunction

    function [23:0] cls_color;
        input [4:0] c;
        begin
            case (c)
            5'd1: cls_color = 24'hFF_FF_FF; // circle
            5'd2: cls_color = 24'h00_FF_FF; // square
            5'd3: cls_color = 24'hFF_FF_00; // triangle
            5'd4: cls_color = 24'h00_FF_00; // cross
            5'd5: cls_color = 24'hFF_00_FF; // rectangle
            default: cls_color = (c >= 5'd6) ? 24'hFF_A0_20 : 24'hC0_C0_C0;
            endcase
        end
    endfunction

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_l <= 4'd0;
            cls_l <= 20'd0;
            for (k = 0; k < 4; k = k + 1) begin
                ox0_l[k] <= 12'd0; ox1_l[k] <= 12'd0;
                oy0_l[k] <= 12'd0; oy1_l[k] <= 12'd0;
                bxi0_l[k] <= 12'd0; bxi1_l[k] <= 12'd32;
                byi0_l[k] <= 12'd0; byi1_l[k] <= 12'd32;
                glyph_l[k] <= 35'b01110_10001_00001_00010_00100_00000_00100;
            end
            bok_l <= 4'd0;
        end else if (i_vs) begin
            vld_l <= i_valid & {
                (SHOW_UNKNOWN || (i_cls[19:15] != 5'd0)),
                (SHOW_UNKNOWN || (i_cls[14:10] != 5'd0)),
                (SHOW_UNKNOWN || (i_cls[9:5]   != 5'd0)),
                (SHOW_UNKNOWN || (i_cls[4:0]   != 5'd0)) };
            cls_l <= i_cls;
            for (k = 0; k < 4; k = k + 1) begin
                ox0_l[k] <= geo_ox0(i_bx0[11*k +: 11], i_xoff);
                ox1_l[k] <= geo_ox1(i_bx1[11*k +: 11], i_xoff);
                oy0_l[k] <= geo_oy0(i_by0[11*k +: 11], i_yoff);
                oy1_l[k] <= geo_oy1(i_by1[11*k +: 11], i_yoff);
                bxi0_l[k] <= geo_bxi0(geo_ox1(i_bx1[11*k +: 11], i_xoff));
                bxi1_l[k] <= geo_bxi0(geo_ox1(i_bx1[11*k +: 11], i_xoff)) + 12'd32;
                byi0_l[k] <= geo_oy0(i_by0[11*k +: 11], i_yoff) + 12'd3;
                byi1_l[k] <= geo_oy0(i_by0[11*k +: 11], i_yoff) + 12'd35;
                bok_l[k]  <= (i_bx1[11*k +: 11] >  i_bx0[11*k +: 11]) &&
                             (i_by1[11*k +: 11] >  i_by0[11*k +: 11]) &&
                             (i_bx1[11*k +: 11] >= 11'd480) &&
                             (i_bx0[11*k +: 11] <  11'd960);
                glyph_l[k] <= glyph_bits(i_cls[5*k +: 5]);
            end
        end
    end

    wire [3:0] cand_on;
    wire [23:0] cand_rgb [0:3];
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : G_BOX
            wire [11:0] ox0 = ox0_l[gi];
            wire [11:0] ox1 = ox1_l[gi];
            wire [11:0] oy0 = oy0_l[gi];
            wire [11:0] oy1 = oy1_l[gi];
            wire [11:0] bxi0 = bxi0_l[gi];
            wire [11:0] bxi1 = bxi1_l[gi];
            wire [11:0] byi0 = byi0_l[gi];
            wire [11:0] byi1 = byi1_l[gi];
            wire box_ok = bok_l[gi] && (i_x < 11'd960);
            wire in_box = ({1'b0,i_x} >= ox0) && ({1'b0,i_x} <= ox1) &&
                          ({1'b0,i_y} >= oy0) && ({1'b0,i_y} <= oy1);
            wire edge_px = ({1'b0,i_x} <= ox0 + 12'd1) ||
                           ({1'b0,i_x} + 12'd1 >= ox1) ||
                           ({1'b0,i_y} <= oy0 + 12'd1) ||
                           ({1'b0,i_y} + 12'd1 >= oy1);

            wire [11:0] idx  = {1'b0,i_x} - bxi0;
            wire [11:0] idy  = {1'b0,i_y} - byi0;
            wire badge_px = ({1'b0,i_x} >= bxi0) && ({1'b0,i_x} < bxi1) &&
                            ({1'b0,i_y} >= byi0) && ({1'b0,i_y} < byi1);
            wire badge_frame = badge_px &&
                               ((idx == 12'd0) || (idx == 12'd31) ||
                                (idy == 12'd0) || (idy == 12'd31));
            wire [11:0] gx = idx - 12'd6;
            wire [11:0] gy = idy - 12'd5;
            wire [2:0]  grow_i = div3(gy[4:0]);
            wire [4:0]  grow = glyph_l[gi][5*grow_i +: 5];
            wire [2:0]  gcol_i = gx[4:2];
            wire        icon_bit = grow[4 - gcol_i];
            wire icon_px = badge_px && (gx < 12'd20) && (gy < 12'd21) && icon_bit;

            assign cand_on[gi] = vld_l[gi] && box_ok &&
                                 ((in_box && edge_px) || badge_px);
            assign cand_rgb[gi] = (badge_px && !icon_px && !badge_frame) ?
                                  24'h10_10_10 : cls_color(cls_l[5*gi +: 5]);
        end
    endgenerate

    always @* begin
        o_r = 8'd0; o_g = 8'd0; o_b = 8'd0; o_on = 1'b0;
        if (cand_on[3]) begin o_r=cand_rgb[3][23:16]; o_g=cand_rgb[3][15:8]; o_b=cand_rgb[3][7:0]; o_on=1'b1; end
        if (cand_on[2]) begin o_r=cand_rgb[2][23:16]; o_g=cand_rgb[2][15:8]; o_b=cand_rgb[2][7:0]; o_on=1'b1; end
        if (cand_on[1]) begin o_r=cand_rgb[1][23:16]; o_g=cand_rgb[1][15:8]; o_b=cand_rgb[1][7:0]; o_on=1'b1; end
        if (cand_on[0]) begin o_r=cand_rgb[0][23:16]; o_g=cand_rgb[0][15:8]; o_b=cand_rgb[0][7:0]; o_on=1'b1; end
    end

endmodule
