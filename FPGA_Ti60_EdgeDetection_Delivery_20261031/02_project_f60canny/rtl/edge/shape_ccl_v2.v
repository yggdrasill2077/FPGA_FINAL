// shape_ccl_v2.v -- 1/8-domain connected components (largest blob bbox), register-table method
//  Grid 240x135 for 1920x1080 (one sample per 8 px).
//  16-entry active-blob table (all registers). Per run: parallel overlap test;
//  merge when 2+ entries overlap, else allocate a new entry (drop if full).
//  At vs: latch the max-area entry's bbox in camera px; clear the table one cycle later.
module shape_ccl_v2 #(
    parameter integer H_PAIRS  = 960,
    parameter integer V_LINES  = 1080,
    parameter integer NENT     = 16,
    parameter integer MIN_AREA = 12
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_ty,
    output reg  [10:0] o_bx0,
    output reg  [10:0] o_bx1,
    output reg  [10:0] o_by0,
    output reg  [10:0] o_by1,
    output reg  [10:0] o2_bx0,
    output reg  [10:0] o2_bx1,
    output reg  [10:0] o2_by0,
    output reg  [10:0] o2_by1,
    output reg         o2_valid,
    output reg  [15:0] o_area,
    output reg         o_valid
);

    // ---------------- row/col counters + 1/8 sampling ----------------
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

    wire smp8     = (row[2:0] == 3'd0) && (pcol[1:0] == 2'd0);   // x0 = 2*pcol, x0%8==0
    wire line_end = de_d && !i_de;
    wire [7:0] yc = row[10:3];

    // ---------------- run detection ----------------
    reg        bit_d;
    reg        in_run;
    reg [7:0]  rs;
    reg [7:0]  col_idx;

    wire fg_now = (i_g0 < i_ty);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_d <= 1'b0; in_run <= 1'b0; rs <= 8'd0; col_idx <= 8'd0;
        end else if (!i_de) begin
            bit_d <= 1'b0; in_run <= 1'b0; col_idx <= 8'd0;
        end else if (smp8) begin
            bit_d   <= fg_now;
            col_idx <= col_idx + 8'd1;
            if (fg_now && !bit_d) begin
                in_run <= 1'b1;
                rs     <= col_idx;
            end
            if (!fg_now && bit_d) in_run <= 1'b0;
        end
    end

    wire run_end_p   = (smp8 && !fg_now && bit_d && in_run);       // normal end
    wire run_end_f   = (line_end && in_run);                       // forced end at row finish
    wire run_end_any = run_end_p || run_end_f;
    integer smp8_cnt = 0;
    integer re_cnt   = 0;
    always @(posedge clk) begin if (smp8) smp8_cnt <= smp8_cnt + 1; if (run_end_any) re_cnt <= re_cnt + 1; end
    wire [7:0] run_s = rs;
    wire [7:0] run_e = col_idx - 8'd1;

    // ---------------- active blob table ----------------
    reg [15:0] a_area [0:NENT-1];
    reg [7:0]  a_lx0  [0:NENT-1];
    reg [7:0]  a_lx1  [0:NENT-1];
    reg [7:0]  a_bx0  [0:NENT-1];
    reg [7:0]  a_bx1  [0:NENT-1];
    reg [7:0]  a_by0  [0:NENT-1];
    reg [7:0]  a_by1  [0:NENT-1];
    reg [NENT-1:0] a_valid;

    wire [NENT-1:0] ovl;
    genvar gi;
    generate
        for (gi = 0; gi < NENT; gi = gi + 1) begin : G_OVL
            assign ovl[gi] = a_valid[gi] &&
                             !((run_e < a_lx0[gi]) || (run_s > a_lx1[gi]));
        end
    endgenerate

    reg [3:0] hit0, hit1;
    reg       has0, has1;
    integer   k;
    always @* begin
        has0 = 1'b0; has1 = 1'b0; hit0 = 4'd0; hit1 = 4'd0;
        for (k = NENT-1; k >= 0; k = k - 1) begin
            if (ovl[k]) begin
                has1 = has0; hit1 = hit0;
                has0 = 1'b1; hit0 = k[3:0];
            end
        end
    end

    reg [3:0] free_idx;
    reg       has_free;
    always @* begin
        has_free = 1'b0; free_idx = 4'd0;
        for (k = NENT-1; k >= 0; k = k - 1) begin
            if (!a_valid[k]) begin
                has_free = 1'b1;
                free_idx = k[3:0];
            end
        end
    end

    // ---------------- table update ----------------
    reg  vs_d;
    wire vs_rise = i_vs & ~vs_d;
    wire vs_fall = vs_d & ~i_vs;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= i_vs;
    end

    integer i;
    reg [15:0] run_len;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_valid <= {NENT{1'b0}};
            for (i = 0; i < NENT; i = i + 1) begin
                a_area[i] <= 16'd0; a_lx0[i] <= 8'd0; a_lx1[i] <= 8'd0;
                a_bx0[i]  <= 8'd0;  a_bx1[i]  <= 8'd0;
                a_by0[i]  <= 8'd0;  a_by1[i]  <= 8'd0;
            end
        end else if (vs_fall) begin
            a_valid <= {NENT{1'b0}};
        end else if (run_end_any) begin
            run_len = run_e - run_s + 8'd1;
            if (has0) begin
                a_area[hit0] <= a_area[hit0] + {8'd0, run_len};
                a_lx0[hit0]  <= run_s;
                a_lx1[hit0]  <= run_e;
                if (run_s < a_bx0[hit0]) a_bx0[hit0] <= run_s;
                if (run_e > a_bx1[hit0]) a_bx1[hit0] <= run_e;
                if (yc < a_by0[hit0])    a_by0[hit0] <= yc;
                if (yc > a_by1[hit0])    a_by1[hit0] <= yc;
                if (has1) begin
                    a_area[hit0] <= a_area[hit0] + {8'd0, run_len} + a_area[hit1];
                    if (a_bx0[hit1] < a_bx0[hit0]) a_bx0[hit0] <= a_bx0[hit1];
                    if (a_bx1[hit1] > a_bx1[hit0]) a_bx1[hit0] <= a_bx1[hit1];
                    if (a_by0[hit1] < a_by0[hit0]) a_by0[hit0] <= a_by0[hit1];
                    if (a_by1[hit1] > a_by1[hit0]) a_by1[hit0] <= a_by1[hit1];
                    a_valid[hit1] <= 1'b0;
                end
            end else if (has_free) begin
                a_valid[free_idx] <= 1'b1;
                a_area[free_idx]  <= {8'd0, run_len};
                a_lx0[free_idx]   <= run_s;
                a_lx1[free_idx]   <= run_e;
                a_bx0[free_idx]   <= run_s;
                a_bx1[free_idx]   <= run_e;
                a_by0[free_idx]   <= yc;
                a_by1[free_idx]   <= yc;
            end
        end
    end

    // ---------------- frame end: max area ----------------
    integer j;
    reg [15:0] best_area, best2_area;
    reg [3:0]  best_idx,  best2_idx;
    reg        best_ok,   best2_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_bx0 <= 11'd0; o_bx1 <= 11'd0; o_by0 <= 11'd0; o_by1 <= 11'd0;
            o_area <= 16'd0; o_valid <= 1'b0;
            o2_bx0 <= 11'd0; o2_bx1 <= 11'd0; o2_by0 <= 11'd0; o2_by1 <= 11'd0;
            o2_valid <= 1'b0;
        end else if (vs_rise) begin
            best_area = 16'd0; best_idx = 4'd0; best_ok = 1'b0;
            for (j = 0; j < NENT; j = j + 1) begin
                if (a_valid[j] && (a_area[j] >= MIN_AREA[15:0]) &&
                    ((a_bx0[j] + a_bx1[j]) > 7'd40) && ((a_bx0[j] + a_bx1[j]) < 7'd200) &&
                    ((a_by0[j] + a_by1[j]) > 7'd30) && ((a_by0[j] + a_by1[j]) < 7'd230) &&
                    ((a_bx1[j] - a_bx0[j]) <= 2 * (a_by1[j] - a_by0[j]) + 2) &&
                    ((a_by1[j] - a_by0[j]) <= 2 * (a_bx1[j] - a_bx0[j]) + 2) &&
                    (a_area[j] > best_area)) begin
                    best_area = a_area[j]; best_idx = j[3:0]; best_ok = 1'b1;
                end
            end
            // 第二遍（仅当没有中心块时）：退回纯面积
            best2_area = 16'd0; best2_idx = 4'd0; best2_ok = 1'b0;
            for (j = 0; j < NENT; j = j + 1) begin
                if (a_valid[j] && (a_area[j] >= MIN_AREA[15:0]) && (a_area[j] > best2_area) &&
                    ((a_bx1[j] - a_bx0[j]) <= 2 * (a_by1[j] - a_by0[j]) + 2) &&
                    ((a_by1[j] - a_by0[j]) <= 2 * (a_bx1[j] - a_bx0[j]) + 2)) begin
                    if (a_area[j] > best_area) begin
                        best2_area = best_area; best2_idx = best_idx; best2_ok = best_ok;
                        best_area  = a_area[j];  best_idx  = j[3:0];    best_ok  = 1'b1;
                    end else begin
                        best2_area = a_area[j]; best2_idx = j[3:0]; best2_ok = 1'b1;
                    end
                end
            end
            o_valid <= best_ok;
            o_area  <= best_ok ? best_area : 16'd0;
            o_bx0   <= best_ok ? {a_bx0[best_idx], 3'b000} : 11'd0;
            o_bx1   <= best_ok ? ({a_bx1[best_idx], 3'b000} + 11'd7) : 11'd0;
            o_by0   <= best_ok ? {a_by0[best_idx], 3'b000} : 11'd0;
            o_by1   <= best_ok ? ({a_by1[best_idx], 3'b000} + 11'd7) : 11'd0;
            o2_valid<= best2_ok;
            o2_bx0  <= best2_ok ? {a_bx0[best2_idx], 3'b000} : 11'd0;
            o2_bx1  <= best2_ok ? ({a_bx1[best2_idx], 3'b000} + 11'd7) : 11'd0;
            o2_by0  <= best2_ok ? {a_by0[best2_idx], 3'b000} : 11'd0;
            o2_by1  <= best2_ok ? ({a_by1[best2_idx], 3'b000} + 11'd7) : 11'd0;
        end
    end
endmodule
