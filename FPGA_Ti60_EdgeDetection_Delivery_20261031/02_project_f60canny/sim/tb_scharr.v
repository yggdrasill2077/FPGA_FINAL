`timescale 1ns/1ps

module tb_scharr;
    reg [7:0] p00, p01, p02;
    reg [7:0] p10, p11, p12;
    reg [7:0] p20, p21, p22;

    wire signed [11:0] gx, gy;
    wire [11:0] mag, mag_iso;

    scharr_3x3 dut (
        .i_p00(p00), .i_p01(p01), .i_p02(p02),
        .i_p10(p10), .i_p11(p11), .i_p12(p12),
        .i_p20(p20), .i_p21(p21), .i_p22(p22),
        .o_gx(gx), .o_gy(gy),
        .o_magnitude(mag), .o_mag_iso(mag_iso)
    );

    task set_flat;
        input [7:0] v;
        begin
            p00 = v; p01 = v; p02 = v;
            p10 = v; p11 = v; p12 = v;
            p20 = v; p21 = v; p22 = v;
            #1;
        end
    endtask

    task check;
        input signed [11:0] egx;
        input signed [11:0] egy;
        input [11:0] emag;
        input [8*24-1:0] name;
        begin
            if ((gx !== egx) || (gy !== egy) || (mag !== emag)) begin
                $display("FAIL %0s: gx=%0d (exp %0d), gy=%0d (exp %0d), mag=%0d (exp %0d)",
                         name, gx, egx, gy, egy, mag, emag);
                $fatal(1);
            end
            $display("PASS %0s: gx=%0d gy=%0d mag=%0d iso=%0d",
                     name, gx, gy, mag, mag_iso);
        end
    endtask

    initial begin
        // Flat field: no gradient.
        set_flat(8'd128);
        check(12'sd0, 12'sd0, 12'd0, "flat");

        // Vertical step 0 -> 100: Scharr/4 axial response is 400.
        p00=0; p01=100; p02=100;
        p10=0; p11=100; p12=100;
        p20=0; p21=100; p22=100;
        #1;
        check(12'sd400, 12'sd0, 12'd400, "vertical_step");

        // Horizontal step 0 -> 100: same response on Gy.
        p00=0; p01=0; p02=0;
        p10=100; p11=100; p12=100;
        p20=100; p21=100; p22=100;
        #1;
        check(12'sd0, 12'sd400, 12'd400, "horizontal_step");

        // Reverse polarity preserves the sign.
        p00=100; p01=0; p02=0;
        p10=100; p11=0; p12=0;
        p20=100; p21=0; p22=0;
        #1;
        check(-12'sd400, 12'sd0, 12'd400, "reverse_step");

        // Saturation guard: full-scale vertical step must not overflow.
        p00=0; p01=255; p02=255;
        p10=0; p11=255; p12=255;
        p20=0; p21=255; p22=255;
        #1;
        check(12'sd1020, 12'sd0, 12'd1020, "full_scale");

        // Diagonal edge: Scharr has a different response from Sobel and must
        // remain within the 12-bit magnitude range.
        p00=0; p01=0; p02=0;
        p10=0; p11=0; p12=255;
        p20=0; p21=255; p22=255;
        #1;
        if ((gx !== 12'sd829) || (gy !== 12'sd829) || (mag !== 12'd1658)) begin
            $display("FAIL diagonal: gx=%0d gy=%0d mag=%0d", gx, gy, mag);
            $fatal(1);
        end
        $display("PASS diagonal: gx=%0d gy=%0d mag=%0d iso=%0d", gx, gy, mag, mag_iso);

        $display("SCHARR_TB_PASS");
        $finish;
    end
endmodule
