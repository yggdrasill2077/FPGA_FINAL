//==============================================================================
// shape_edge_mask_2px.v -- Sobel edge stream used only as the shape locator
//
//  F35b located shapes from dark-ink blobs.  That made the scan box depend on
//  the paper/ink threshold and allowed shadows or paper texture to define a
//  candidate.  This module produces a paper-gated gradient mask instead:
//
//      gray -> 3x3 Sobel -> |Gx|+|Gy| -> fixed threshold -> edge pixels
//
//  The downstream block logic then requires at least two edge pixels inside a
//  4x4 block before the block can seed/join a connected component.  A single
//  hot pixel or paper-fibre gradient therefore cannot create a scan box.
//
//  The Sobel is evaluated on the ungated gray image.  Paper gating is applied
//  to the resulting edge pixels after the gradient, so the gate boundary itself
//  cannot manufacture a false edge.
//==============================================================================
module shape_edge_mask_2px #(
    parameter integer H_PAIRS   = 960,
    parameter integer V_LINES   = 1080,
    parameter integer ADDR_W    = 10,
    parameter integer EDGE_PIX_TH = 24,
    parameter integer EDGE_BLOCK_MIN = 2,
    parameter integer BLOCK_SHIFT = 2
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              i_de,
    input  wire              i_vs,
    input  wire [7:0]        i_g0,
    input  wire [7:0]        i_g1,
    input  wire              i_gate,
    output reg               o_de,
    output reg               o_vs,
    output reg  [7:0]        o_g0,
    output reg  [7:0]        o_g1,
    output wire              o_blk_hit
);

    reg [ADDR_W-1:0] pcol;
    reg [11:0]       row;
    reg              de_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol <= {ADDR_W{1'b0}};
            row  <= 12'd0;
            de_q <= 1'b0;
        end else begin
            de_q <= i_de;
            if (i_vs)
                row <= 12'd0;
            else if (de_q && !i_de)
                row <= row + 12'd1;

            if (!i_de)
                pcol <= {ADDR_W{1'b0}};
            else if (pcol == (H_PAIRS-1))
                pcol <= {ADDR_W{1'b0}};
            else
                pcol <= pcol + 1'b1;
        end
    end

    wire [31:0] w_top, w_mid, w_bot;

    win3x3_2px #(.DW(16), .H_PAIRS(H_PAIRS), .ADDR_W(ADDR_W)) u_win (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_x(pcol), .i_row(12'd0), .i_pair({i_g1, i_g0}),
        .o_de(), .o_x(), .o_row(),
        .o_top(w_top), .o_mid(w_mid), .o_bot(w_bot)
    );

    wire [11:0] g0_mag, g1_mag;
    wire [11:0] g0_mag_iso, g1_mag_iso;
    wire signed [11:0] g0_gx, g0_gy, g1_gx, g1_gy;

    sobel_3x3 u_sob0 (
        .i_p00(w_top[7:0]),   .i_p01(w_top[15:8]),  .i_p02(w_top[23:16]),
        .i_p10(w_mid[7:0]),   .i_p11(w_mid[15:8]),  .i_p12(w_mid[23:16]),
        .i_p20(w_bot[7:0]),   .i_p21(w_bot[15:8]),  .i_p22(w_bot[23:16]),
        .o_gx(g0_gx), .o_gy(g0_gy),
        .o_magnitude(g0_mag), .o_mag_iso(g0_mag_iso)
    );

    sobel_3x3 u_sob1 (
        .i_p00(w_top[15:8]),  .i_p01(w_top[23:16]), .i_p02(w_top[31:24]),
        .i_p10(w_mid[15:8]),  .i_p11(w_mid[23:16]), .i_p12(w_mid[31:24]),
        .i_p20(w_bot[15:8]),  .i_p21(w_bot[23:16]), .i_p22(w_bot[31:24]),
        .o_gx(g1_gx), .o_gy(g1_gy),
        .o_magnitude(g1_mag), .o_mag_iso(g1_mag_iso)
    );

    reg              d1_de, d2_de;
    reg              d1_vs, d2_vs;
    reg              d1_gate, d2_gate;
    reg [11:0]       d1_row, d2_row;
    reg [ADDR_W-1:0] d1_x, d2_x;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_de <= 1'b0; d2_de <= 1'b0;
            d1_vs <= 1'b0; d2_vs <= 1'b0;
            d1_gate <= 1'b0; d2_gate <= 1'b0;
            d1_row <= 12'd0; d2_row <= 12'd0;
            d1_x <= {ADDR_W{1'b0}}; d2_x <= {ADDR_W{1'b0}};
        end else begin
            d1_de <= i_de;   d2_de <= d1_de;
            d1_vs <= i_vs;   d2_vs <= d1_vs;
            d1_gate <= i_gate; d2_gate <= d1_gate;
            d1_row <= row;   d2_row <= d1_row;
            d1_x <= pcol;    d2_x <= d1_x;
        end
    end

    // The 3x3 window is only defined from the second line and second pair
    // inward.  Suppressing the outer border also removes BRAM warm-up pixels.
    wire spatial_ok = (d2_row >= 12'd2) &&
                      (d2_row < (V_LINES-1)) &&
                      (d2_x != {ADDR_W{1'b0}}) &&
                      (d2_x != (H_PAIRS-1));

    wire edge0 = d2_de && d2_gate && spatial_ok &&
                 (g0_mag_iso >= EDGE_PIX_TH);
    wire edge1 = d2_de && d2_gate && spatial_ok &&
                 (g1_mag_iso >= EDGE_PIX_TH);

    // 4x4 block vote.  A counter is kept per horizontal block column because
    // the four rows of a block are interleaved with all other columns while the
    // line is streamed.  The counter saturates at two: only "0, 1, >=2" matters.
    localparam integer BX_MAX = (H_PAIRS + (1 << (BLOCK_SHIFT-1)) - 1) >>
                                (BLOCK_SHIFT-1);
    reg [1:0] blk_cnt [0:BX_MAX-1];

    wire [8:0] out_bx = d2_x >> (BLOCK_SHIFT-1);
    wire [1:0] edge_pair = {1'b0,edge0} + {1'b0,edge1};
    wire [2:0] blk_sum = {1'b0,blk_cnt[out_bx]} + {1'b0,edge_pair};
    wire [1:0] blk_sat = (blk_sum >= 3'd2) ? 2'd2 : blk_sum[1:0];
    wire       out_blk_start = d2_de && (d2_row[BLOCK_SHIFT-1:0] == 0) &&
                               (d2_x[BLOCK_SHIFT-2:0] == 0);
    wire       out_blk_end   = d2_de &&
                               (d2_row[BLOCK_SHIFT-1:0] == ((1<<BLOCK_SHIFT)-1)) &&
                               (d2_x[BLOCK_SHIFT-2:0] == ((1<<(BLOCK_SHIFT-1))-1));

    always @(posedge clk) begin
        if (out_blk_start)
            blk_cnt[out_bx] <= (edge_pair >= 2'd2) ? 2'd2 : edge_pair;
        else if (d2_de)
            blk_cnt[out_bx] <= blk_sat;
    end

    assign o_blk_hit = out_blk_end && (blk_sum >= EDGE_BLOCK_MIN[2:0]);

    always @(*) begin
        o_de = d2_de;
        o_vs = d2_vs;
        o_g0 = edge0 ? 8'd0 : 8'd255;   // 0 = foreground for the grid/polar map
        o_g1 = edge1 ? 8'd0 : 8'd255;
    end

endmodule
