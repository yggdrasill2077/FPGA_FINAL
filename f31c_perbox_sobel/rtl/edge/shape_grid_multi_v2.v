//==============================================================================
// shape_grid_multi_v2.v -- parameterised multi-object candidate extractor
//
//  4x4 block stream -> GRID_X x GRID_Y cell statistics -> frame-end BFS CCL
//  -> up to four tight bboxes / moment centroids for the polar classifier.
//
//  The design deliberately keeps three separate decisions:
//    1) a cell is a seed only when it contains CELL_SEED_MIN foreground blocks;
//    2) a neighbour joins only when it contains CELL_MERGE_MIN blocks and its
//       tight bbox intersects the current cell bbox after MERGE_GAP dilation;
//    3) a component becomes a candidate only when area, bbox and fill pass.
//
//  This is the hardware-friendly form of region adjacency graph merging used
//  by single-pass CCL / region-labelling work: heavy work is outside the pixel
//  path and no full-frame binary image is stored.
//==============================================================================
module shape_grid_multi_v2 #(
    parameter integer H_PAIRS        = 960,
    parameter integer V_LINES        = 1080,
    parameter integer GRID_X         = 32,
    parameter integer GRID_Y         = 18,
    parameter integer CELL_SEED_MIN  = 4,
    parameter integer CELL_MERGE_MIN = 1,
    parameter integer MIN_AREA       = 32,
    parameter integer MIN_BBOX       = 8,
    parameter integer FILL_MIN       = 4,      // Q8: 4/256 = 1.56 %
    parameter integer MERGE_GAP      = 1,      // blocks of bbox dilation
    parameter integer MAX_BBOX_W     = 1800,
    parameter integer MAX_BBOX_H     = 1000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [7:0]  i_g0,
    input  wire [7:0]  i_g1,
    input  wire [7:0]  i_ty,

    output reg  [2:0]  o_num,
    output reg  [3:0]  o_valid,
    output wire [43:0] o_bx0,
    output wire [43:0] o_bx1,
    output wire [43:0] o_by0,
    output wire [43:0] o_by1,
    output wire [107:0] o_sx,
    output wire [107:0] o_sy,
    output wire [63:0] o_area,
    output reg         o_done
);

    localparam integer IMG_W  = H_PAIRS * 2;
    localparam integer BLK_W  = IMG_W / 4;
    localparam integer BLK_H  = (V_LINES + 3) / 4;
    localparam integer CBW    = (BLK_W + GRID_X - 1) / GRID_X;
    localparam integer CBH    = (BLK_H + GRID_Y - 1) / GRID_Y;
    localparam integer NCELL  = GRID_X * GRID_Y;
    localparam integer COL_W  = $clog2(GRID_X);
    localparam integer ROW_W  = $clog2(GRID_Y);
    localparam integer ADDR_W = $clog2(NCELL);
    localparam integer POS_W  = ((COL_W > ROW_W) ? COL_W : ROW_W) + 2;
    localparam integer CCW    = $clog2(CBW + 1);
    localparam integer CRW    = $clog2(CBH + 1);
    localparam integer REC_W  = 12 + 20 + 19 + 9 + 9 + 9 + 9;

    //--------------------------------------------------------------------------
    // Pixel / block position
    //--------------------------------------------------------------------------
    reg [9:0]  pcol;
    reg [11:0] row;
    reg        de_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcol <= 10'd0;
            row  <= 12'd0;
            de_d <= 1'b0;
        end else begin
            de_d <= i_de;
            if (i_vs)
                row <= 12'd0;
            else if (de_d && !i_de)
                row <= row + 12'd1;

            if (!i_de)
                pcol <= 10'd0;
            else if (pcol == (H_PAIRS-1))
                pcol <= 10'd0;
            else
                pcol <= pcol + 10'd1;
        end
    end

    wire [8:0] blk_x     = pcol[9:1];
    wire [8:0] blk_y     = row[10:2];
    wire       blk_last  = i_de && pcol[0] && (row[1:0] == 2'b11);
    wire       line_last = blk_last && (pcol == (H_PAIRS-1));
    wire       fg_pair   = (i_g0 < i_ty) || (i_g1 < i_ty);

    reg blk_fg;
    wire blk_fg_now = blk_fg | fg_pair;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            blk_fg <= 1'b0;
        else if (!i_de || blk_last)
            blk_fg <= 1'b0;
        else
            blk_fg <= blk_fg_now;
    end

    //--------------------------------------------------------------------------
    // One live accumulator per grid column.  At the end of a cell row the
    // GRID_X words are committed to cell_ram during horizontal blanking.
    //--------------------------------------------------------------------------
    reg [11:0] acc_cnt  [0:GRID_X-1];
    reg [19:0] acc_sx   [0:GRID_X-1];
    reg [18:0] acc_sy   [0:GRID_X-1];
    reg [8:0]  acc_minx [0:GRID_X-1];
    reg [8:0]  acc_maxx [0:GRID_X-1];
    reg [8:0]  acc_miny [0:GRID_X-1];
    reg [8:0]  acc_maxy [0:GRID_X-1];

    reg [CCW-1:0] col_in_cell;
    reg [COL_W-1:0] cell_col;
    reg [CRW-1:0] row_in_cell;
    reg [ROW_W-1:0] cell_row;

    reg [REC_W-1:0] cell_ram [0:NCELL-1];

    // Explicitly packed per column.  A function with a dynamic array index is
    // legal Verilog, but some simulators fail to add the array contents to the
    // sensitivity list of a continuous assignment.  That silently writes a zero
    // record for column 0 and truncates targets at the left edge.  Keep the
    // packing combinational, but make every column an explicit mux input.
    wire [REC_W-1:0] acc_pack [0:GRID_X-1];
    genvar gp;
    generate
        for (gp = 0; gp < GRID_X; gp = gp + 1) begin : G_PACK_ACC
            assign acc_pack[gp] = {acc_cnt[gp], acc_sx[gp], acc_sy[gp],
                                   acc_minx[gp], acc_maxx[gp],
                                   acc_miny[gp], acc_maxy[gp]};
        end
    endgenerate

    localparam P_RUN = 1'b0;
    localparam P_WR  = 1'b1;
    reg        p_state;
    reg [COL_W-1:0] wr_idx;

    reg [REC_W-1:0] cell_wr_data_mux;
    integer pk;
    always @* begin
        cell_wr_data_mux = acc_pack[0];
        for (pk = 0; pk < GRID_X; pk = pk + 1) begin
            if (wr_idx == pk)
                cell_wr_data_mux = acc_pack[pk];
        end
    end

    // Keep the memory write in a reset-free synchronous block so synthesis can
    // infer block RAM instead of expanding 576 x 87 bits into flip-flops.
    wire                 cell_wr_en   = (p_state == P_WR);
    wire [ADDR_W-1:0]    cell_wr_addr = cell_row * GRID_X + wr_idx;
    wire [REC_W-1:0]     cell_wr_data = cell_wr_data_mux;
    always @(posedge clk) begin
        if (cell_wr_en)
            cell_ram[cell_wr_addr] <= cell_wr_data;
    end

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_in_cell <= {CCW{1'b0}};
            cell_col    <= {COL_W{1'b0}};
            row_in_cell <= {CRW{1'b0}};
            cell_row    <= {ROW_W{1'b0}};
            p_state     <= P_RUN;
            wr_idx      <= {COL_W{1'b0}};
            for (ii = 0; ii < GRID_X; ii = ii + 1) begin
                acc_cnt[ii]  <= 12'd0;
                acc_sx[ii]   <= 20'd0;
                acc_sy[ii]   <= 19'd0;
                acc_minx[ii] <= 9'd511;
                acc_maxx[ii] <= 9'd0;
                acc_miny[ii] <= 9'd511;
                acc_maxy[ii] <= 9'd0;
            end
        end else if (i_vs) begin
            col_in_cell <= {CCW{1'b0}};
            cell_col    <= {COL_W{1'b0}};
            row_in_cell <= {CRW{1'b0}};
            cell_row    <= {ROW_W{1'b0}};
            p_state     <= P_RUN;
            wr_idx      <= {COL_W{1'b0}};
            for (ii = 0; ii < GRID_X; ii = ii + 1) begin
                acc_cnt[ii]  <= 12'd0;
                acc_sx[ii]   <= 20'd0;
                acc_sy[ii]   <= 19'd0;
                acc_minx[ii] <= 9'd511;
                acc_maxx[ii] <= 9'd0;
                acc_miny[ii] <= 9'd511;
                acc_maxy[ii] <= 9'd0;
            end
        end else if (p_state == P_WR) begin
            if (wr_idx == (GRID_X-1)) begin
                wr_idx      <= {COL_W{1'b0}};
                p_state     <= P_RUN;
                cell_col    <= {COL_W{1'b0}};
                col_in_cell <= {CCW{1'b0}};
                row_in_cell <= {CRW{1'b0}};
                cell_row    <= cell_row + 1'b1;
                for (ii = 0; ii < GRID_X; ii = ii + 1) begin
                    acc_cnt[ii]  <= 12'd0;
                    acc_sx[ii]   <= 20'd0;
                    acc_sy[ii]   <= 19'd0;
                    acc_minx[ii] <= 9'd511;
                    acc_maxx[ii] <= 9'd0;
                    acc_miny[ii] <= 9'd511;
                    acc_maxy[ii] <= 9'd0;
                end
            end else begin
                wr_idx <= wr_idx + 1'b1;
            end
        end else if (blk_last) begin
            if (blk_fg_now) begin
                acc_cnt[cell_col]  <= acc_cnt[cell_col]  + 12'd1;
                acc_sx[cell_col]   <= acc_sx[cell_col]   + {11'd0, blk_x};
                acc_sy[cell_col]   <= acc_sy[cell_col]   + {12'd0, blk_y};
                if (blk_x < acc_minx[cell_col]) acc_minx[cell_col] <= blk_x;
                if (blk_x > acc_maxx[cell_col]) acc_maxx[cell_col] <= blk_x;
                if (blk_y < acc_miny[cell_col]) acc_miny[cell_col] <= blk_y;
                if (blk_y > acc_maxy[cell_col]) acc_maxy[cell_col] <= blk_y;
            end

            // Handle both exact and partial (tail) grid cells.  The tail
            // column ends at the real last block, not at the nominal CBW-1.
            if (cell_col == (GRID_X-1)) begin
                if (blk_x == (BLK_W-1)) begin
                    if (line_last) begin
                        if ((row_in_cell == (CBH-1)) ||
                            ((cell_row == (GRID_Y-1)) &&
                             (blk_y == (BLK_H-1)))) begin
                            p_state <= P_WR;
                        end else begin
                            row_in_cell <= row_in_cell + 1'b1;
                            cell_col    <= {COL_W{1'b0}};
                            col_in_cell <= {CCW{1'b0}};
                        end
                    end else begin
                        cell_col    <= {COL_W{1'b0}};
                        col_in_cell <= {CCW{1'b0}};
                    end
                end else begin
                    col_in_cell <= col_in_cell + 1'b1;
                end
            end else if (col_in_cell == (CBW-1)) begin
                cell_col    <= cell_col + 1'b1;
                col_in_cell <= {CCW{1'b0}};
            end else begin
                col_in_cell <= col_in_cell + 1'b1;
            end
        end
    end

    // One-cycle BRAM read port.
    reg [ADDR_W-1:0] rd_addr;
    reg [REC_W-1:0]  rd_data;
    always @(posedge clk) rd_data <= cell_ram[rd_addr];

    wire [11:0] rd_cnt  = rd_data[86:75];
    wire [19:0] rd_sx   = rd_data[74:55];
    wire [18:0] rd_sy   = rd_data[54:36];
    wire [8:0]  rd_minx = rd_data[35:27];
    wire [8:0]  rd_maxx = rd_data[26:18];
    wire [8:0]  rd_miny = rd_data[17:9];
    wire [8:0]  rd_maxy = rd_data[8:0];

    //--------------------------------------------------------------------------
    // Frame-end BFS over the cell adjacency graph.
    //--------------------------------------------------------------------------
    reg vs_d;
    wire vs_rise = i_vs & ~vs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= i_vs;
    end

    localparam [3:0] C_IDLE      = 4'd0;
    localparam [3:0] C_SCAN_RD   = 4'd1;
    localparam [3:0] C_SCAN_WAIT = 4'd2;
    localparam [3:0] C_SCAN_CHK  = 4'd3;
    localparam [3:0] C_POP       = 4'd4;
    localparam [3:0] C_POP_WAIT1 = 4'd5;
    localparam [3:0] C_POP_WAIT  = 4'd6;
    localparam [3:0] C_NB        = 4'd7;
    localparam [3:0] C_NB_WAIT1  = 4'd8;
    localparam [3:0] C_NB_WAIT   = 4'd9;
    localparam [3:0] C_INSERT    = 4'd10;
    localparam [3:0] C_DONE      = 4'd11;

    reg [3:0]       c_state;
    reg             ccl_pending;
    reg [ADDR_W-1:0] scan_idx;
    reg [ADDR_W-1:0] q_mem [0:NCELL-1];
    reg [ADDR_W-1:0] q_head, q_tail;
    reg [NCELL-1:0] visited;

    reg [ADDR_W-1:0] cur_cell;
    reg [2:0]        nb_idx;
    reg [ADDR_W-1:0] nb_cell;
    reg              nb_geom_ok;

    reg [15:0] comp_cnt;
    reg [26:0] comp_sx, comp_sy;
    reg [8:0]  comp_minx, comp_maxx, comp_miny, comp_maxy;
    reg [8:0]  cur_minx, cur_maxx, cur_miny, cur_maxy;

    reg [15:0] c_cnt  [0:3];
    reg [8:0]  c_minx [0:3];
    reg [8:0]  c_maxx [0:3];
    reg [8:0]  c_miny [0:3];
    reg [8:0]  c_maxy [0:3];
    reg [26:0] c_sx   [0:3];
    reg [26:0] c_sy   [0:3];

    // Fallback candidate used only when the strict pass produces no box.
    // A single close-up target often touches one image edge (or exceeds the
    // nominal 1800x1000 bbox cap), while multi-target scenes stay compact and
    // are unaffected by this path.
    reg        fb_valid;
    reg [15:0] fb_cnt;
    reg [8:0]  fb_minx, fb_maxx, fb_miny, fb_maxy;
    reg [26:0] fb_sx, fb_sy;

    // Last-resort component for a very small / far single target.  It is used
    // only when neither the strict pass nor the large-border fallback produced
    // any box, so normal multi-target sorting is unchanged.
    reg        fb2_valid;
    reg [15:0] fb2_cnt;
    reg [8:0]  fb2_minx, fb2_maxx, fb2_miny, fb2_maxy;
    reg [26:0] fb2_sx, fb2_sy;

    wire [9:0] cur_x0 = (cur_minx > MERGE_GAP) ?
                        ({1'b0,cur_minx} - MERGE_GAP) : 10'd0;
    wire [9:0] cur_x1 = (({1'b0,cur_maxx} + MERGE_GAP) < BLK_W) ?
                        ({1'b0,cur_maxx} + MERGE_GAP) : (BLK_W-1);
    wire [9:0] cur_y0 = (cur_miny > MERGE_GAP) ?
                        ({1'b0,cur_miny} - MERGE_GAP) : 10'd0;
    wire [9:0] cur_y1 = (({1'b0,cur_maxy} + MERGE_GAP) < BLK_H) ?
                        ({1'b0,cur_maxy} + MERGE_GAP) : (BLK_H-1);

    wire bbox_overlap = ({1'b0,rd_minx} <= cur_x1) && ({1'b0,rd_maxx} >= cur_x0) &&
                        ({1'b0,rd_miny} <= cur_y1) && ({1'b0,rd_maxy} >= cur_y0);

    task insert_candidate;
        input [15:0] a;
        input [8:0]  x0, x1, y0, y1;
        input [26:0] sx, sy;
        begin
            if (a > c_cnt[0]) begin
                c_cnt[3]<=c_cnt[2]; c_minx[3]<=c_minx[2]; c_maxx[3]<=c_maxx[2];
                c_miny[3]<=c_miny[2]; c_maxy[3]<=c_maxy[2]; c_sx[3]<=c_sx[2]; c_sy[3]<=c_sy[2];
                c_cnt[2]<=c_cnt[1]; c_minx[2]<=c_minx[1]; c_maxx[2]<=c_maxx[1];
                c_miny[2]<=c_miny[1]; c_maxy[2]<=c_maxy[1]; c_sx[2]<=c_sx[1]; c_sy[2]<=c_sy[1];
                c_cnt[1]<=c_cnt[0]; c_minx[1]<=c_minx[0]; c_maxx[1]<=c_maxx[0];
                c_miny[1]<=c_miny[0]; c_maxy[1]<=c_maxy[0]; c_sx[1]<=c_sx[0]; c_sy[1]<=c_sy[0];
                c_cnt[0]<=a; c_minx[0]<=x0; c_maxx[0]<=x1;
                c_miny[0]<=y0; c_maxy[0]<=y1; c_sx[0]<=sx; c_sy[0]<=sy;
            end else if (a > c_cnt[1]) begin
                c_cnt[3]<=c_cnt[2]; c_minx[3]<=c_minx[2]; c_maxx[3]<=c_maxx[2];
                c_miny[3]<=c_miny[2]; c_maxy[3]<=c_maxy[2]; c_sx[3]<=c_sx[2]; c_sy[3]<=c_sy[2];
                c_cnt[2]<=c_cnt[1]; c_minx[2]<=c_minx[1]; c_maxx[2]<=c_maxx[1];
                c_miny[2]<=c_miny[1]; c_maxy[2]<=c_maxy[1]; c_sx[2]<=c_sx[1]; c_sy[2]<=c_sy[1];
                c_cnt[1]<=a; c_minx[1]<=x0; c_maxx[1]<=x1;
                c_miny[1]<=y0; c_maxy[1]<=y1; c_sx[1]<=sx; c_sy[1]<=sy;
            end else if (a > c_cnt[2]) begin
                c_cnt[3]<=c_cnt[2]; c_minx[3]<=c_minx[2]; c_maxx[3]<=c_maxx[2];
                c_miny[3]<=c_miny[2]; c_maxy[3]<=c_maxy[2]; c_sx[3]<=c_sx[2]; c_sy[3]<=c_sy[2];
                c_cnt[2]<=a; c_minx[2]<=x0; c_maxx[2]<=x1;
                c_miny[2]<=y0; c_maxy[2]<=y1; c_sx[2]<=sx; c_sy[2]<=sy;
            end else if (a > c_cnt[3]) begin
                c_cnt[3]<=a; c_minx[3]<=x0; c_maxx[3]<=x1;
                c_miny[3]<=y0; c_maxy[3]<=y1; c_sx[3]<=sx; c_sy[3]<=sy;
            end
        end
    endtask

    wire [8:0]  bbw = (comp_maxx >= comp_minx) ? (comp_maxx - comp_minx + 9'd1) : 9'd0;
    wire [8:0]  bbh = (comp_maxy >= comp_miny) ? (comp_maxy - comp_miny + 9'd1) : 9'd0;
    wire [31:0] bbox_blocks = {23'd0,bbw} * {23'd0,bbh};
    wire [31:0] fill_lhs    = {16'd0,comp_cnt} << 8;
    wire [31:0] fill_rhs    = bbox_blocks * FILL_MIN;
    // A component touching the image boundary is normally the table, a hand,
    // or a shadow band.  Keeping it would let one background region displace
    // all real shapes in the top-4 list.
    wire comp_touch = (comp_minx == 9'd0) || (comp_miny == 9'd0) ||
                      (comp_maxx >= (BLK_W-1)) || (comp_maxy >= (BLK_H-1));

    // Do not discard a target merely because it overlaps one edge.  Reject the
    // border region only when it is large in BOTH axes (table / arm / shadow).
    wire border_soft_ok = !comp_touch ||
                          (bbw <= (BLK_W * 3 / 4)) ||
                          (bbh <= (BLK_H * 3 / 4));

    wire cand_base_ok = (comp_cnt >= MIN_AREA) &&
                        (bbw >= MIN_BBOX) && (bbh >= MIN_BBOX) &&
                        (comp_minx <= comp_maxx) && (comp_miny <= comp_maxy) &&
                        (bbox_blocks != 0) && (fill_lhs >= fill_rhs);
    wire cand_size_ok = (bbw <= (MAX_BBOX_W/4)) && (bbh <= (MAX_BBOX_H/4));
    wire cand_strict_ok = cand_base_ok && cand_size_ok && border_soft_ok;
    wire cand_fallback_ok = cand_base_ok && (!cand_size_ok || !border_soft_ok);
    wire cand_ultra_ok = (comp_cnt >= 16'd4) && (bbw >= 9'd2) && (bbh >= 9'd2) &&
                         (comp_minx <= comp_maxx) && (comp_miny <= comp_maxy) &&
                         (bbox_blocks != 0) && (fill_lhs >= bbox_blocks);

    integer jj;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_state <= C_IDLE;
            ccl_pending <= 1'b0;
            fb_valid <= 1'b0;
            fb_cnt <= 16'd0;
            fb_minx <= 9'd511; fb_maxx <= 9'd0;
            fb_miny <= 9'd511; fb_maxy <= 9'd0;
            fb_sx <= 27'd0; fb_sy <= 27'd0;
            fb2_valid <= 1'b0;
            fb2_cnt <= 16'd0;
            fb2_minx <= 9'd511; fb2_maxx <= 9'd0;
            fb2_miny <= 9'd511; fb2_maxy <= 9'd0;
            fb2_sx <= 27'd0; fb2_sy <= 27'd0;
            scan_idx <= {ADDR_W{1'b0}};
            q_head <= {ADDR_W{1'b0}}; q_tail <= {ADDR_W{1'b0}};
            visited <= {NCELL{1'b0}};
            comp_cnt <= 16'd0; comp_sx <= 27'd0; comp_sy <= 27'd0;
            comp_minx <= 9'd511; comp_maxx <= 9'd0;
            comp_miny <= 9'd511; comp_maxy <= 9'd0;
            cur_minx <= 9'd511; cur_maxx <= 9'd0;
            cur_miny <= 9'd511; cur_maxy <= 9'd0;
            o_num <= 3'd0; o_valid <= 4'd0; o_done <= 1'b0;
            rd_addr <= {ADDR_W{1'b0}};
            for (jj = 0; jj < 4; jj = jj + 1) begin
                c_cnt[jj] <= 16'd0; c_minx[jj] <= 9'd511; c_maxx[jj] <= 9'd0;
                c_miny[jj] <= 9'd511; c_maxy[jj] <= 9'd0;
                c_sx[jj] <= 27'd0; c_sy[jj] <= 27'd0;
            end
        end else begin
            o_done <= 1'b0;
            if (vs_rise) ccl_pending <= 1'b1;

            case (c_state)
            C_IDLE: begin
                if (ccl_pending) begin
                    ccl_pending <= 1'b0;
                    scan_idx <= {ADDR_W{1'b0}};
                    q_head <= {ADDR_W{1'b0}}; q_tail <= {ADDR_W{1'b0}};
                    visited <= {NCELL{1'b0}};
                    for (jj = 0; jj < 4; jj = jj + 1) begin
                        c_cnt[jj] <= 16'd0; c_minx[jj] <= 9'd511; c_maxx[jj] <= 9'd0;
                        c_miny[jj] <= 9'd511; c_maxy[jj] <= 9'd0;
                        c_sx[jj] <= 27'd0; c_sy[jj] <= 27'd0;
                    end
                    fb_valid <= 1'b0;
                    fb_cnt <= 16'd0;
                    fb_minx <= 9'd511; fb_maxx <= 9'd0;
                    fb_miny <= 9'd511; fb_maxy <= 9'd0;
                    fb_sx <= 27'd0; fb_sy <= 27'd0;
                    fb2_valid <= 1'b0;
                    fb2_cnt <= 16'd0;
                    fb2_minx <= 9'd511; fb2_maxx <= 9'd0;
                    fb2_miny <= 9'd511; fb2_maxy <= 9'd0;
                    fb2_sx <= 27'd0; fb2_sy <= 27'd0;
                    c_state <= C_SCAN_RD;
                end
            end

            C_SCAN_RD: begin
                if (scan_idx >= NCELL) begin
                    c_state <= C_DONE;
                end else begin
                    rd_addr <= scan_idx;
                    c_state <= C_SCAN_WAIT;
                end
            end

            C_SCAN_WAIT: c_state <= C_SCAN_CHK;

            C_SCAN_CHK: begin
                if ((rd_cnt >= CELL_SEED_MIN) && !visited[scan_idx]) begin
                    visited[scan_idx] <= 1'b1;
                    q_mem[0] <= scan_idx;
                    q_head <= {ADDR_W{1'b0}};
                    q_tail <= {{(ADDR_W-1){1'b0}},1'b1};
                    comp_cnt <= 16'd0; comp_sx <= 27'd0; comp_sy <= 27'd0;
                    comp_minx <= 9'd511; comp_maxx <= 9'd0;
                    comp_miny <= 9'd511; comp_maxy <= 9'd0;
                    c_state <= C_POP;
                end else begin
                    scan_idx <= scan_idx + 1'b1;
                    c_state <= C_SCAN_RD;
                end
            end

            C_POP: begin
                if (q_head == q_tail) begin
                    c_state <= C_INSERT;
                end else begin
                    cur_cell <= q_mem[q_head];
                    q_head   <= q_head + 1'b1;
                    rd_addr  <= q_mem[q_head];
                    c_state  <= C_POP_WAIT1;
                end
            end

            C_POP_WAIT1: c_state <= C_POP_WAIT;

            C_POP_WAIT: begin
                comp_cnt <= comp_cnt + {4'd0, rd_cnt};
                comp_sx  <= comp_sx + {7'd0, rd_sx};
                comp_sy  <= comp_sy + {8'd0, rd_sy};
                if (rd_minx < comp_minx) comp_minx <= rd_minx;
                if (rd_maxx > comp_maxx) comp_maxx <= rd_maxx;
                if (rd_miny < comp_miny) comp_miny <= rd_miny;
                if (rd_maxy > comp_maxy) comp_maxy <= rd_maxy;
                cur_minx <= rd_minx; cur_maxx <= rd_maxx;
                cur_miny <= rd_miny; cur_maxy <= rd_maxy;
                nb_idx   <= 3'd0;
                c_state  <= C_NB;
            end

            C_NB: begin
                if (nb_geom_ok) begin
                    rd_addr <= nb_cell;
                    c_state <= C_NB_WAIT1;
                end else if (nb_idx == 3'd7) begin
                    c_state <= C_POP;
                end else begin
                    nb_idx  <= nb_idx + 3'd1;
                    c_state <= C_NB;
                end
            end

            C_NB_WAIT1: c_state <= C_NB_WAIT;

            C_NB_WAIT: begin
                if (nb_geom_ok && (rd_cnt >= CELL_MERGE_MIN) &&
                    !visited[nb_cell] && bbox_overlap) begin
                    visited[nb_cell] <= 1'b1;
                    q_mem[q_tail]   <= nb_cell;
                    q_tail          <= q_tail + 1'b1;
                end
                if (nb_idx == 3'd7)
                    c_state <= C_POP;
                else begin
                    nb_idx  <= nb_idx + 3'd1;
                    c_state <= C_NB;
                end
            end

            C_INSERT: begin
                if (cand_strict_ok) begin
                    insert_candidate(comp_cnt, comp_minx, comp_maxx,
                                     comp_miny, comp_maxy, comp_sx, comp_sy);
                end else if (cand_fallback_ok && (comp_cnt > fb_cnt)) begin
                    fb_valid <= 1'b1;
                    fb_cnt   <= comp_cnt;
                    fb_minx  <= comp_minx; fb_maxx <= comp_maxx;
                    fb_miny  <= comp_miny; fb_maxy <= comp_maxy;
                    fb_sx    <= comp_sx;   fb_sy   <= comp_sy;
                end else if (cand_ultra_ok && (comp_cnt > fb2_cnt)) begin
                    fb2_valid <= 1'b1;
                    fb2_cnt   <= comp_cnt;
                    fb2_minx  <= comp_minx; fb2_maxx <= comp_maxx;
                    fb2_miny  <= comp_miny; fb2_maxy <= comp_maxy;
                    fb2_sx    <= comp_sx;   fb2_sy   <= comp_sy;
                end
                scan_idx <= scan_idx + 1'b1;
                c_state  <= C_SCAN_RD;
            end

            C_DONE: begin
                // If every strict component was rejected, expose the largest
                // otherwise-valid connected component instead of showing no
                // scan box at all.  Multi-target scenes never enter this path.
                if ((c_cnt[0] == 0) && fb_valid) begin
                    c_cnt[0]  <= fb_cnt;
                    c_minx[0] <= fb_minx; c_maxx[0] <= fb_maxx;
                    c_miny[0] <= fb_miny; c_maxy[0] <= fb_maxy;
                    c_sx[0]   <= fb_sx;   c_sy[0]   <= fb_sy;
                    o_num     <= 3'd1;
                    o_valid   <= 4'b0001;
                end else if ((c_cnt[0] == 0) && fb2_valid) begin
                    c_cnt[0]  <= fb2_cnt;
                    c_minx[0] <= fb2_minx; c_maxx[0] <= fb2_maxx;
                    c_miny[0] <= fb2_miny; c_maxy[0] <= fb2_maxy;
                    c_sx[0]   <= fb2_sx;   c_sy[0]   <= fb2_sy;
                    o_num     <= 3'd1;
                    o_valid   <= 4'b0001;
                end else begin
                    o_num   <= {2'd0,(c_cnt[0] != 0)} + {2'd0,(c_cnt[1] != 0)} +
                               {2'd0,(c_cnt[2] != 0)} + {2'd0,(c_cnt[3] != 0)};
                    o_valid <= {(c_cnt[3] != 0),(c_cnt[2] != 0),
                                (c_cnt[1] != 0),(c_cnt[0] != 0)};
                end
                o_done  <= 1'b1;
                c_state <= C_IDLE;
            end
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Neighbour coordinates for 8-connectivity.
    //--------------------------------------------------------------------------
    reg [COL_W-1:0] cur_cx;
    reg [ROW_W-1:0] cur_cy;
    reg signed [POS_W-1:0] nb_x, nb_y;
    always @* begin
        cur_cx = cur_cell[COL_W-1:0];
        cur_cy = cur_cell[ADDR_W-1:COL_W];
        nb_x   = $signed({1'b0,cur_cx});
        nb_y   = $signed({1'b0,cur_cy});
        case (nb_idx)
        3'd0: begin nb_x = $signed({1'b0,cur_cx}) - 1'sd1; nb_y = $signed({1'b0,cur_cy}) - 1'sd1; end
        3'd1: begin nb_x = $signed({1'b0,cur_cx});          nb_y = $signed({1'b0,cur_cy}) - 1'sd1; end
        3'd2: begin nb_x = $signed({1'b0,cur_cx}) + 1'sd1; nb_y = $signed({1'b0,cur_cy}) - 1'sd1; end
        3'd3: begin nb_x = $signed({1'b0,cur_cx}) - 1'sd1; nb_y = $signed({1'b0,cur_cy}); end
        3'd4: begin nb_x = $signed({1'b0,cur_cx}) + 1'sd1; nb_y = $signed({1'b0,cur_cy}); end
        3'd5: begin nb_x = $signed({1'b0,cur_cx}) - 1'sd1; nb_y = $signed({1'b0,cur_cy}) + 1'sd1; end
        3'd6: begin nb_x = $signed({1'b0,cur_cx});          nb_y = $signed({1'b0,cur_cy}) + 1'sd1; end
        3'd7: begin nb_x = $signed({1'b0,cur_cx}) + 1'sd1; nb_y = $signed({1'b0,cur_cy}) + 1'sd1; end
        default: begin nb_x = $signed({1'b0,cur_cx}); nb_y = $signed({1'b0,cur_cy}); end
        endcase
        nb_geom_ok = (nb_x >= 0) && (nb_x < GRID_X) &&
                     (nb_y >= 0) && (nb_y < GRID_Y);
        nb_cell = {nb_y[ROW_W-1:0], nb_x[COL_W-1:0]};
    end

    //--------------------------------------------------------------------------
    // Pixel-domain packing for shape_polar.  Keep the bbox TIGHT: the polar
    // classifier uses bbox area to compute fill ratio, so a display margin here
    // would bias small squares towards the circle branch.  shape_osd must add
    // its own visual margin when drawing the box.
    //--------------------------------------------------------------------------
    wire [43:0]  c_bx0, c_bx1, c_by0, c_by1;
    wire [107:0] c_sx_px, c_sy_px;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : G_PACK
            wire [11:0] x0p = {3'd0, c_minx[gi]} << 2;
            wire [11:0] x1p = ({3'd0, c_maxx[gi]} << 2) + 12'd3;
            wire [11:0] y0p = {3'd0, c_miny[gi]} << 2;
            wire [11:0] y1p = ({3'd0, c_maxy[gi]} << 2) + 12'd3;
            assign c_bx0[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 : x0p[10:0];
            assign c_bx1[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 :
                               (x1p > 12'd1919) ? 11'd1919 : x1p[10:0];
            assign c_by0[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 : y0p[10:0];
            assign c_by1[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 :
                               (y1p > 12'd1079) ? 11'd1079 : y1p[10:0];
            // Pixel centre of a 4x4 block is 4*block + 1.5.  The old
            // 4*sum+2*count biased the centroid by +0.5 px; keep the exact
            // half-pixel term in integer arithmetic.
            assign c_sx_px[27*gi +: 27] = {1'b0, c_sx[gi], 2'b00} +
                                          {11'd0, c_cnt[gi]} +
                                          {12'd0, c_cnt[gi][15:1]};
            assign c_sy_px[27*gi +: 27] = {1'b0, c_sy[gi], 2'b00} +
                                          {11'd0, c_cnt[gi]} +
                                          {12'd0, c_cnt[gi][15:1]};
        end
    endgenerate

    assign o_bx0 = c_bx0;
    assign o_bx1 = c_bx1;
    assign o_by0 = c_by0;
    assign o_by1 = c_by1;
    assign o_sx  = c_sx_px;
    assign o_sy  = c_sy_px;
    assign o_area= {c_cnt[3], c_cnt[2], c_cnt[1], c_cnt[0]};

endmodule
