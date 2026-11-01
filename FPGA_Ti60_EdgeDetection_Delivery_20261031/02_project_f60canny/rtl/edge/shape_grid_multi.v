//==============================================================================
// shape_grid_multi.v -- multi-object candidate extractor (research prototype)
//
//  Method:
//    1) 4x4 block stream: a block is foreground if ANY pixel in it is below TY.
//    2) 16x9 grid (120x120 px cells): per-cell count / sumx / sumy / tight bbox.
//    3) Frame-end BFS connected components on the cell grid. Adjacent cells are
//       merged only when their tight bboxes overlap after a 1-block dilation.
//    4) Up to 4 candidates are emitted, sorted by block count. Candidate bbox is
//       the tight foreground bbox expanded by 4 px; sumx/sumy/area are in the
//       same units expected by shape_polar (pixel coordinates / block count).
//
//  Why run-length / component merging instead of "cell touched -> 1":
//    - a single noisy pixel cannot create a candidate (CELL_SEED_MIN);
//    - one object spanning several cells becomes one component, not many;
//    - two nearby objects in adjacent cells stay separate unless their tight
//      bboxes actually overlap.
//
//  Resource-oriented choices:
//    - no full-frame bitmap; only 16 live column accumulators + 144 cell words;
//    - cell RAM is 144 x 87 bits (~2 RAM10 blocks);
//    - BFS queue/visited are 144 entries, no union-find table;
//    - all heavy work happens after the active frame, outside the pixel path.
//==============================================================================
module shape_grid_multi #(
    parameter integer H_PAIRS        = 960,   // pixel pairs per line (1920/2)
    parameter integer V_LINES        = 1080,
    parameter integer GRID_X         = 16,    // 16 columns -> 120 px cells
    parameter integer GRID_Y         = 9,     // 9 rows    -> 120 px cells
    parameter integer CELL_SEED_MIN  = 8,     // blocks (16 px each) to seed a cell
    parameter integer CELL_MERGE_MIN = 2,     // blocks to join an existing component
    parameter integer MIN_AREA       = 32,    // blocks per candidate (512 px)
    parameter integer MIN_BBOX       = 8,     // blocks per bbox side (32 px)
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
    output wire [43:0] o_bx0,     // 4 x 11-bit
    output wire [43:0] o_bx1,
    output wire [43:0] o_by0,
    output wire [43:0] o_by1,
    output wire [107:0] o_sx,     // 4 x 27-bit
    output wire [107:0] o_sy,
    output wire [63:0] o_area,    // 4 x 16-bit
    output reg         o_done
);

    localparam integer NCELL  = GRID_X * GRID_Y;
    localparam integer CELL_W = 30;   // 120 px / 4 px per block
    localparam integer CELL_H = 30;   // 120 px / 4 px per block
    localparam integer REC_W  = 12 + 20 + 19 + 9 + 9 + 9 + 9; // 87

    //--------------------------------------------------------------------------
    // Pixel / block counters
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
            if (i_vs) begin
                row <= 12'd0;
            end else if (de_d && !i_de) begin
                row <= row + 12'd1;
            end
            if (!i_de) begin
                pcol <= 10'd0;
            end else if (pcol == (H_PAIRS-1)) begin
                pcol <= 10'd0;
            end else begin
                pcol <= pcol + 10'd1;
            end
        end
    end

    wire [8:0] blk_x = pcol[9:1];       // 0..479
    wire [8:0] blk_y = row[10:2];       // 0..269
    wire       blk_last = i_de && pcol[0] && (row[1:0] == 2'b11);
    wire       line_last = blk_last && (pcol == (H_PAIRS-1));

    wire fg_pair = (i_g0 < i_ty) || (i_g1 < i_ty);
    reg  blk_fg;
    wire blk_fg_now = blk_fg | fg_pair;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blk_fg <= 1'b0;
        else if (!i_de) blk_fg <= 1'b0;
        else if (blk_last) blk_fg <= 1'b0;
        else blk_fg <= blk_fg_now;
    end

    //--------------------------------------------------------------------------
    // 16 live column accumulators.  A 30-block-tall cell row is accumulated in
    // parallel columns; at the end of the cell row all 16 words are written to
    // cell_ram.  This avoids 144 parallel adders and avoids a full block map.
    //--------------------------------------------------------------------------
    reg [11:0] acc_cnt  [0:GRID_X-1];
    reg [19:0] acc_sx   [0:GRID_X-1];
    reg [18:0] acc_sy   [0:GRID_X-1];
    reg [8:0]  acc_minx [0:GRID_X-1];
    reg [8:0]  acc_maxx [0:GRID_X-1];
    reg [8:0]  acc_miny [0:GRID_X-1];
    reg [8:0]  acc_maxy [0:GRID_X-1];

    reg [4:0] col_in_cell;   // 0..29
    reg [3:0] cell_col;      // 0..15
    reg [4:0] row_in_cell;   // 0..29
    reg [3:0] cell_row;      // 0..8

    reg [REC_W-1:0] cell_ram [0:NCELL-1];

    function [REC_W-1:0] pack_acc;
        input [3:0] idx;
        begin
            pack_acc = {acc_cnt[idx], acc_sx[idx], acc_sy[idx],
                        acc_minx[idx], acc_maxx[idx], acc_miny[idx], acc_maxy[idx]};
        end
    endfunction

    // Cell-row write state
    localparam P_RUN = 1'b0;
    localparam P_WR  = 1'b1;
    reg        p_state;
    reg [3:0]  wr_idx;

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_in_cell <= 5'd0;
            cell_col    <= 4'd0;
            row_in_cell <= 5'd0;
            cell_row    <= 4'd0;
            p_state     <= P_RUN;
            wr_idx      <= 4'd0;
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
            col_in_cell <= 5'd0;
            cell_col    <= 4'd0;
            row_in_cell <= 5'd0;
            cell_row    <= 4'd0;
            p_state     <= P_RUN;
            wr_idx      <= 4'd0;
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
            cell_ram[{cell_row, 4'h0} + {4'h0, wr_idx}] <= pack_acc(wr_idx);
            if (wr_idx == (GRID_X-1)) begin
                wr_idx <= 4'd0;
                p_state <= P_RUN;
                cell_col <= 4'd0;
                col_in_cell <= 5'd0;
                row_in_cell <= 5'd0;
                cell_row <= cell_row + 4'd1;
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
                wr_idx <= wr_idx + 4'd1;
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

            if (col_in_cell == (CELL_W-1)) begin
                if (cell_col == (GRID_X-1)) begin
                    // last cell of this block row
                    if (line_last) begin
                        if (row_in_cell == (CELL_H-1)) begin
                            p_state <= P_WR;   // write all 16 cells of this cell row
                        end else begin
                            row_in_cell <= row_in_cell + 5'd1;
                            cell_col    <= 4'd0;
                            col_in_cell <= 5'd0;
                        end
                    end else begin
                        cell_col    <= 4'd0;
                        col_in_cell <= 5'd0;
                    end
                end else begin
                    cell_col    <= cell_col + 4'd1;
                    col_in_cell <= 5'd0;
                end
            end else begin
                col_in_cell <= col_in_cell + 5'd1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Cell RAM read port (one-cycle latency)
    //--------------------------------------------------------------------------
    reg [7:0]        rd_addr;
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
    // Frame-end BFS connected components on the 16x9 cell grid
    //--------------------------------------------------------------------------
    reg vs_d;
    wire vs_rise = i_vs & ~vs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= i_vs;
    end

    localparam C_IDLE   = 4'd0;
    localparam C_SCAN_RD= 4'd1;
    localparam C_SCAN_WAIT=4'd2;
    localparam C_SCAN_CHK=4'd3;
    localparam C_POP    = 4'd4;
    localparam C_POP_WAIT1=4'd5;
    localparam C_POP_WAIT=4'd6;
    localparam C_NB     = 4'd7;
    localparam C_NB_WAIT1= 4'd8;
    localparam C_NB_WAIT= 4'd9;
    localparam C_INSERT = 4'd10;
    localparam C_DONE   = 4'd11;

    reg [3:0]        c_state;
    reg              ccl_pending;
    reg [7:0]        scan_idx;
    reg [7:0]        q_mem [0:NCELL-1];
    reg [7:0]        q_head, q_tail;
    reg [NCELL-1:0]  visited;

    reg [7:0]  cur_cell;
    reg [2:0]  nb_idx;
    reg [7:0]  nb_cell;
    reg        nb_geom_ok;

    reg [15:0] comp_cnt;
    reg [23:0] comp_sx, comp_sy;
    reg [8:0]  comp_minx, comp_maxx, comp_miny, comp_maxy;
    reg [8:0]  cur_minx, cur_maxx, cur_miny, cur_maxy;

    // Top-4 candidate table, sorted by block count
    reg [15:0] c_cnt  [0:3];
    reg [8:0]  c_minx [0:3];
    reg [8:0]  c_maxx [0:3];
    reg [8:0]  c_miny [0:3];
    reg [8:0]  c_maxy [0:3];
    reg [23:0] c_sx   [0:3];
    reg [23:0] c_sy   [0:3];
    reg [3:0]  c_valid;

    wire [9:0] cur_x0 = (cur_minx > 9'd0) ? {1'b0,cur_minx} - 10'd1 : 10'd0;
    wire [9:0] cur_x1 = (cur_maxx < 9'd479) ? {1'b0,cur_maxx} + 10'd1 : 10'd479;
    wire [9:0] cur_y0 = (cur_miny > 9'd0) ? {1'b0,cur_miny} - 10'd1 : 10'd0;
    wire [9:0] cur_y1 = (cur_maxy < 9'd269) ? {1'b0,cur_maxy} + 10'd1 : 10'd269;

    wire bbox_overlap = ({1'b0,rd_minx} <= cur_x1) && ({1'b0,rd_maxx} >= cur_x0) &&
                        ({1'b0,rd_miny} <= cur_y1) && ({1'b0,rd_maxy} >= cur_y0);

    // Insert one candidate into the sorted top-4 table.
    task insert_candidate;
        input [15:0] a;
        input [8:0]  x0, x1, y0, y1;
        input [23:0] sx, sy;
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

    integer jj;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_state <= C_IDLE;
            ccl_pending <= 1'b0;
            scan_idx <= 8'd0;
            q_head <= 8'd0; q_tail <= 8'd0;
            visited <= {NCELL{1'b0}};
            comp_cnt <= 16'd0; comp_sx <= 24'd0; comp_sy <= 24'd0;
            comp_minx <= 9'd511; comp_maxx <= 9'd0; comp_miny <= 9'd511; comp_maxy <= 9'd0;
            cur_minx <= 9'd511; cur_maxx <= 9'd0; cur_miny <= 9'd511; cur_maxy <= 9'd0;
            c_valid <= 4'd0;
            for (jj = 0; jj < 4; jj = jj + 1) begin
                c_cnt[jj] <= 16'd0; c_minx[jj] <= 9'd511; c_maxx[jj] <= 9'd0;
                c_miny[jj] <= 9'd511; c_maxy[jj] <= 9'd0; c_sx[jj] <= 24'd0; c_sy[jj] <= 24'd0;
            end
            o_num <= 3'd0; o_valid <= 4'd0; o_done <= 1'b0;
            rd_addr <= 8'd0;
        end else begin
            o_done <= 1'b0;
            if (vs_rise) ccl_pending <= 1'b1;

            case (c_state)
            C_IDLE: begin
                if (ccl_pending) begin
                    ccl_pending <= 1'b0;
                    scan_idx <= 8'd0;
                    q_head <= 8'd0; q_tail <= 8'd0;
                    visited <= {NCELL{1'b0}};
                    c_valid <= 4'd0;
                    for (jj = 0; jj < 4; jj = jj + 1) begin
                        c_cnt[jj] <= 16'd0; c_minx[jj] <= 9'd511; c_maxx[jj] <= 9'd0;
                        c_miny[jj] <= 9'd511; c_maxy[jj] <= 9'd0; c_sx[jj] <= 24'd0; c_sy[jj] <= 24'd0;
                    end
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

            C_SCAN_WAIT: begin
                c_state <= C_SCAN_CHK;
            end

            C_SCAN_CHK: begin
                if ((rd_cnt >= CELL_SEED_MIN) && !visited[scan_idx[7:0]]) begin
                    visited[scan_idx[7:0]] <= 1'b1;
                    q_mem[0] <= scan_idx;
                    q_head <= 8'd0;
                    q_tail <= 8'd1;
                    comp_cnt <= 16'd0; comp_sx <= 24'd0; comp_sy <= 24'd0;
                    comp_minx <= 9'd511; comp_maxx <= 9'd0;
                    comp_miny <= 9'd511; comp_maxy <= 9'd0;
                    c_state <= C_POP;
                end else begin
                    scan_idx <= scan_idx + 8'd1;
                    c_state <= C_SCAN_RD;
                end
            end

            C_POP: begin
                if (q_head == q_tail) begin
                    c_state <= C_INSERT;
                end else begin
                    cur_cell <= q_mem[q_head[7:0]];
                    q_head <= q_head + 8'd1;
                    rd_addr <= q_mem[q_head[7:0]];
                    c_state <= C_POP_WAIT1;
                end
            end

            C_POP_WAIT1: begin
                c_state <= C_POP_WAIT;
            end

            C_POP_WAIT: begin
                comp_cnt <= comp_cnt + {4'd0, rd_cnt};
                comp_sx  <= comp_sx + {4'd0, rd_sx};
                comp_sy  <= comp_sy + {5'd0, rd_sy};
                if (rd_minx < comp_minx) comp_minx <= rd_minx;
                if (rd_maxx > comp_maxx) comp_maxx <= rd_maxx;
                if (rd_miny < comp_miny) comp_miny <= rd_miny;
                if (rd_maxy > comp_maxy) comp_maxy <= rd_maxy;
                cur_minx <= rd_minx; cur_maxx <= rd_maxx;
                cur_miny <= rd_miny; cur_maxy <= rd_maxy;
                nb_idx <= 3'd0;
                c_state <= C_NB;
            end

            C_NB: begin
                if (nb_geom_ok) begin
                    rd_addr <= nb_cell;
                    c_state <= C_NB_WAIT1;
                end else if (nb_idx == 3'd7) begin
                    c_state <= C_POP;
                end else begin
                    nb_idx <= nb_idx + 3'd1;
                    c_state <= C_NB;
                end
            end

            C_NB_WAIT1: begin
                c_state <= C_NB_WAIT;
            end

            C_NB_WAIT: begin
                if (nb_geom_ok && (rd_cnt >= CELL_MERGE_MIN) && !visited[nb_cell[7:0]] && bbox_overlap) begin
                    visited[nb_cell[7:0]] <= 1'b1;
                    q_mem[q_tail[7:0]] <= nb_cell;
                    q_tail <= q_tail + 8'd1;
                end
                if (nb_idx == 3'd7) begin
                    c_state <= C_POP;
                end else begin
                    nb_idx <= nb_idx + 3'd1;
                    c_state <= C_NB;
                end
            end

            C_INSERT: begin
                if ((comp_cnt >= MIN_AREA) &&
                    ((comp_maxx - comp_minx + 9'd1) >= MIN_BBOX) &&
                    ((comp_maxy - comp_miny + 9'd1) >= MIN_BBOX) &&
                    ((comp_maxx - comp_minx + 9'd1) <= MAX_BBOX_W/4) &&
                    ((comp_maxy - comp_miny + 9'd1) <= MAX_BBOX_H/4) &&
                    (comp_minx <= comp_maxx) && (comp_miny <= comp_maxy)) begin
                    insert_candidate(comp_cnt, comp_minx, comp_maxx, comp_miny, comp_maxy, comp_sx, comp_sy);
                end
                scan_idx <= scan_idx + 8'd1;
                c_state <= C_SCAN_RD;
            end

            C_DONE: begin
                o_num <= {2'd0,(c_cnt[0] != 0)} + {2'd0,(c_cnt[1] != 0)} +
                         {2'd0,(c_cnt[2] != 0)} + {2'd0,(c_cnt[3] != 0)};
                o_valid <= { (c_cnt[3] != 0), (c_cnt[2] != 0), (c_cnt[1] != 0), (c_cnt[0] != 0) };
                o_done <= 1'b1;
                c_state <= C_IDLE;
            end
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Neighbor geometry (combinational, uses cur_cell and nb_idx)
    //--------------------------------------------------------------------------
    reg [3:0] cur_cx, cur_cy;
    reg signed [4:0] nb_x, nb_y;
    always @* begin
        cur_cx = cur_cell[3:0];
        cur_cy = cur_cell[7:4];
        nb_x = {1'b0, cur_cx};
        nb_y = {1'b0, cur_cy};
        case (nb_idx)
        3'd0: begin nb_x = {1'b0,cur_cx} - 5'sd1; nb_y = {1'b0,cur_cy} - 5'sd1; end
        3'd1: begin nb_x = {1'b0,cur_cx};              nb_y = {1'b0,cur_cy} - 5'sd1; end
        3'd2: begin nb_x = {1'b0,cur_cx} + 5'sd1; nb_y = {1'b0,cur_cy} - 5'sd1; end
        3'd3: begin nb_x = {1'b0,cur_cx} - 5'sd1; nb_y = {1'b0,cur_cy}; end
        3'd4: begin nb_x = {1'b0,cur_cx} + 5'sd1; nb_y = {1'b0,cur_cy}; end
        3'd5: begin nb_x = {1'b0,cur_cx} - 5'sd1; nb_y = {1'b0,cur_cy} + 5'sd1; end
        3'd6: begin nb_x = {1'b0,cur_cx};              nb_y = {1'b0,cur_cy} + 5'sd1; end
        3'd7: begin nb_x = {1'b0,cur_cx} + 5'sd1; nb_y = {1'b0,cur_cy} + 5'sd1; end
        default: begin nb_x = {1'b0,cur_cx}; nb_y = {1'b0,cur_cy}; end
        endcase
        nb_geom_ok = (nb_x >= 0) && (nb_x < GRID_X) && (nb_y >= 0) && (nb_y < GRID_Y);
        nb_cell = {nb_y[3:0], nb_x[3:0]};
    end

    //--------------------------------------------------------------------------
    // Output packing: pixel bbox (4x expansion), sums in pixel units, area in
    // 4x4 blocks (shape_polar divides sum by area).
    //--------------------------------------------------------------------------
    wire [43:0]  c_bx0;
    wire [43:0]  c_bx1;
    wire [43:0]  c_by0;
    wire [43:0]  c_by1;
    wire [107:0] c_sx_px;
    wire [107:0] c_sy_px;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : G_PACK
            wire [11:0] x0p = {3'd0, c_minx[gi]} << 2;
            wire [11:0] x1p = ({3'd0, c_maxx[gi]} << 2) + 12'd3;
            wire [11:0] y0p = {3'd0, c_miny[gi]} << 2;
            wire [11:0] y1p = ({3'd0, c_maxy[gi]} << 2) + 12'd3;
            assign c_bx0[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 :
                               (x0p > 12'd4) ? (x0p[10:0] - 11'd4) : 11'd0;
            assign c_bx1[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 :
                               ((x1p + 12'd4) > 12'd1919) ? 11'd1919 : (x1p[10:0] + 11'd4);
            assign c_by0[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 :
                               (y0p > 12'd4) ? (y0p[10:0] - 11'd4) : 11'd0;
            assign c_by1[11*gi +: 11] = (c_cnt[gi] == 0) ? 11'd0 :
                               ((y1p + 12'd4) > 12'd1079) ? 11'd1079 : (y1p[10:0] + 11'd4);
            assign c_sx_px[27*gi +: 27] = {1'b0, c_sx[gi], 2'b00} + {10'd0, c_cnt[gi], 1'b0};
            assign c_sy_px[27*gi +: 27] = {1'b0, c_sy[gi], 2'b00} + {10'd0, c_cnt[gi], 1'b0};
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
