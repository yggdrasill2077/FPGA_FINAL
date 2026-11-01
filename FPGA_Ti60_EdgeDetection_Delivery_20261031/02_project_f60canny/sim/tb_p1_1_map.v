//==============================================================================
// tb_p1_1_map.v —— P1-1 通道映射数值对照（独立小 TB，非顶层例化）
//
//   comp_rgb_q 的字节序来自 debayer_top_2to1.v:142:
//     rgb_datax2_o = {b[15:8], g[15:8], r[15:8], b[7:0], g[7:0], r[7:0]}
//   → 24bit 字内 [23:16]=b, [15:8]=g, [7:0]=r
//
//   改前：ov_r=[23:16]=b, ov_b=[7:0]=r   → 红蓝互换
//   改后：ov_r=[7:0]=r,   ov_b=[23:16]=b → 正确
//
//   运行：iverilog -g2012 -s tb_p1_1_map -o sim/tb_p1_1_map.vvp sim/tb_p1_1_map.v
//         vvp sim/tb_p1_1_map.vvp
//==============================================================================
`timescale 1ns/1ps
module tb_p1_1_map;

    reg  [23:0] q;

    wire [7:0] r_old = q[23:16];
    wire [7:0] b_old = q[7:0];
    wire [7:0] r_new = q[7:0];
    wire [7:0] b_new = q[23:16];

    integer errs = 0;
    initial begin
        // 取一帧典型颜色：b=0x11, g=0x22, r=0x33 → {b,g,r} = 24'h112233
        q = 24'h11_22_33;
        #1;
        $display("");
        $display("======================================================================");
        $display(" P1-1 comp_rgb_q channel order (byte order {b,g,r}, per debayer_top_2to1.v:142)");
        $display("======================================================================");
        $display(" comp_rgb_q = 24'h%06h  ->  b=0x%02h g=0x%02h r=0x%02h", q, q[23:16], q[15:8], q[7:0]);
        $display("----------------------------------------------------------------------");
        $display("            ov_r  ov_g  ov_b");
        $display(" before     0x%02h  0x%02h  0x%02h   <-- r/b swapped", r_old, q[15:8], b_old);
        $display(" after      0x%02h  0x%02h  0x%02h   <-- correct",        r_new, q[15:8], b_new);
        $display(" expected   0x33  0x22  0x11");

        if (r_old !== 8'h11 || b_old !== 8'h33) begin
            $display("  ERROR: old mapping model wrong"); errs = errs + 1;
        end
        if (r_new !== 8'h33 || b_new !== 8'h11) begin
            $display("  ERROR: new mapping model wrong"); errs = errs + 1;
        end
        if (q[15:8] !== 8'h22) begin
            $display("  ERROR: green channel wrong"); errs = errs + 1;
        end

        $display("----------------------------------------------------------------------");
        if (errs == 0) $display(" P1-1 MAPPING: PASS  (before r=0x11/b=0x33, after r=0x33/b=0x11)");
        else           $display(" P1-1 MAPPING: FAIL");
        $display("======================================================================");
        $finish;
    end

endmodule
