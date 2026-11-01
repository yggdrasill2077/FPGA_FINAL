`timescale 1ns/1ps

module tb_frame_ring_ctrl;
  reg clk = 0;
  reg rst_n = 0;
  reg wr_sw = 0;
  reg rd_sw = 0;
  reg rd_replay_en = 0;

  wire [31:0] wr_addr;
  wire [31:0] rd_addr;
  wire        wr_ack;
  wire        rd_ack;
  wire [4:0]  hist_oldest;
  wire [5:0]  hist_count;
  wire        rd_ready;

  integer frame;
  integer errors = 0;

  frame_ring_ctrl #(
    .START_ADDR (32'h00000000),
    .FRAME_LEN  (32'd1000      ),
    .LIVE_NUM   (3             ),
    .HIST_NUM   (30            ),
    .DECIM      (4             ),
    .AW         (32            )
  ) dut (
    .clk(clk), .rst_n(rst_n), .wr_sw(wr_sw), .rd_sw(rd_sw),
    .rd_replay_en(rd_replay_en),
    .wr_start_addr(wr_addr), .rd_start_addr(rd_addr),
    .wr_sw_ack(wr_ack), .rd_sw_ack(rd_ack),
    .hist_oldest(hist_oldest), .hist_count(hist_count),
    .ring_rd_ready(rd_ready)
  );

  always #5 clk = ~clk;

  task pulse_wr;
    begin
      @(negedge clk); wr_sw = 1;
      @(negedge clk); wr_sw = 0;
      @(negedge clk);
    end
  endtask

  task pulse_rd;
    begin
      @(negedge clk); rd_sw = 1;
      @(negedge clk); rd_sw = 0;
      @(negedge clk);
    end
  endtask

  task expect32;
    input [31:0] got;
    input [31:0] exp;
    input [255:0] name;
    begin
      if (got !== exp) begin
        $display("FAIL %0s got=%0d expected=%0d", name, got, exp);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    expect32(wr_addr, 32'd3000, "reset wr_addr");
    expect32(rd_addr, 32'd0,    "reset rd_addr");
    if (rd_ready !== 1'b0) begin
      $display("FAIL reset rd_ready should be 0");
      errors = errors + 1;
    end

    // 120 帧 = 30 个历史槽，整环刚好填满。
    for (frame = 0; frame < 120; frame = frame + 1) begin
      pulse_wr;
      pulse_rd;
    end

    if (hist_count !== 6'd30) begin
      $display("FAIL hist_count=%0d expected 30", hist_count);
      errors = errors + 1;
    end
    if (hist_oldest !== 5'd0) begin
      $display("FAIL hist_oldest=%0d expected 0", hist_oldest);
      errors = errors + 1;
    end
    expect32(wr_addr, 32'd3000, "wrap wr_addr");

    repeat (3) pulse_wr;
    pulse_wr;
    if (hist_oldest !== 5'd1) begin
      $display("FAIL old after wrap=%0d expected 1", hist_oldest);
      errors = errors + 1;
    end
    expect32(wr_addr, 32'd4000, "next history addr");

    // 重新复位，检查寄存后的读地址、空队列保持、滞后封顶与解冻恢复。
    rst_n = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);
    if (rd_ready !== 1'b0) begin
      $display("FAIL rd_ready should be 0 after reset");
      errors = errors + 1;
    end

    pulse_wr;                       // hist slot 0 -> 3000
    if (rd_ready !== 1'b1) begin
      $display("FAIL rd_ready should rise after first frame");
      errors = errors + 1;
    end
    expect32(rd_addr, 32'd0, "rd_addr is registered");
    pulse_rd;
    expect32(rd_addr, 32'd3000, "pop 1");
    pulse_rd;
    expect32(rd_addr, 32'd3000, "hold when map empty");

    // 连续 4 个完成帧不读：最旧的两个地址应被丢弃，滞后最多 2 帧。
    pulse_wr;                       // live0 -> 0
    pulse_wr;                       // live1 -> 1000
    pulse_wr;                       // live2 -> 2000
    pulse_wr;                       // hist1 -> 4000
    pulse_rd;
    expect32(rd_addr, 32'd2000, "lag capped to 2");
    pulse_rd;
    expect32(rd_addr, 32'd4000, "lag pop 2");
    pulse_rd;
    expect32(rd_addr, 32'd4000, "lag pop 3");
    pulse_rd;
    expect32(rd_addr, 32'd4000, "hold after drain");

    // 冻结回放期间不弹队列；解冻后地址指向最近写完的实时槽，且 ready 不清零。
    rd_replay_en = 1;
    repeat (2) @(negedge clk);
    pulse_rd;
    expect32(rd_addr, 32'd4000, "replay keeps map");
    pulse_rd;
    expect32(rd_addr, 32'd4000, "replay keeps map 2");
    rd_replay_en = 0;
    repeat (2) @(negedge clk);
    if (rd_ready !== 1'b1) begin
      $display("FAIL rd_ready must stay high after unfreeze");
      errors = errors + 1;
    end
    expect32(rd_addr, 32'd2000, "unfreeze points to last live slot");
    if (hist_count !== 6'd2) begin
      $display("FAIL hist_count=%0d expected 2", hist_count);
      errors = errors + 1;
    end

    if (errors == 0) $display("PASS frame_ring_ctrl");
    $finish;
  end
endmodule
