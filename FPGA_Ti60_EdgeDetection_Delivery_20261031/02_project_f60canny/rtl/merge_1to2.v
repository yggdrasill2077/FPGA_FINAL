`timescale 1ns/1ps
// 1px/clk 24bit → 2px/clk 48bit 合并
// 输出配对 = {px[2n+1], px[2n]}，行首第一像素在低半字
module merge_1to2 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire        i_hs,
    input  wire [23:0] i_px,
    output reg         o_de,
    output reg         o_vs,
    output reg         o_hs,
    output reg  [47:0] o_px
);
    reg        ph;        // 0=等低半字 1=等高一字
    reg [23:0] lo;        // 低半字缓存
    reg        hs_d, vs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= 1'b0; lo <= 24'd0;
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0; o_px <= 48'd0;
            hs_d <= 1'b0; vs_d <= 1'b0;
        end else begin
            hs_d <= i_hs; vs_d <= i_vs;
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0;
            if (i_de) begin
                if (!ph) begin
                    lo <= i_px;           // 收低半字
                    ph <= 1'b1;
                end else begin
                    o_px <= {i_px, lo};   // 高半字在前 → {px[2n+1], px[2n]}
                    o_de <= 1'b1;
                    o_hs <= hs_d;
                    o_vs <= vs_d;
                    ph <= 1'b0;
                end
            end else begin
                ph <= 1'b0;               // de 拉低丢弃未配对像素（行长为奇数时的行为）
            end
        end
    end
endmodule