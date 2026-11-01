//==============================================================================
// shape_multi_sched.v -- frame-end scheduler for up to four candidates
//
//  shape_grid_multi_v2 emits a tight bbox / moment centroid / block count for
//  each connected component.  This block reuses ONE shape_polar engine to
//  classify the candidates one after another, instead of duplicating the block
//  map and 128-ray datapath four times.  That is the resource-efficient choice
//  for the Ti60F225, where RAM is the limiting resource.
//
//  The scheduler snapshots the grid result at i_grid_done, because the grid
//  RAM is being overwritten by the next frame.  A timeout keeps the FSM live if
//  a malformed candidate never produces o_upd.
//==============================================================================
module shape_multi_sched #(
    parameter integer MAX_CAND = 4,
    parameter integer TIMEOUT  = 24000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_grid_done,
    input  wire [2:0]  i_num,
    input  wire [3:0]  i_valid,
    input  wire [63:0] i_area,
    input  wire [107:0] i_sx,
    input  wire [107:0] i_sy,
    input  wire [43:0] i_bx0,
    input  wire [43:0] i_bx1,
    input  wire [43:0] i_by0,
    input  wire [43:0] i_by1,

    input  wire        i_pol_upd,
    input  wire [4:0]  i_pol_cls,

    output reg         o_start,
    output reg  [1:0]  o_sel,
    output reg  [2:0]  o_num,
    output reg  [3:0]  o_valid,
    output reg  [19:0] o_cls,
    output reg  [63:0] o_area,
    output reg  [107:0] o_sx,
    output reg  [107:0] o_sy,
    output reg  [43:0] o_bx0,
    output reg  [43:0] o_bx1,
    output reg  [43:0] o_by0,
    output reg  [43:0] o_by1,

    // selected candidate presented to shape_polar
    output reg  [15:0] o_sel_area,
    output reg  [26:0] o_sel_sx,
    output reg  [26:0] o_sel_sy,
    output reg  [10:0] o_sel_bx0,
    output reg  [10:0] o_sel_bx1,
    output reg  [10:0] o_sel_by0,
    output reg  [10:0] o_sel_by1,

    output reg         o_done
);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_WAIT  = 2'd2;
    localparam [1:0] S_NEXT  = 2'd3;

    reg [15:0] s_area [0:3];
    reg [26:0] s_sx   [0:3];
    reg [26:0] s_sy   [0:3];
    reg [10:0] s_bx0  [0:3];
    reg [10:0] s_bx1  [0:3];
    reg [10:0] s_by0  [0:3];
    reg [10:0] s_by1  [0:3];

    reg [1:0] state;
    reg [19:0] tmo;
    integer k;

    reg       first_found;
    reg [1:0] first_sel;
    reg       next_found;
    reg [1:0] next_sel;

    // Find lowest-numbered valid candidate.  Loop descending so index 0 wins.
    always @* begin
        first_found = 1'b0;
        first_sel   = 2'd0;
        for (k = 3; k >= 0; k = k - 1) begin
            if (i_valid[k]) begin
                first_found = 1'b1;
                first_sel   = k[1:0];
            end
        end
    end

    // First valid candidate strictly after o_sel.
    always @* begin
        next_found = 1'b0;
        next_sel   = 2'd0;
        for (k = 3; k >= 0; k = k - 1) begin
            if (o_valid[k] && (k > o_sel)) begin
                next_found = 1'b1;
                next_sel   = k[1:0];
            end
        end
    end

    // Candidate mux.  The loop reads every entry so simulation sensitivity is
    // complete; synthesis builds a 4-way mux.
    always @* begin
        o_sel_area = s_area[0];
        o_sel_sx   = s_sx[0];
        o_sel_sy   = s_sy[0];
        o_sel_bx0  = s_bx0[0];
        o_sel_bx1  = s_bx1[0];
        o_sel_by0  = s_by0[0];
        o_sel_by1  = s_by1[0];
        for (k = 0; k < 4; k = k + 1) begin
            if (o_sel == k) begin
                o_sel_area = s_area[k];
                o_sel_sx   = s_sx[k];
                o_sel_sy   = s_sy[k];
                o_sel_bx0  = s_bx0[k];
                o_sel_bx1  = s_bx1[k];
                o_sel_by0  = s_by0[k];
                o_sel_by1  = s_by1[k];
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            o_start <= 1'b0;
            o_sel   <= 2'd0;
            o_num   <= 3'd0;
            o_valid <= 4'd0;
            o_cls   <= 20'd0;
            o_area  <= 64'd0;
            o_sx    <= 108'd0;
            o_sy    <= 108'd0;
            o_bx0   <= 44'd0;
            o_bx1   <= 44'd0;
            o_by0   <= 44'd0;
            o_by1   <= 44'd0;
            o_done  <= 1'b0;
            tmo     <= 20'd0;
            for (k = 0; k < 4; k = k + 1) begin
                s_area[k] <= 16'd0; s_sx[k] <= 27'd0; s_sy[k] <= 27'd0;
                s_bx0[k] <= 11'd0; s_bx1[k] <= 11'd0;
                s_by0[k] <= 11'd0; s_by1[k] <= 11'd0;
            end
        end else begin
            o_start <= 1'b0;
            o_done  <= 1'b0;
            case (state)
            S_IDLE: begin
                if (i_grid_done) begin
                    o_num   <= i_num;
                    o_valid <= i_valid;
                    o_cls   <= 20'd0;
                    o_area  <= i_area;
                    o_sx    <= i_sx;
                    o_sy    <= i_sy;
                    o_bx0   <= i_bx0;
                    o_bx1   <= i_bx1;
                    o_by0   <= i_by0;
                    o_by1   <= i_by1;
                    for (k = 0; k < 4; k = k + 1) begin
                        s_area[k] <= i_area[16*k +: 16];
                        s_sx[k]   <= i_sx[27*k +: 27];
                        s_sy[k]   <= i_sy[27*k +: 27];
                        s_bx0[k]  <= i_bx0[11*k +: 11];
                        s_bx1[k]  <= i_bx1[11*k +: 11];
                        s_by0[k]  <= i_by0[11*k +: 11];
                        s_by1[k]  <= i_by1[11*k +: 11];
                    end
                    if (first_found) begin
                        o_sel <= first_sel;
                        tmo   <= 20'd0;
                        state <= S_START;
                    end else begin
                        state <= S_NEXT;
                    end
                end
            end

            S_START: begin
                o_start <= 1'b1;
                tmo     <= 20'd0;
                state   <= S_WAIT;
            end

            S_WAIT: begin
                if (i_pol_upd) begin
                    case (o_sel)
                    2'd0: o_cls[4:0]   <= i_pol_cls;
                    2'd1: o_cls[9:5]   <= i_pol_cls;
                    2'd2: o_cls[14:10] <= i_pol_cls;
                    default: o_cls[19:15] <= i_pol_cls;
                    endcase
                    state <= S_NEXT;
                end else if (tmo == (TIMEOUT-1)) begin
                    // Keep the box, report unknown class.
                    case (o_sel)
                    2'd0: o_cls[4:0]   <= 5'd0;
                    2'd1: o_cls[9:5]   <= 5'd0;
                    2'd2: o_cls[14:10] <= 5'd0;
                    default: o_cls[19:15] <= 5'd0;
                    endcase
                    state <= S_NEXT;
                end else begin
                    tmo <= tmo + 20'd1;
                end
            end

            S_NEXT: begin
                if (next_found) begin
                    o_sel <= next_sel;
                    tmo   <= 20'd0;
                    state <= S_START;
                end else begin
                    o_done <= 1'b1;
                    state  <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
