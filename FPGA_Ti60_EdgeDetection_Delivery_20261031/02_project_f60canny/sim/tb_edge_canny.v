`timescale 1ns/1ps
//==============================================================================
// tb_edge_canny.v —— edge_canny_2px NMS/滞后验证台
//   * 激励与原版一致：2 帧 64x540，含垂直阶跃、1px 斜线
//   * 新增逐行边缘统计：总边缘像素数、run 宽度直方图、各边缘窗口宽度
//   * 逐行明细写入 sim/edge_stats.csv（frame,row,total,left,right,ramp,diag,runs,maxrun,bits）
//==============================================================================
module tb_edge_canny;
    localparam integer HP = 32;
    localparam integer VP = 540;
    reg clk = 1'b0; reg rst_n = 1'b0;
    always #5 clk = ~clk;
    reg i_de = 1'b0, i_hs = 1'b0, i_vs = 1'b0;
    reg [7:0] i_g0 = 8'd0, i_g1 = 8'd0;
    reg [11:0] i_th = 12'd12;
    reg [47:0] i_rgb = 48'd0;
    reg        i_sob8 = 1'b0;
    wire o_de, o_hs, o_vs;
    wire [1:0] o_e;
    wire [15:0] o_osd, o_bg;
    wire [47:0] o_rgb;

    edge_canny_2px #(.H_PAIRS(HP), .ADDR_W(5), .GAUSS_ON(1),
                     .CANNY_HYST_ON(1), .LOCAL_T_ON(0), .SUBPIX_ON(1)
`ifdef HYST4
                     , .HYST_SHIFT(4)
`endif
                     ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_hs(i_hs), .i_vs(i_vs),
        .i_g0(i_g0), .i_g1(i_g1), .i_rgb(i_rgb), .i_threshold(i_th), .i_sob8(i_sob8),
        .o_de(o_de), .o_hs(o_hs), .o_vs(o_vs),
        .o_e(o_e), .o_osd(o_osd), .o_bg(o_bg), .o_rgb(o_rgb)
    );

    // y<30 预热帧全 0；y>=30 测试图（阶跃 255 / 细线 255 / 斜边）
    function integer pix;
        input integer x, y;
        begin
            if (y < 30)                 pix = 8'd0;
            else if (x < 20)            pix = 8'd0;
            else if (x == 30)           pix = 8'd255;
            else if (x < 30)            pix = 8'd255;
            else if (x == 50 + (y % 4)) pix = 8'd255;
`ifdef RAMP
            // 平台压力测试：x=34..42 线性斜坡（内部梯度恒定，形成幅值平台）
            else if (x >= 34 && x <= 42) pix = 8'd20 + (x - 34) * 8'd25;
