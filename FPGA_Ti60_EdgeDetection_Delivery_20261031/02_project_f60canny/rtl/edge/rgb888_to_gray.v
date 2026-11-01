//////////////////////////////////////////////////////////////////////////////
// RGB888 to 8-bit luminance.
//
// Integer approximation used by the competition design:
//   Y = (77*R + 150*G + 29*B) >> 8
//
// The constant multiplications are written as shifts and adds so the
// datapath does not require a divider or a general-purpose multiplier.
//////////////////////////////////////////////////////////////////////////////

module rgb888_to_gray (
    input  wire [7:0] i_r,
    input  wire [7:0] i_g,
    input  wire [7:0] i_b,
    output wire [7:0] o_gray
);

    wire [15:0] r_ext = {8'd0, i_r};
    wire [15:0] g_ext = {8'd0, i_g};
    wire [15:0] b_ext = {8'd0, i_b};

    // 77 = 64 + 8 + 4 + 1
    wire [15:0] r_77 = r_ext + (r_ext << 2) + (r_ext << 3) + (r_ext << 6);

    // 150 = 128 + 16 + 4 + 2
    wire [15:0] g_150 = (g_ext << 1) + (g_ext << 2) + (g_ext << 4) + (g_ext << 7);

    // 29 = 16 + 8 + 4 + 1
    wire [15:0] b_29 = b_ext + (b_ext << 2) + (b_ext << 3) + (b_ext << 4);

    wire [16:0] luma_sum = {1'b0, r_77} + {1'b0, g_150} + {1'b0, b_29};

    assign o_gray = luma_sum[15:8];

endmodule
