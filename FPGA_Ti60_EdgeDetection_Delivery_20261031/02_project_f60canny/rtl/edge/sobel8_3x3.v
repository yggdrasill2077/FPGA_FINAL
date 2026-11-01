//////////////////////////////////////////////////////////////////////////////
// Eight-direction 3x3 gradient for the FPGA edge pipeline (v24).
//
// The eight kernels in Song et al., "Design of Sobel image edge detection
// system based on FPGA", Electronic Measurement Technology 47(13), 2024,
// are pairwise opposites.  Only four convolutions are therefore independent:
//
//   0/180 deg : [-1 -2 -1;  0  0  0;  1  2  1]  -> Gy
//   45/225 deg: [-2 -1  0; -1  0  1;  0  1  2]  -> D1
//   90/270 deg: [-1  0  1; -2  0  2; -1  0  1]  -> Gx
//  135/315 deg: [ 0  1  2; -1  0  1; -2 -1  0]  -> D2
//
// The paper forms (sum(|G0|..|G7|)) >> 3.  Because opposite responses have
// equal magnitude this is (|Gy|+|D1|+|Gx|+|D2|) >> 2.  The existing pipeline
// uses the |Gx|+|Gy| scale (0..2040), so v24 keeps the same range by dropping
// one shift: (|Gy|+|D1|+|Gx|+|D2|) >> 1.  This is exactly twice the paper's
// average and preserves the calibration of the histogram/local thresholds.
//
// o_oct quantises the gradient normal into eight 45-degree sectors:
//   0=+x, 1=+x+y, 2=+y, 3=-x+y, 4=-x, 5=-x-y, 6=-y, 7=+x-y
// o_t2 is a two-bit fixed-point interpolation level used by the NMS stage.
//////////////////////////////////////////////////////////////////////////////

module sobel8_3x3 (
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
    output wire [11:0]        o_mag,
    output wire [2:0]         o_oct,
    output wire [1:0]         o_t2
);

    wire [10:0] gx_pos = i_p02 + {i_p12, 1'b0} + i_p22;
    wire [10:0] gx_neg = i_p00 + {i_p10, 1'b0} + i_p20;
    wire [10:0] gy_pos = i_p20 + {i_p21, 1'b0} + i_p22;
    wire [10:0] gy_neg = i_p00 + {i_p01, 1'b0} + i_p02;

    // 45-degree kernel: (2*p22 + p12 + p21) - (2*p00 + p01 + p10).
    wire [10:0] d1_pos = {i_p22, 1'b0} + i_p12 + i_p21;
    wire [10:0] d1_neg = {i_p00, 1'b0} + i_p01 + i_p10;

    // 135-degree kernel: (2*p02 + p01 + p12) - (2*p20 + p21 + p10).
    wire [10:0] d2_pos = {i_p02, 1'b0} + i_p01 + i_p12;
    wire [10:0] d2_neg = {i_p20, 1'b0} + i_p21 + i_p10;

    wire [11:0] gx_value = {1'b0, gx_pos} - {1'b0, gx_neg};
    wire [11:0] gy_value = {1'b0, gy_pos} - {1'b0, gy_neg};
    wire [11:0] d1_value = {1'b0, d1_pos} - {1'b0, d1_neg};
    wire [11:0] d2_value = {1'b0, d2_pos} - {1'b0, d2_neg};

    wire [11:0] abs_gx = gx_value[11] ? (~gx_value + 1'b1) : gx_value;
    wire [11:0] abs_gy = gy_value[11] ? (~gy_value + 1'b1) : gy_value;
    wire [11:0] abs_d1 = d1_value[11] ? (~d1_value + 1'b1) : d1_value;
    wire [11:0] abs_d2 = d2_value[11] ? (~d2_value + 1'b1) : d2_value;

    wire [13:0] unique_sum = {2'b00, abs_gx} + {2'b00, abs_gy} +
                             {2'b00, abs_d1} + {2'b00, abs_d2};

    wire [15:0] gx_x5 = {4'b0000, abs_gx} * 5;
    wire [15:0] gy_x5 = {4'b0000, abs_gy} * 5;
    wire [15:0] gx_x2 = {5'b00000, abs_gx} << 1;
    wire [15:0] gy_x2 = {5'b00000, abs_gy} << 1;

    reg [2:0] oct_r;
    reg [1:0] t2_r;

    always @(*) begin
        // Boundaries at 22.5 and 67.5 degrees.  5*minor <= 2*major is the
        // integer form of tan(22.5)=0.4142 and avoids a divider.
        if (gy_x5 <= gx_x2)
            oct_r = gx_value[11] ? 3'd4 : 3'd0;
        else if (gx_x5 <= gy_x2)
            oct_r = gy_value[11] ? 3'd6 : 3'd2;
        else if (!gx_value[11])
            oct_r = gy_value[11] ? 3'd7 : 3'd1;
        else
            oct_r = gy_value[11] ? 3'd5 : 3'd3;

        // Interpolation levels 0, 1/4, 2/4 and 4/4.  Snapping the final
        // level to the exact diagonal avoids a persistent 25% cardinal bias
        // on true 45-degree edges.
        if (abs_gx >= abs_gy) begin
            if ({4'b0000, abs_gy} << 3 <= {4'b0000, abs_gx})
                t2_r = 2'd0;
            else if ({4'b0000, abs_gy} << 2 <= {4'b0000, abs_gx})
                t2_r = 2'd1;
            else if ({4'b0000, abs_gy} << 1 <= {4'b0000, abs_gx})
                t2_r = 2'd2;
            else
                t2_r = 2'd3;
        end else begin
            if ({4'b0000, abs_gx} << 3 <= {4'b0000, abs_gy})
                t2_r = 2'd0;
            else if ({4'b0000, abs_gx} << 2 <= {4'b0000, abs_gy})
                t2_r = 2'd1;
            else if ({4'b0000, abs_gx} << 1 <= {4'b0000, abs_gy})
                t2_r = 2'd2;
            else
                t2_r = 2'd3;
        end
    end

    assign o_gx  = gx_value;
    assign o_gy  = gy_value;
    assign o_mag = unique_sum[12:1];
    assign o_oct = oct_r;
    assign o_t2  = t2_r;

endmodule
