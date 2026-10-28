//============================================================================
// key_autorepeat —— 按键消抖 + 长按连发
//   按下立即输出一个单拍脉冲；按住超过 HOLD_MS 后，每 REPEAT_MS 再输出一个脉冲。
//   按键低有效（i_key_n = 0 表示按下）。
//============================================================================
module key_autorepeat #(
    parameter integer CLK_HZ      = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer HOLD_MS     = 400,
    parameter integer REPEAT_MS   = 80
)(
    input  wire i_clk,
    input  wire i_rst_n,
    input  wire i_key_n,
    output reg  o_press,
    output wire o_pressed        // 消抖后的稳定按下电平（1 = 按下）
);
    localparam integer DEB = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer HLD = (CLK_HZ / 1000) * HOLD_MS;
    localparam integer RPT = (CLK_HZ / 1000) * REPEAT_MS;

    reg [31:0] deb_cnt;
    reg        pressed;
    reg        pressed_d;
    reg [31:0] hold_cnt;
    reg [31:0] rpt_cnt;
    reg        repeating;

    // 先声明后使用（iverilog 对 "assign 里的前向引用" 会报 Unable to bind）
    assign o_pressed = pressed;

    wire key_raw = ~i_key_n;      // 1 = 按下

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            deb_cnt   <= 32'd0;
            pressed   <= 1'b0;
            pressed_d <= 1'b0;
            hold_cnt  <= 32'd0;
            rpt_cnt   <= 32'd0;
            repeating <= 1'b0;
            o_press   <= 1'b0;
        end else begin
            o_press   <= 1'b0;
            pressed_d <= pressed;

            // ---- 消抖：输入与稳定值不同则计数，持续 DEB 拍后更新稳定值
            if (key_raw != pressed) begin
                if (deb_cnt >= DEB - 1) begin
                    deb_cnt <= 32'd0;
                    pressed <= key_raw;
                end else begin
                    deb_cnt <= deb_cnt + 32'd1;
                end
            end else begin
                deb_cnt <= 32'd0;
            end

            // ---- 按下沿：立即一个脉冲，并复位长按计时
            if (pressed && !pressed_d) begin
                o_press   <= 1'b1;
                hold_cnt  <= 32'd0;
                rpt_cnt   <= 32'd0;
                repeating <= 1'b0;
            end else if (pressed) begin
                if (!repeating) begin
                    // 长按等待期
                    if (hold_cnt >= HLD - 1) begin
                        hold_cnt  <= 32'd0;
                        rpt_cnt   <= 32'd0;
                        repeating <= 1'b1;
                    end else begin
                        hold_cnt <= hold_cnt + 32'd1;
                    end
                end else begin
                    // 连发期
                    if (rpt_cnt >= RPT - 1) begin
                        rpt_cnt <= 32'd0;
                        o_press <= 1'b1;
                    end else begin
                        rpt_cnt <= rpt_cnt + 32'd1;
                    end
                end
            end else begin
                hold_cnt  <= 32'd0;
                rpt_cnt   <= 32'd0;
                repeating <= 1'b0;
            end
        end
    end

endmodule
