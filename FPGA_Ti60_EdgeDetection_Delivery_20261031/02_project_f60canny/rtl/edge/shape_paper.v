// shape_paper.v -- bright backdrop (paper) bbox at 1/16 resolution, single always block
//   bright = (g > PAPER_T); 1/16 sampling; 2x2 erosion; accumulate bbox; latch at vs.
module shape_paper #(
    parameter integer H_PAIRS  = 960,
    parameter integer V_LINES  = 1080,
    parameter [7:0]   PAPER_T  = 8'd150,
    parameter integer MIN_CELL = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [7:0]  i_g0,
    output reg  [10:0] o_bx0,
    output reg  [10:0] o_bx1,
    output reg  [10:0] o_by0,
    output reg  [10:0] o_by1,
    output reg         o_valid
);
    reg  [10:0] pcol;
    reg  [11:0] row;
    reg         de_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol <= 11'd0; row <= 12'd0; de_d <= 1'b0;
        end else begin
            de_d <= i_de;
            if (i_vs)                   row <= 12'd0;
            else if (de_d && !i_de)     row <= row + 12'd1;
            if (!i_de)                  pcol <= 11'd0;
            else if (pcol == H_PAIRS-1) pcol <= 11'd0;
            else                        pcol <= pcol + 11'd1;
        end
    end

    wire smp16 = (row[3:0] == 4'd0) && (pcol[2:0] == 3'd0);
    wire bright = (i_g0 > PAPER_T);

    // accumulators + latch in one block (single driver)
    reg  prev_bit, prev_row_bit;
    reg  [10:0] ax0, ax1, ay0, ay1, acnt;

    wire er = smp16 && bright && prev_bit && prev_row_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_bit <= 1'b0; prev_row_bit <= 1'b0;
            ax0 <= 11'h7FF; ax1 <= 11'd0; ay0 <= 11'h7FF; ay1 <= 11'd0; acnt <= 11'd0;
            o_bx0 <= 11'd0; o_bx1 <= 11'd0; o_by0 <= 11'd0; o_by1 <= 11'd0; o_valid <= 1'b0;
        end else if (i_vs) begin
            // latch this frame's result
            o_valid <= (acnt >= MIN_CELL[10:0]);
            o_bx0   <= (ax0 > 11'd16) ? (ax0 - 11'd16) : 11'd0;
            o_bx1   <= ax1 + 11'd16;
            o_by0   <= (ay0 > 11'd16) ? (ay0 - 11'd16) : 11'd0;
            o_by1   <= ay1 + 11'd16;
            // reset accumulators
            ax0 <= 11'h7FF; ax1 <= 11'd0; ay0 <= 11'h7FF; ay1 <= 11'd0; acnt <= 11'd0;
            prev_bit <= 1'b0; prev_row_bit <= 1'b0;
        end else if (!i_de) begin
            prev_bit <= 1'b0; prev_row_bit <= 1'b0;
        end else if (smp16) begin
            prev_bit <= bright;
            prev_row_bit <= bright;
            if (er) begin
                if ((pcol[9:3] * 16) < ax0) ax0 <= pcol[9:3] * 16;
                if ((pcol[9:3] * 16) > ax1) ax1 <= pcol[9:3] * 16;
                if (row < ay0) ay0 <= row;
                if (row > ay1) ay1 <= row;
                acnt <= acnt + 11'd1;
            end
        end
    end
endmodule
