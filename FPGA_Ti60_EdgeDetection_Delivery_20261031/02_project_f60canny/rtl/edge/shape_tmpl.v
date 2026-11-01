//==============================================================================
// shape_tmpl.v —— 32×32 模板匹配引擎（4 类 × 0/15/30/45°）
//
//   口径
//   ────────────────────────────────────────────────────────────────────────
//   * 32×32 网格来自**上一帧 bbox**（与 R9 窗口同一套一帧滞后）；
//   * 全分辨率前景（2ppx，i_g<TY=170），不是 1/16 抽样；
//   * 每格 10bit 饱和计数，thr = bw*bh/2048（≤1012），cnt>thr 记 1；
//   * 1024 格 × 16bit 模板 ROM，XOR 后累加 16 个 11bit 汉明距离；
//   * 最小距离 < THAM 才输出类别，否则 unknown。
//
//   资源
//   ────────────────────────────────────────────────────────────────────────
//   计数 RAM：1024×10 = 1 × RAM10
//   模板 ROM：1024×16 = 2 × RAM10
//   行缓存  ：32×10 寄存器，gy 变化时 32 拍 flush
//
//   时序
//   ────────────────────────────────────────────────────────────────────────
//   vs 后：最后一行 flush 32 拍 → 1024 格比对 1026 拍 → S_MIN 1 拍
//          → 清 1024 格 1024 拍，共 ~2083 拍 ≈ 28us @74.25MHz。
//==============================================================================
module shape_tmpl #(
    parameter integer H_PAIRS    = 960,
    parameter integer V_LINES    = 1080,
    parameter integer TMPL_MIN   = 32,
    parameter integer THAM       = 256
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_g1,
    input  wire [7:0]  i_ty,        // adaptive threshold from shape_recog (ty_eff)
    input  wire [10:0] i_bx0,
    input  wire [10:0] i_bx1,
    input  wire [10:0] i_by0,
    input  wire [10:0] i_by1,
    input  wire [10:0] i_thr,
    input  wire        i_valid,
    output reg  [2:0]  o_cls,
    output reg         o_upd,
    output wire [10:0] o_min_dist,
    output wire [3:0]  o_min_idx
);

    localparam [2:0] S_RUN    = 3'd0;
    localparam [2:0] S_LFLUSH = 3'd1;
    localparam [2:0] S_FLUSH  = 3'd2;
    localparam [2:0] S_CMP    = 3'd3;
    localparam [2:0] S_MIN    = 3'd4;
    localparam [2:0] S_CLR    = 3'd5;

    reg  [2:0]  state;
    reg  [10:0] cmp_idx;
    reg  [9:0]  clr_idx;
    reg  [4:0]  flush_idx;
    reg  [4:0]  flush_gy;
    reg  [4:0]  gy;
    reg  [10:0] by_acc;
    reg         row_dirty;
    reg         line_flush_pending;
    reg         vs_pending;
    reg  [2:0]  o_cls_r;
    reg         o_upd_r;
    reg  [10:0] hdist [0:15];

    integer fi;
    integer ri;
    integer mi;

    //--------------------------------------------------------------------------
    // 1. 行/列计数
    //--------------------------------------------------------------------------
    wire fg0 = (i_g0 < i_ty);
    wire fg1 = (i_g1 < i_ty);

    reg vs_d;
    wire vs_rise = i_vs & ~vs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= i_vs;
    end

    reg [9:0] pcol;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                        pcol <= 10'd0;
        else if (!i_de)                    pcol <= 10'd0;
        else if (pcol == (H_PAIRS - 1))    pcol <= 10'd0;
        else                               pcol <= pcol + 10'd1;
    end

    wire [11:0] x0 = {1'b0, pcol, 1'b0};
    wire [11:0] x1 = x0 + 12'd1;

    reg [11:0] row;
    reg        de_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row  <= 12'd0;
            de_d <= 1'b0;
        end else begin
            de_d <= i_de;
            if (i_vs)                       row <= 12'd0;
            else if (de_d && !i_de)         row <= row + 12'd1;
        end
    end
    wire line_end = de_d && !i_de;

    //--------------------------------------------------------------------------
    // 2. bbox 口径
    //--------------------------------------------------------------------------
    wire [11:0] bw = (i_bx1 >= i_bx0) ? ({1'b0, i_bx1} - {1'b0, i_bx0} + 12'd1) : 12'd0;
    wire [11:0] bh = (i_by1 >= i_by0) ? ({1'b0, i_by1} - {1'b0, i_by0} + 12'd1) : 12'd0;

    wire bbox_ok = i_valid && (bw >= TMPL_MIN) && (bh >= TMPL_MIN);
    wire row_in  = bbox_ok &&
                   (row >= {1'b0, i_by0}) && (row <= {1'b0, i_by1});

    wire [11:0] next_row = row + 12'd1;
    wire next_in = bbox_ok &&
                   (next_row >= {1'b0, i_by0}) && (next_row <= {1'b0, i_by1});

    //--------------------------------------------------------------------------
    // 3. x 方向：两像素/拍相位累加器
    //--------------------------------------------------------------------------
    reg  [10:0] bx_acc;
    reg  [4:0]  gx;
    reg         map_started;

    wire count_row = (state == S_RUN) && row_in;
    wire start_now = count_row && !map_started && (x0 >= {1'b0, i_bx0});
    wire proc      = count_row && (map_started || start_now);

    wire [11:0] a0  = bx_acc + 12'd32;
    wire        c0  = (a0 >= bw);
    wire [11:0] a0r = c0 ? (a0 - bw) : a0;
    wire [11:0] a1  = a0r + 12'd32;
    wire        c1  = (a1 >= bw);
    wire [11:0] a1r = c1 ? (a1 - bw) : a1;

    wire [5:0]  gx0_6  = {1'b0, gx};
    wire [5:0]  gx1_6  = gx0_6 + {5'd0, c0};
    wire [5:0]  gxn_6  = gx0_6 + {5'd0, c0} + {5'd0, c1};
    wire [4:0]  gx_next = (gxn_6 > 6'd31) ? 5'd31 : gxn_6[4:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bx_acc      <= 11'd0;
            gx          <= 5'd0;
            map_started <= 1'b0;
        end else if (!i_de) begin
            bx_acc      <= 11'd0;
            gx          <= 5'd0;
            map_started <= 1'b0;
        end else if (proc) begin
            bx_acc      <= a1r[10:0];
            gx          <= gx_next;
            map_started <= 1'b1;
        end
    end

    wire in_x0 = proc && (x0 >= {1'b0, i_bx0}) && (x0 <= {1'b0, i_bx1});
    wire in_x1 = proc && (x1 >= {1'b0, i_bx0}) && (x1 <= {1'b0, i_bx1});
    wire hit0  = in_x0 && fg0;
    wire hit1  = in_x1 && fg1;

    //--------------------------------------------------------------------------
    // 4. y 方向：每行进一格
    //--------------------------------------------------------------------------
    wire [11:0] b0  = by_acc + 12'd32;
    wire        cb  = (b0 >= bh);
    wire [11:0] b0r = cb ? (b0 - bh) : b0;
    wire [5:0]  gy_6 = {1'b0, gy} + {5'd0, cb};
    wire [4:0]  next_gy = gy_6[4:0];

    //--------------------------------------------------------------------------
    // 5. 行缓存 32×10（饱和）
    //--------------------------------------------------------------------------
    reg [9:0] rowcnt [0:31];
    reg [1:0]  add_i;
    reg [10:0] sum_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ri = 0; ri < 32; ri = ri + 1)
                rowcnt[ri] <= 10'd0;
        end else if (state == S_MIN) begin
            for (ri = 0; ri < 32; ri = ri + 1)
                rowcnt[ri] <= 10'd0;
        end else if ((state == S_LFLUSH) || (state == S_FLUSH)) begin
            rowcnt[flush_idx] <= 10'd0;
        end else if (state == S_RUN) begin
            for (ri = 0; ri < 32; ri = ri + 1) begin
                add_i = (hit0 && (gx0_6 == ri)) ? 2'd1 : 2'd0;
                add_i = add_i + ((hit1 && (gx1_6 == ri)) ? 2'd1 : 2'd0);
                sum_i = rowcnt[ri] + {9'd0, add_i};
                rowcnt[ri] <= (sum_i > 11'd1023) ? 10'd1023 : sum_i[9:0];
            end
        end
    end

    //--------------------------------------------------------------------------
    // 6. 计数 RAM（1024×10，1 读 1 写）
    //--------------------------------------------------------------------------
    reg  [9:0] grid_ram [0:1023];

    reg  [9:0] ram_wr_addr;
    reg  [9:0] ram_wr_data;
    reg        ram_we;
    reg  [9:0] ram_rd;
    wire [9:0] ram_rd_addr = (state == S_CMP) ? cmp_idx[9:0] : 10'd0;

    always @* begin
        ram_we      = 1'b0;
        ram_wr_addr = 10'd0;
        ram_wr_data = 10'd0;
        if ((state == S_LFLUSH) || (state == S_FLUSH)) begin
            ram_we      = 1'b1;
            ram_wr_addr = {flush_gy, flush_idx};
            ram_wr_data = rowcnt[flush_idx];
        end else if (state == S_CLR) begin
            ram_we      = 1'b1;
            ram_wr_addr = clr_idx;
            ram_wr_data = 10'd0;
        end
    end

    always @(posedge clk) begin
        if (ram_we)
            grid_ram[ram_wr_addr] <= ram_wr_data;
        ram_rd <= grid_ram[ram_rd_addr];
    end

    //--------------------------------------------------------------------------
    // 7. 模板 ROM（1024×16，只读）
    //--------------------------------------------------------------------------
    reg [15:0] tmpl_rom [0:1023];
    initial begin
        $readmemh("rtl/edge/shape_templates.mem", tmpl_rom);
    end

    reg [15:0] rom_rd;
    always @(posedge clk) begin
        rom_rd <= tmpl_rom[ram_rd_addr];
    end

    //--------------------------------------------------------------------------
    // 8. 最小值（T1 修复：串行 16 拍）
    //    原实现是组合式 16 路比较链，实测 52 级逻辑、vid 域 slack 仅 +0.055 ns。
    //    改为在 S_MIN 状态分 16 拍扫描（每拍只比较一个候选），关键路径降到 1 级比较。
    //--------------------------------------------------------------------------
    reg  [4:0]  min_k;
    reg  [10:0] min_d_r;
    reg  [3:0]  min_idx_r;
    reg         valid_l;

    assign o_min_dist = min_d_r;
    assign o_min_idx  = min_idx_r;

    //--------------------------------------------------------------------------
    // 9. 主 FSM
    //--------------------------------------------------------------------------
    wire obs_cmp = (ram_rd > i_thr);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_CLR;
            cmp_idx            <= 11'd0;
            clr_idx            <= 10'd0;
            flush_idx          <= 5'd0;
            flush_gy           <= 5'd0;
            gy                 <= 5'd0;
            by_acc             <= 11'd0;
            row_dirty          <= 1'b0;
            line_flush_pending <= 1'b0;
            vs_pending         <= 1'b0;
            o_cls_r            <= 3'd0;
            o_upd_r            <= 1'b0;
            min_k              <= 5'd0;
            min_d_r            <= 11'd2047;
            min_idx_r          <= 4'd0;
            valid_l            <= 1'b0;
            for (fi = 0; fi < 16; fi = fi + 1)
                hdist[fi] <= 11'd0;
        end else begin
            o_upd_r <= 1'b0;

            // ---- 行末：gy 推进 / 离开 bbox → 请求 flush ----
            if (state == S_RUN && line_end && bbox_ok) begin
                if (row_in) begin
                    if (!next_in) begin
                        if (row_dirty) begin
                            line_flush_pending <= 1'b1;
                            flush_gy           <= gy;
                        end
                    end else if (next_gy != gy) begin
                        if (row_dirty) begin
                            line_flush_pending <= 1'b1;
                            flush_gy           <= gy;
                        end
                    end
                    if (next_in) begin
                        by_acc <= b0r[10:0];
                        gy     <= next_gy;
                    end
                end else if (next_in && (next_row == {1'b0, i_by0})) begin
                    by_acc <= 11'd0;
                    gy     <= 5'd0;
                end
            end

            if (state == S_RUN && (hit0 || hit1))
                row_dirty <= 1'b1;

            case (state)
            //------------------------------------------------------------------
            S_RUN: begin
                if (vs_rise) begin
                    line_flush_pending <= 1'b0;
                    if (!i_valid) begin
                        min_k   <= 5'd0;
                        min_d_r <= 11'd2047;
                        valid_l <= 1'b0;
                        state   <= S_MIN;
                    end else if (row_dirty) begin
                        if (!line_flush_pending)
                            flush_gy <= gy;
                        flush_idx <= 5'd0;
                        state     <= S_FLUSH;
                    end else begin
                        for (fi = 0; fi < 16; fi = fi + 1)
                            hdist[fi] <= 11'd0;
                        cmp_idx <= 11'd0;
                        state   <= S_CMP;
                    end
                end else if (line_flush_pending) begin
                    line_flush_pending <= 1'b0;
                    flush_idx          <= 5'd0;
                    state              <= S_LFLUSH;
                end
            end

            //------------------------------------------------------------------
            S_LFLUSH: begin
                if (flush_idx == 5'd31) begin
                    flush_idx <= 5'd0;
                    row_dirty <= 1'b0;
                    if (vs_pending || vs_rise) begin
                        vs_pending <= 1'b0;
                        state      <= S_FLUSH;
                    end else begin
                        state <= S_RUN;
                    end
                end else begin
                    flush_idx <= flush_idx + 5'd1;
                end
                if (vs_rise)
                    vs_pending <= 1'b1;
            end

            //------------------------------------------------------------------
            S_FLUSH: begin
                if (!row_dirty) begin
                    if (i_valid) begin
                        for (fi = 0; fi < 16; fi = fi + 1)
                            hdist[fi] <= 11'd0;
                        cmp_idx <= 11'd0;
                        state   <= S_CMP;
                    end else begin
                        min_k   <= 5'd0;
                        min_d_r <= 11'd2047;
                        valid_l <= 1'b0;
                        state   <= S_MIN;
                    end
                end else if (flush_idx == 5'd31) begin
                    flush_idx <= 5'd0;
                    row_dirty <= 1'b0;
                    if (i_valid) begin
                        for (fi = 0; fi < 16; fi = fi + 1)
                            hdist[fi] <= 11'd0;
                        cmp_idx <= 11'd0;
                        state   <= S_CMP;
                    end else begin
                        min_k   <= 5'd0;
                        min_d_r <= 11'd2047;
                        valid_l <= 1'b0;
                        state   <= S_MIN;
                    end
                end else begin
                    flush_idx <= flush_idx + 5'd1;
                end
            end

            //------------------------------------------------------------------
            S_CMP: begin
                if (cmp_idx <= 11'd1024) begin
                    if (cmp_idx >= 11'd1) begin
                        for (fi = 0; fi < 16; fi = fi + 1)
                            hdist[fi] <= hdist[fi] + {10'd0, (obs_cmp ^ rom_rd[fi])};
                    end
                    cmp_idx <= cmp_idx + 11'd1;
                end else if (cmp_idx == 11'd1025) begin
                    min_k   <= 5'd0;
                    min_d_r <= 11'd2047;
                    valid_l <= i_valid;
                    state   <= S_MIN;
                end
            end

            //------------------------------------------------------------------
            S_MIN: begin
                // 串行 16 拍求最小汉明距离（min_k=0..15 扫描，第 16 拍出结果）
                if (min_k < 5'd16) begin
                    if (hdist[min_k[3:0]] < min_d_r) begin
                        min_d_r   <= hdist[min_k[3:0]];
                        min_idx_r <= min_k[3:0];
                    end
                    min_k <= min_k + 5'd1;
                end else begin
                    o_cls_r <= (valid_l && (min_d_r < THAM)) ?
                               (min_idx_r[3:2] + 3'd1) : 3'd0;
                    o_upd_r <= 1'b1;
                    gy                 <= 5'd0;
                    by_acc             <= 11'd0;
                    row_dirty          <= 1'b0;
                    line_flush_pending <= 1'b0;
                    vs_pending         <= 1'b0;
                    clr_idx            <= 10'd0;
                    state              <= S_CLR;
                end
            end

            //------------------------------------------------------------------
            S_CLR: begin
                if (clr_idx == 10'd1023) begin
                    clr_idx <= 10'd0;
                    state   <= S_RUN;
                end else begin
                    clr_idx <= clr_idx + 10'd1;
                end
            end

            default: state <= S_CLR;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 10. 输出
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_cls <= 3'd0;
            o_upd <= 1'b0;
        end else begin
            o_cls <= o_cls_r;
            o_upd <= o_upd_r;
        end
    end

endmodule
