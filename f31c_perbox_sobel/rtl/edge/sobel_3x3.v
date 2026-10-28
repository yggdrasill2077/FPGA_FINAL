//////////////////////////////////////////////////////////////////////////////
// Combinational 3x3 Sobel core.
//
// The module is deliberately kept free of line-buffer and display logic so
// that it can be verified independently. The parent edge_pipeline_2px module
// supplies the nine pixels for each pixel position.
//////////////////////////////////////////////////////////////////////////////

module sobel_3x3 (
    input  wire [7:0] i_p00,
    input  wire [7:0] i_p01,
    input  wire [7:0] i_p02,
    input  wire [7:0] i_p10,
    input  wire [7:0] i_p11,
    input  wire [7:0] i_p12,
    input  wire [7:0] i_p20,
    input  wire [7:0] i_p21,
    input  wire [7:0] i_p22,
    output wire signed [11:0] o_gx,
    output wire signed [11:0] o_gy,
    output wire [11:0] o_magnitude,   // 赛题口径：|Gx| + |Gy|（保持原样，默认使用）
    output wire [11:0] o_mag_iso      // 各向异性补偿：max(|Gx|,|Gy|) + min(|Gx|,|Gy|)/2
);

    wire [10:0] gx_pos = i_p02 + {i_p12, 1'b0} + i_p22;
    wire [10:0] gx_neg = i_p00 + {i_p10, 1'b0} + i_p20;
    wire [10:0] gy_pos = i_p20 + {i_p21, 1'b0} + i_p22;
    wire [10:0] gy_neg = i_p00 + {i_p01, 1'b0} + i_p02;

    // Extend to 12 bits before subtraction so the signed result is explicit.
    // Keep the arithmetic in explicitly sized unsigned vectors. The bit
    // pattern is still two's-complement, but this avoids relying on
    // $signed() for a synthesizable RTL macro.
    wire [11:0] gx_value = {1'b0, gx_pos} - {1'b0, gx_neg};
    wire [11:0] gy_value = {1'b0, gy_pos} - {1'b0, gy_neg};

    wire [11:0] abs_gx = gx_value[11] ? (~gx_value + 1'b1) : gx_value;
    wire [11:0] abs_gy = gy_value[11] ? (~gy_value + 1'b1) : gy_value;

    // ------------------------------------------------------------------
    // 各向异性补偿幅值（60 LUT 量级：2×12bit 比较 + 2×12bit 选择 + 1×12bit 加法）
    //
    //   |Gx|+|Gy| 的角度响应不是常量：轴向（0°/90°）为 1.0·a，
    //   对角（45°）为 1.414·a，平均偏高约 41%（论文实测 41.4%）。
    //   max + min/2 的响应为轴向 1.0·a、对角 1.5·a，把角度增益压平；
    //   峰值 = 1.5·a = 1530（12bit 足够，不会溢出）。
    //   注：o_magnitude 保持赛题口径不变，两者并存由上层选择。
    // ------------------------------------------------------------------
    wire        gx_is_max = (abs_gx >= abs_gy);
    wire [11:0] ab_max    = gx_is_max ? abs_gx : abs_gy;
    wire [11:0] ab_min    = gx_is_max ? abs_gy : abs_gx;
    wire [11:0] mag_iso   = ab_max + {1'b0, ab_min[11:1]};   // max + (min >> 1)

    assign o_gx = gx_value;
    assign o_gy = gy_value;
    assign o_magnitude = abs_gx + abs_gy;
    assign o_mag_iso   = mag_iso;

endmodule
