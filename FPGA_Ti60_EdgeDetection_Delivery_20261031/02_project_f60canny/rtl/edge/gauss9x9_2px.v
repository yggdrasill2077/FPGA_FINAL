// gauss9x9_2px.v -- 可分离 9x9 高斯（σ≈1.84），2px/clk
//   行方向：9 抽头 [1 8 28 56 70 56 28 8 1]/256（4 级像素对延迟，无 RAM）
//   列方向：8 个行缓存（轮转写）+ 当前行 = 9 行，抽头按写指针重排
module gauss9x9_2px #(
    parameter integer H_PAIRS = 960,
    parameter integer ADDR_W  = 10
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [15:0] i_pair,
    output reg         o_de,
    output reg  [15:0] o_pair
);
    // ---------------- 行方向 9 抽头 ----------------
    reg  [15:0] d1, d2, d3, d4;
    reg  [9:0]  px;
    reg         eol;                     // 行结束标志

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1<=0; d2<=0; d3<=0; d4<=0; px<=0; eol<=1'b0;
        end else if (!i_de) begin
            d1<=0; d2<=0; d3<=0; d4<=0; px<=0; eol<=1'b0;
        end else begin
            d1<=i_pair; d2<=d1; d3<=d2; d4<=d3;
            px <= px + 10'd1;
            eol<= (px == H_PAIRS-1);
        end
    end

    wire [7:0] a0=d4[7:0],  a1=d4[15:8], a2=d3[7:0], a3=d3[15:8], a4=d2[7:0];
    wire [7:0] a5=d2[15:8], a6=d1[7:0],  a7=d1[15:8], a8=i_pair[7:0];
    wire [7:0] b0=d4[15:8], b1=d3[7:0],  b2=d3[15:8], b3=d2[7:0],  b4=d2[15:8];
    wire [7:0] b5=d1[7:0],  b6=d1[15:8], b7=i_pair[7:0], b8=i_pair[15:8];

    wire [15:0] hs0 = (a0+a8) + ((a1+a7)<<3) + ((a2+a6)*8'd28) + ((a3+a5)*8'd56) + (a4*8'd70);
    wire [15:0] hs1 = (b0+b8) + ((b1+b7)<<3) + ((b2+b6)*8'd28) + ((b3+b5)*8'd56) + (b4*8'd70);
    wire [15:0] hp  = {hs1[15:8], hs0[15:8]};        // 行方向 /256

    // ---------------- 8 个行缓存（轮转写）----------------
    reg  [2:0] wr;
    reg  [9:0] px1;
    reg        de1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wr<=3'd0; px1<=10'd0; de1<=1'b0; end
        else begin
            de1 <= i_de;
            px1 <= px;
            if (i_vs)     wr <= 3'd0;
            else if (eol) wr <= wr + 3'd1;
        end
    end

    wire [15:0] r0,r1,r2,r3,r4,r5,r6,r7;
    wire we0 = i_de && (wr==3'd0), we1 = i_de && (wr==3'd1);
    wire we2 = i_de && (wr==3'd2), we3 = i_de && (wr==3'd3);
    wire we4 = i_de && (wr==3'd4), we5 = i_de && (wr==3'd5);
    wire we6 = i_de && (wr==3'd6), we7 = i_de && (wr==3'd7);

    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r0 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we0), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r0));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r1 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we1), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r1));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r2 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we2), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r2));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r3 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we3), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r3));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r4 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we4), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r4));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r5 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we5), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r5));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r6 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we6), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r6));
    simple_dual_port_ram #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_W)) u_r7 (
        .wdata(hp), .waddr(px[ADDR_W-1:0]), .raddr(px1[ADDR_W-1:0]),
        .we(we7), .wclk(clk), .re(1'b1), .rclk(clk), .rdata(r7));

    // 当前行（对齐 RAM 读延迟：1 拍）
    reg [15:0] cur1, cur2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cur1<=0; cur2<=0; end
        else begin cur1<=hp; cur2<=cur1; end
    end

    // 抽头重排：k=0(最老)..7 → RAM[(base+1+k)&7]，base = 当前写指针
    wire [2:0] b0i = wr + 3'd1, b1i = wr + 3'd2, b2i = wr + 3'd3, b3i = wr + 3'd4;
    wire [2:0] b4i = wr + 3'd5, b5i = wr + 3'd6, b6i = wr + 3'd7, b7i = wr;

    reg [15:0] tap [0:7];
    always @(*) begin
        case (b0i) 3'd0: tap[0]=r0; 3'd1: tap[0]=r1; 3'd2: tap[0]=r2; 3'd3: tap[0]=r3;
                   3'd4: tap[0]=r4; 3'd5: tap[0]=r5; 3'd6: tap[0]=r6; default: tap[0]=r7; endcase
        case (b1i) 3'd0: tap[1]=r0; 3'd1: tap[1]=r1; 3'd2: tap[1]=r2; 3'd3: tap[1]=r3;
                   3'd4: tap[1]=r4; 3'd5: tap[1]=r5; 3'd6: tap[1]=r6; default: tap[1]=r7; endcase
        case (b2i) 3'd0: tap[2]=r0; 3'd1: tap[2]=r1; 3'd2: tap[2]=r2; 3'd3: tap[2]=r3;
                   3'd4: tap[2]=r4; 3'd5: tap[2]=r5; 3'd6: tap[2]=r6; default: tap[2]=r7; endcase
        case (b3i) 3'd0: tap[3]=r0; 3'd1: tap[3]=r1; 3'd2: tap[3]=r2; 3'd3: tap[3]=r3;
                   3'd4: tap[3]=r4; 3'd5: tap[3]=r5; 3'd6: tap[3]=r6; default: tap[3]=r7; endcase
        case (b4i) 3'd0: tap[4]=r0; 3'd1: tap[4]=r1; 3'd2: tap[4]=r2; 3'd3: tap[4]=r3;
                   3'd4: tap[4]=r4; 3'd5: tap[4]=r5; 3'd6: tap[4]=r6; default: tap[4]=r7; endcase
        case (b5i) 3'd0: tap[5]=r0; 3'd1: tap[5]=r1; 3'd2: tap[5]=r2; 3'd3: tap[5]=r3;
                   3'd4: tap[5]=r4; 3'd5: tap[5]=r5; 3'd6: tap[5]=r6; default: tap[5]=r7; endcase
        case (b6i) 3'd0: tap[6]=r0; 3'd1: tap[6]=r1; 3'd2: tap[6]=r2; 3'd3: tap[6]=r3;
                   3'd4: tap[6]=r4; 3'd5: tap[6]=r5; 3'd6: tap[6]=r6; default: tap[6]=r7; endcase
        case (b7i) 3'd0: tap[7]=r0; 3'd1: tap[7]=r1; 3'd2: tap[7]=r2; 3'd3: tap[7]=r3;
                   3'd4: tap[7]=r4; 3'd5: tap[7]=r5; 3'd6: tap[7]=r6; default: tap[7]=r7; endcase
    end

    wire [7:0] p0=tap[0][7:0],  p1=tap[1][7:0],  p2=tap[2][7:0],  p3=tap[3][7:0];
    wire [7:0] p4=tap[4][7:0],  p5=tap[5][7:0],  p6=tap[6][7:0],  p7=tap[7][7:0];
    wire [7:0] p8=cur2[7:0];
    wire [15:0] vs0 = (p0+p8) + ((p1+p7)<<3) + ((p2+p6)*8'd28) + ((p3+p5)*8'd56) + (p4*8'd70);

    wire [7:0] q0=tap[0][15:8], q1=tap[1][15:8], q2=tap[2][15:8], q3=tap[3][15:8];
    wire [7:0] q4=tap[4][15:8], q5=tap[5][15:8], q6=tap[6][15:8], q7=tap[7][15:8];
    wire [7:0] q8=cur2[15:8];
    wire [15:0] vs1 = (q0+q8) + ((q1+q7)<<3) + ((q2+q6)*8'd28) + ((q3+q5)*8'd56) + (q4*8'd70);

    reg de2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin de2<=1'b0; o_de<=1'b0; o_pair<=16'd0; end
        else begin
            de2 <= de1;
            o_de <= de2;
            o_pair <= {vs1[15:8], vs0[15:8]};
        end
    end
endmodule
