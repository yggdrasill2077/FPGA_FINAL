//////////////////////////////////////////////////////////////////////////////
// Active-low key debounce and single-cycle press detector.
//
// The input is synchronized to i_clk, then it must remain stable for
// DEBOUNCE_MS before the new state is accepted. o_press is asserted for one
// clock when the debounced key changes from released (1) to pressed (0).
//////////////////////////////////////////////////////////////////////////////

module key_debounce #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire i_clk,
    input  wire i_rst_n,
    input  wire i_key_n,
    output reg  o_press
);

    function integer clogb2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clogb2 = 0; v > 0; clogb2 = clogb2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam integer DEBOUNCE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_WIDTH = clogb2(DEBOUNCE_CYCLES);

    reg [1:0] sync;
    reg       key_stable;
    reg [CNT_WIDTH-1:0] hold_cnt;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            sync       <= 2'b11;
            key_stable <= 1'b1;
            hold_cnt   <= {CNT_WIDTH{1'b0}};
            o_press    <= 1'b0;
        end else begin
            sync    <= {sync[0], i_key_n};
            o_press <= 1'b0;

            if (sync[1] == key_stable) begin
                hold_cnt <= {CNT_WIDTH{1'b0}};
            end else if (hold_cnt == (DEBOUNCE_CYCLES - 1)) begin
                hold_cnt   <= {CNT_WIDTH{1'b0}};
                key_stable <= sync[1];
                o_press    <= ~sync[1];
            end else begin
                hold_cnt <= hold_cnt + 1'b1;
            end
        end
    end

endmodule