`endif
            else                        pix = 8'd0;
        end
    endfunction

    integer x, y, i;
    integer fd;
    integer frame_no = 0;
    reg     vs_q = 1'b0;

    // 行内边缘位图
    reg        line_act = 1'b0;
    reg [11:0] cur_row;
    reg [63:0] rowbits;

    // 统计量
    integer rows = 0, tot_px = 0, empty_rows = 0, runs_total = 0, max_run = 0;
    integer maxrow_px = 0;
    integer hist_w [0:8];
    integer lw0=0, lw1=0, lw2=0, lw3=0;
    integer rw0=0, rw1=0, rw2=0, rw3=0;
    integer pw0=0, pw1=0, pw2=0, pw3=0;
    integer dw0=0, dw1=0, dw2=0, dw3=0;

    function integer cntw;
        input [63:0] b;
        input integer lo, hi;
        integer k;
        begin
            cntw = 0;
            for (k = lo; k <= hi; k = k + 1)
                if (b[k]) cntw = cntw + 1;
        end
    endfunction

    task process_row;
        input [11:0] r;
        input [63:0] b;
        integer k, w, nr, np, mx, lw, rw, pw, dw;
        begin
            if (r >= 12'd40 && r <= 12'd530) begin
                np = 0; nr = 0; mx = 0; w = 0;
                for (k = 0; k < 64; k = k + 1) begin
                    if (b[k]) begin
                        np = np + 1;
                        w  = w + 1;
                    end else if (w > 0) begin
                        nr = nr + 1;
                        if (w > mx) mx = w;
                        if (w >= 8) hist_w[8] = hist_w[8] + 1;
                        else        hist_w[w] = hist_w[w] + 1;
                        w = 0;
                    end
                end
                if (w > 0) begin
                    nr = nr + 1;
                    if (w > mx) mx = w;
                    if (w >= 8) hist_w[8] = hist_w[8] + 1;
                    else        hist_w[w] = hist_w[w] + 1;
                end

                lw = cntw(b, 18, 22);   // 左阶跃（暗→白，x≈20）
                rw = cntw(b, 29, 33);   // 白块右边界（白→暗，x≈30）
                pw = cntw(b, 33, 44);   // 斜坡/平台窗口（RAMP 时有效）
                dw = cntw(b, 48, 56);   // 1px 斜线 x=50+(y%4)

                rows       = rows + 1;
                tot_px     = tot_px + np;
                runs_total = runs_total + nr;
                if (np == 0) empty_rows = empty_rows + 1;
                if (np > maxrow_px) maxrow_px = np;
                if (mx > max_run) max_run = mx;

                if (lw == 0) lw0 = lw0 + 1; else if (lw == 1) lw1 = lw1 + 1;
                else if (lw == 2) lw2 = lw2 + 1; else lw3 = lw3 + 1;
                if (rw == 0) rw0 = rw0 + 1; else if (rw == 1) rw1 = rw1 + 1;
                else if (rw == 2) rw2 = rw2 + 1; else rw3 = rw3 + 1;
                if (pw == 0) pw0 = pw0 + 1; else if (pw == 1) pw1 = pw1 + 1;
                else if (pw == 2) pw2 = pw2 + 1; else pw3 = pw3 + 1;
                if (dw == 0) dw0 = dw0 + 1; else if (dw == 1) dw1 = dw1 + 1;
                else if (dw == 2) dw2 = dw2 + 1; else dw3 = dw3 + 1;

                $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h\n",
                        frame_no, r, np, lw, rw, pw, dw, nr, mx, b);
            end
        end
    endtask

    // 帧号（输入 i_vs 上升沿）
    always @(posedge clk) begin
        vs_q <= i_vs;
        if (i_vs && !vs_q) frame_no <= frame_no + 1;
    end

    // 输出行采集：dut.ocol 为输出像素对号，dut.row_d6 为输出行号（同相）
    always @(posedge clk) begin
        if (!o_de) begin
            if (line_act) begin
                process_row(cur_row, rowbits);
                line_act <= 1'b0;
            end
        end else begin
            if (!line_act) begin
                line_act <= 1'b1;
                cur_row  <= dut.row_d6;
                rowbits  <= 64'd0;
            end
            rowbits[2*dut.ocol]     <= o_e[0];
            rowbits[2*dut.ocol + 1] <= o_e[1];
        end
    end

    initial begin
        if (!$value$plusargs("TH=%d", i_th)) i_th = 12'd12;
        for (i = 0; i < 9; i = i + 1) hist_w[i] = 0;
        fd = $fopen("sim/edge_stats.csv", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open sim/edge_stats.csv");
            $finish;
        end
        #100; rst_n = 1'b1; #100;
        for (i = 0; i < 1024; i = i + 1) dut.vmem[i] = 8'd0;
        for (y = 0; y < VP*2; y = y + 1) begin
            if (y == 0 || y == VP) begin
                i_vs <= 1'b1; repeat (10) @(posedge clk); i_vs <= 1'b0;
            end
            i_hs <= 1'b1; @(posedge clk); @(posedge clk); i_hs <= 1'b0;
            repeat (20) @(posedge clk);
            // 在 negedge 更新像素，保证下一个 posedge 采样时数据已稳定
            for (x = 0; x < HP; x = x + 1) begin
                @(negedge clk);
                i_de = 1'b1;
                i_g0 = pix(2*x,   y);
                i_g1 = pix(2*x+1, y);
            end
            @(negedge clk);
            i_de = 1'b0;
            @(posedge clk);
            repeat (20) @(posedge clk);
        end
        repeat (100) @(posedge clk);
        $fclose(fd);
        $display("==== 仿真结束 ====");
        $display("[STAT] frames=%0d rows=%0d total_px=%0d avg_per_row=%0.3f empty_rows=%0d max_px_in_row=%0d",
                 frame_no, rows, tot_px, (rows>0) ? tot_px*1.0/rows : 0.0, empty_rows, maxrow_px);
        $display("[STAT] runs=%0d max_run=%0d width_hist: w1=%0d w2=%0d w3=%0d w4=%0d w5=%0d w6=%0d w7=%0d w8+=%0d",
                 runs_total, max_run, hist_w[1], hist_w[2], hist_w[3], hist_w[4],
                 hist_w[5], hist_w[6], hist_w[7], hist_w[8]);
        $display("[STAT] left(18-22)  0/1/2/3+=%0d/%0d/%0d/%0d", lw0, lw1, lw2, lw3);
        $display("[STAT] right(29-33) 0/1/2/3+=%0d/%0d/%0d/%0d", rw0, rw1, rw2, rw3);
        $display("[STAT] ramp(33-44)  0/1/2/3+=%0d/%0d/%0d/%0d", pw0, pw1, pw2, pw3);
        $display("[STAT] diag(48-56)  0/1/2/3+=%0d/%0d/%0d/%0d", dw0, dw1, dw2, dw3);
        $finish;
    end
endmodule
