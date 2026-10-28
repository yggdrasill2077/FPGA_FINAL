//////////////////////////////////////////////////////////////////////////////
// Two-pixel-per-clock grayscale + Sobel + threshold pipeline.
//
// Input/output pixel order matches debayer_top_2to1:
//   [47:40] = R1, [39:32] = G1, [31:24] = B1,
//   [23:16] = R0, [15:8]  = G0, [7:0]   = B0
//
// The input stream advances one pixel pair per clock. Two true-dual-port
// line buffers hold y-1 and y-2. The processing pair is delayed one input
// pair: when pair x is present on the input, the pipeline calculates pair
// x-1. This gives every pixel in the processed pair access to the right-hand
// pixel from pair x without adding a frame buffer.
//
// display_mode:
//   0 = left half delayed original RGB, right half binary edge image
//   1 = full-screen binary edge image (useful for simulation/debug)
//
// The first/last active rows and the first/last pixel pair are masked because
// they do not have a complete 3x3 neighbourhood.
//////////////////////////////////////////////////////////////////////////////

module edge_pipeline_2px #(
    parameter integer H_ACTIVE = 1920,
    parameter integer SPLIT_PAIR = H_ACTIVE / 4,
    parameter integer EDGE_THRESHOLD = 128
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_vs,
    input  wire        i_hs,
    input  wire        i_de,
    input  wire        i_valid,
    input  wire [47:0] i_rgbx2,

    input  wire [11:0] i_threshold,
    input  wire        i_display_mode,

    output reg         o_vs,
    output reg         o_hs,
    output reg         o_de,
    output reg         o_valid,
    output reg  [47:0] o_rgbx2
);

    function integer clogb2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clogb2 = 0; v > 0; clogb2 = clogb2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam integer PAIRS_PER_LINE = H_ACTIVE / 2;
    localparam integer ADDR_WIDTH = clogb2(PAIRS_PER_LINE + 2);

    wire [23:0] rgb0 = i_rgbx2[23:0];
    wire [23:0] rgb1 = i_rgbx2[47:24];

    wire [7:0] gray0;
    wire [7:0] gray1;

    rgb888_to_gray u_gray0 (
        .i_r(rgb0[23:16]),
        .i_g(rgb0[15:8]),
        .i_b(rgb0[7:0]),
        .o_gray(gray0)
    );

    rgb888_to_gray u_gray1 (
        .i_r(rgb1[23:16]),
        .i_g(rgb1[15:8]),
        .i_b(rgb1[7:0]),
        .o_gray(gray1)
    );

    wire [15:0] gray_pair = {gray1, gray0};
    // Keep the original RGB pair in the same line buffer as the grayscale
    // pair. The read bank then supplies a color image already aligned with
    // the center row used by the Sobel window.
    wire [63:0] pixel_pair = {rgb1, rgb0, gray_pair};
    wire        pixel_valid = i_de & i_valid;

    // x_cnt is the pair index presented on the input this cycle. The RAM
    // read latency is one clock, so the row values observed after a clock
    // edge belong to the pair that was addressed on the previous cycle.
    reg [ADDR_WIDTH-1:0] x_cnt;
    reg                  wr_sel;
    reg                  de_d;
    reg                  vs_d;
    reg [11:0]           line_count;
    reg                  row_ok;

    wire line_start = pixel_valid & ~de_d;
    wire frame_start = i_vs & ~vs_d;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            x_cnt      <= {ADDR_WIDTH{1'b0}};
            wr_sel     <= 1'b0;
            de_d       <= 1'b0;
            vs_d       <= 1'b0;
            line_count <= 12'd0;
            row_ok     <= 1'b0;
        end else begin
            de_d <= i_de;
            vs_d <= i_vs;

            if (frame_start) begin
                line_count <= 12'd0;
                row_ok     <= 1'b0;
                wr_sel     <= 1'b0;
            end

            if (line_start) begin
                // The first pair of a line is at address zero.
                x_cnt      <= {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
                wr_sel     <= ~wr_sel;
                line_count <= line_count + 1'b1;
                // Rows 0 and 1 have no complete upper neighbourhood.
                row_ok     <= (line_count >= 12'd2);
            end else if (pixel_valid) begin
                x_cnt <= x_cnt + 1'b1;
            end
        end
    end

    // At line start address zero is used for the first write. During the
    // following cycle x_cnt is one, as required by the read-latency model.
    wire [ADDR_WIDTH-1:0] addr_a = line_start ? {ADDR_WIDTH{1'b0}} : x_cnt;
    wire [ADDR_WIDTH-1:0] addr_b = line_start ? {{(ADDR_WIDTH-1){1'b0}}, 1'b1} :
                                               (x_cnt + 1'b1);

    // Bank 0 is the write bank when wr_sel is zero. The other bank contains
    // the previous row, while the write bank still contains y-2 before the
    // current row is written.
    wire bank0_is_wr = ~wr_sel;
    wire bank1_is_wr = wr_sel;

    wire [63:0] bank0_dout1;
    wire [63:0] bank0_dout2;
    wire [63:0] bank1_dout1;
    wire [63:0] bank1_dout2;

    true_dual_port_ram #(
        .DATA_WIDTH(64),
        .ADDR_WIDTH(ADDR_WIDTH),
        .WRITE_MODE_1("READ_FIRST"),
        .WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),
        .OUTPUT_REG_2("FALSE"),
        .RAM_INIT_FILE("")
    ) u_bank0 (
        .we1(bank0_is_wr & pixel_valid),
        .we2(1'b0),
        .clka(i_clk),
        .clkb(i_clk),
        .din1(pixel_pair),
        .din2(64'd0),
        .addr1(addr_a),
        .addr2(addr_b),
        .dout1(bank0_dout1),
        .dout2(bank0_dout2)
    );

    true_dual_port_ram #(
        .DATA_WIDTH(64),
        .ADDR_WIDTH(ADDR_WIDTH),
        .WRITE_MODE_1("READ_FIRST"),
        .WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),
        .OUTPUT_REG_2("FALSE"),
        .RAM_INIT_FILE("")
    ) u_bank1 (
        .we1(bank1_is_wr & pixel_valid),
        .we2(1'b0),
        .clka(i_clk),
        .clkb(i_clk),
        .din1(pixel_pair),
        .din2(64'd0),
        .addr1(addr_a),
        .addr2(addr_b),
        .dout1(bank1_dout1),
        .dout2(bank1_dout2)
    );

    wire [63:0] wr_dout1 = bank0_is_wr ? bank0_dout1 : bank1_dout1;
    wire [63:0] wr_dout2 = bank0_is_wr ? bank0_dout2 : bank1_dout2;
    wire [63:0] rd_dout1 = bank0_is_wr ? bank1_dout1 : bank0_dout1;
    wire [63:0] rd_dout2 = bank0_is_wr ? bank1_dout2 : bank0_dout2;

    // Each row needs the pair before the centre pair, the centre pair and the
    // pair after it. The RAM ports provide the centre pair and the pair after
    // it; one delayed copy of the write-bank read provides the pair before it.
    reg [63:0] top_d1;
    reg [63:0] top_d2;
    reg [63:0] mid_d1;
    reg [63:0] mid_d2;

    // The bottom row is the incoming row, so a three-deep pair delay gives
    // x-2, x-1 and x at the point where pair x-1 is calculated.
    reg [15:0] bot_d1;
    reg [15:0] bot_d2;
    reg [15:0] bot_d3;

    // Control and coordinate delay chains. v_d[1] corresponds to the pair
    // being registered into the display output.
    reg [1:0] v_d;
    reg [1:0] de_dly;
    reg [1:0] hs_dly;
    reg [1:0] vs_dly;
    reg [ADDR_WIDTH-1:0] x_d;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            top_d1 <= 64'd0;
            top_d2 <= 64'd0;
            mid_d1 <= 64'd0;
            mid_d2 <= 64'd0;
            bot_d1 <= 16'd0;
            bot_d2 <= 16'd0;
            bot_d3 <= 16'd0;
            v_d    <= 2'b00;
            de_dly <= 2'b00;
            hs_dly <= 2'b00;
            vs_dly <= 2'b00;
            x_d    <= {ADDR_WIDTH{1'b0}};
        end else begin
            top_d1 <= wr_dout1;
            top_d2 <= top_d1;
            mid_d1 <= rd_dout1;
            mid_d2 <= mid_d1;

            bot_d1 <= gray_pair;
            bot_d2 <= bot_d1;
            bot_d3 <= bot_d2;

            v_d    <= {v_d[0], pixel_valid};
            de_dly <= {de_dly[0], i_de};
            hs_dly <= {hs_dly[0], i_hs};
            vs_dly <= {vs_dly[0], i_vs};
            x_d    <= x_cnt;
        end
    end

    // After the edge that presents input pair x, these values represent
    // rows x-1, x and x+1. The pair being calculated is x-1.
    wire [63:0] top_prev = top_d2;
    wire [63:0] top_cur  = top_d1;
    wire [63:0] top_next = wr_dout1;
    wire [63:0] mid_prev = mid_d2;
    wire [63:0] mid_cur  = mid_d1;
    wire [63:0] mid_next = rd_dout1;

    wire [7:0] top_xm1 = top_prev[15:8];
    wire [7:0] top_x0  = top_cur[7:0];
    wire [7:0] top_x1  = top_cur[15:8];
    wire [7:0] top_x2  = top_next[7:0];

    wire [7:0] mid_xm1 = mid_prev[15:8];
    wire [7:0] mid_x0  = mid_cur[7:0];
    wire [7:0] mid_x1  = mid_cur[15:8];
    wire [7:0] mid_x2  = mid_next[7:0];

    wire [7:0] bot_xm1 = bot_d3[15:8];
    wire [7:0] bot_x0  = bot_d2[7:0];
    wire [7:0] bot_x1  = bot_d2[15:8];
    wire [7:0] bot_x2  = bot_d1[7:0];

    // Pixel 0 of the calculated pair: x = 2*k.
    wire [7:0] p00_x0 = top_xm1;
    wire [7:0] p01_x0 = top_x0;
    wire [7:0] p02_x0 = top_x1;
    wire [7:0] p10_x0 = mid_xm1;
    wire [7:0] p11_x0 = mid_x0;
    wire [7:0] p12_x0 = mid_x1;
    wire [7:0] p20_x0 = bot_xm1;
    wire [7:0] p21_x0 = bot_x0;
    wire [7:0] p22_x0 = bot_x1;

    // Pixel 1 of the calculated pair: x = 2*k + 1.
    wire [7:0] p00_x1 = top_x0;
    wire [7:0] p01_x1 = top_x1;
    wire [7:0] p02_x1 = top_x2;
    wire [7:0] p10_x1 = mid_x0;
    wire [7:0] p11_x1 = mid_x1;
    wire [7:0] p12_x1 = mid_x2;
    wire [7:0] p20_x1 = bot_x0;
    wire [7:0] p21_x1 = bot_x1;
    wire [7:0] p22_x1 = bot_x2;

    wire signed [11:0] gx_x0, gy_x0, gx_x1, gy_x1;
    wire [11:0] mag_x0, mag_x1;

    sobel_3x3 u_sobel_x0 (
        .i_p00(p00_x0), .i_p01(p01_x0), .i_p02(p02_x0),
        .i_p10(p10_x0), .i_p11(p11_x0), .i_p12(p12_x0),
        .i_p20(p20_x0), .i_p21(p21_x0), .i_p22(p22_x0),
        .o_gx(gx_x0), .o_gy(gy_x0), .o_magnitude(mag_x0)
    );

    sobel_3x3 u_sobel_x1 (
        .i_p00(p00_x1), .i_p01(p01_x1), .i_p02(p02_x1),
        .i_p10(p10_x1), .i_p11(p11_x1), .i_p12(p12_x1),
        .i_p20(p20_x1), .i_p21(p21_x1), .i_p22(p22_x1),
        .o_gx(gx_x1), .o_gy(gy_x1), .o_magnitude(mag_x1)
    );

    reg [11:0] threshold_r;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            threshold_r <= EDGE_THRESHOLD[11:0];
        else
            threshold_r <= i_threshold;
    end

    wire [7:0] edge_x0 = (mag_x0 > threshold_r) ? 8'hFF : 8'h00;
    wire [7:0] edge_x1 = (mag_x1 > threshold_r) ? 8'hFF : 8'h00;

    wire [47:0] original_pair_out = {mid_cur[63:40], mid_cur[39:16]};
    wire [47:0] edge_pair_out = {
        edge_x1, edge_x1, edge_x1,
        edge_x0, edge_x0, edge_x0
    };

    // x_d holds the input pair index after the previous edge. The pair being
    // emitted is one behind it. The coordinate is used for split-screen
    // selection and for suppressing the incomplete border pairs.
    wire [ADDR_WIDTH-1:0] calc_pair = x_d - 1'b1;
    wire border_pair = (calc_pair == {ADDR_WIDTH{1'b0}}) ||
                       (calc_pair == (PAIRS_PER_LINE - 1));
    wire split_pixel = (calc_pair >= SPLIT_PAIR);

    wire [47:0] selected_data = (i_display_mode | split_pixel) ?
                                edge_pair_out : original_pair_out;
    wire [47:0] output_data = (v_d[1] && row_ok && ~border_pair) ?
                              selected_data : 48'd0;
    wire output_valid = v_d[1] && row_ok;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_vs    <= 1'b0;
            o_hs    <= 1'b0;
            o_de    <= 1'b0;
            o_valid <= 1'b0;
            o_rgbx2 <= 48'd0;
        end else begin
            o_vs    <= vs_dly[1];
            o_hs    <= hs_dly[1];
            o_de    <= de_dly[1];
            o_valid <= output_valid;
            o_rgbx2 <= output_data;
        end
    end

endmodule
