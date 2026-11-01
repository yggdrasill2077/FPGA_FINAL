//==============================================================================
// shape_paper_gate.v -- bright paper/display carrier gate
//
// A 4x4 sample grid accumulates the bbox and fill of bright pixels.  The
// previous frame's bbox is eroded before it is used, so the paper edge itself
// cannot become a foreground shape.  Only pixels inside this rectangle are
// allowed to feed the dark-ink detector.
//==============================================================================
module shape_paper_gate #(
    parameter integer H_PAIRS    = 960,
    parameter integer V_LINES    = 1080,
    parameter integer ERODE_PX   = 8,
    parameter integer MIN_SAMPLES= 32,
    parameter integer MIN_SIZE   = 32,
    parameter integer FILL_MIN   = 64,
    parameter integer HOLD_FRAMES= 6
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_g1,
    input  wire [7:0]  i_ty,
    output reg         o_valid,
    output reg  [10:0] o_bx0,
    output reg  [10:0] o_bx1,
    output reg  [10:0] o_by0,
    output reg  [10:0] o_by1,
    output wire        o_cur_inside
);
    reg [9:0]  pcol;
    reg [11:0] row;
    reg        de_d;
    reg        vs_d;
    wire       vs_rise = i_vs & ~vs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol <= 10'd0; row <= 12'd0; de_d <= 1'b0; vs_d <= 1'b0;
        end else begin
            de_d <= i_de;
            vs_d <= i_vs;
            if (i_vs)
                row <= 12'd0;
            else if (de_d && !i_de)
                row <= row + 12'd1;

            if (!i_de)
                pcol <= 10'd0;
            else if (pcol == (H_PAIRS-1))
                pcol <= 10'd0;
            else
                pcol <= pcol + 10'd1;
        end
    end

    wire [11:0] x0p = {1'b0, pcol, 1'b0};
    wire [11:0] x1p = x0p + 12'd1;
    wire sample_en = i_de && !i_vs &&
                     (row[1:0] == 2'd0) && (pcol[1:0] == 2'd0);
    wire bright0 = (i_g0 >= i_ty);
    wire bright1 = (i_g1 >= i_ty);
    wire any_bright = bright0 || bright1;

    reg [17:0] cnt;
    reg [10:0] minx, maxx, miny, maxy;
    reg [3:0]  hold_cnt;

    wire [10:0] bw = (maxx >= minx) ? (maxx - minx + 11'd1) : 11'd0;
    wire [10:0] bh = (maxy >= miny) ? (maxy - miny + 11'd1) : 11'd0;
    wire [9:0]  bws = bw[9:2] + 10'd1;
    wire [9:0]  bhs = bh[9:2] + 10'd1;
    wire [19:0] bbox_samples = bws * bhs;
    wire [25:0] fill_lhs = {8'd0,cnt} << 8;
    wire [31:0] fill_rhs = {12'd0,bbox_samples} * FILL_MIN[15:0];
    wire base_ok = (cnt >= MIN_SAMPLES) &&
                   (bw >= MIN_SIZE) && (bh >= MIN_SIZE) &&
                   (fill_lhs >= fill_rhs);
    wire erode_ok = (maxx > (minx + ERODE_PX*2)) &&
                    (maxy > (miny + ERODE_PX*2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 18'd0;
            minx <= 11'h7FF; maxx <= 11'd0;
            miny <= 11'h7FF; maxy <= 11'd0;
            hold_cnt <= 4'd0;
            o_valid <= 1'b0;
            o_bx0 <= 11'd0; o_bx1 <= 11'd0;
            o_by0 <= 11'd0; o_by1 <= 11'd0;
        end else if (vs_rise) begin
            if (base_ok && erode_ok) begin
                o_valid <= 1'b1;
                o_bx0   <= minx + ERODE_PX;
                o_bx1   <= maxx - ERODE_PX;
                o_by0   <= miny + ERODE_PX;
                o_by1   <= maxy - ERODE_PX;
                hold_cnt<= HOLD_FRAMES;
            end else if (o_valid && (hold_cnt != 4'd0)) begin
                // A single frame with a hand/glare/dim dip must not blank every
                // scan box.  Keep the last carrier box for a few frames; the
                // pixel gate itself is unchanged, so stale boxes only widen the
                // search region briefly.
                hold_cnt <= hold_cnt - 4'd1;
            end else begin
                o_valid <= 1'b0;
                hold_cnt<= 4'd0;
            end
            cnt  <= 18'd0;
            minx <= 11'h7FF; maxx <= 11'd0;
            miny <= 11'h7FF; maxy <= 11'd0;
        end else if (sample_en && any_bright) begin
            cnt <= cnt + 18'd1;
            if (x0p[10:0] < minx) minx <= x0p[10:0];
            if (x1p[10:0] > maxx) maxx <= x1p[10:0];
            if (row[10:0] < miny) miny <= row[10:0];
            if (row[10:0] > maxy) maxy <= row[10:0];
        end
    end

    assign o_cur_inside = o_valid &&
                          (x0p >= {1'b0,o_bx0}) && (x1p <= {1'b0,o_bx1}) &&
                          (row >= {1'b0,o_by0}) && (row <= {1'b0,o_by1});

endmodule
