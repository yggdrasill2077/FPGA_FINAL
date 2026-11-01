

`timescale 1ps/1ps
module ddr_buffer #(
parameter AXI_DATA_WIDTH = 512, //!AXI接口位宽
parameter AXI_ADDR_WIDTH = 33,  //!AXI地址位宽
parameter WR_FIFO_DEPTH	= 1024, //!Write fifo depth   
parameter RD_FIFO_DEPTH = 1024, //!read fifo depth
parameter FB_NUM			= 	3,//2 buffer ,3 buffer   
parameter MAX_VID_WIDTH		=	1920 ,//video width 
parameter MAX_VID_HIGHT		=	1080 ,//wideo height
parameter START_ADDR				=	33'h000201900,
parameter BURST_LEN       = 8'd15,
parameter I_VID_WIDTH = 16,
parameter AXI_STRB_WIDTH = AXI_DATA_WIDTH/8//!总共的字节数量，= AXI_DATA_WIDTH/8

) (

input 											axi_clk,
input                       wr_clk_rst_n,
input                       axi_clk_rst_n,
input                       rd_clk_rst_n,
input 											rd_start,
input											wr_start, // pulse signal 
input                       rd_replay_en,   //!冻结回放：1 = 忽略 bank_switch 的 rd_start_addr，按 rd_replay_bank 指定
 input		[4:0]				      rd_replay_bank, //!冻结回放历史槽 0..29

 output wire [4:0]                     o_hist_oldest,   //!历史环最旧槽
 output wire [5:0]                     o_hist_count,    //!历史环有效帧数
 output wire                           o_ring_rd_ready, //!实时地址映射已有可读帧

// input		[AXI_ADDR_WIDTH-1:0]				start_wr_addr,
// input		[AXI_ADDR_WIDTH-1:0]				start_rd_addr,
input 		[31:0] 								wr_busrt_len,
input 		[31:0] 								rd_burst_len,
output		[7:0] test_cnt ,

input                     wr_fifo_rst_p,
input											wr_fifo_wrclk,
input											wr_fifo_wren,
output											wr_fifo_wrfull,
input	 [AXI_DATA_WIDTH-1:0]					wr_fifo_wrdata, 
input											rd_fifo_rdclk,
input                       rd_fifo_rst_p,
output											rd_fifo_rdvalid,
output	 [AXI_DATA_WIDTH-1:0] 					rd_fifo_rddata,
output wire										rd_fifo_rdempty,
input	 wire									rd_fifo_rden,

output 	[5:0] 									awid,
output  [AXI_ADDR_WIDTH-1:0] 					awaddr,
output  [8-1:0] 					awlen,
output  [2:0] 									awsize,
output  [1:0] 									awburst,
output  [3:0] 									awcache,
output [2:0]                    awprot,
output  										awlock,
output  										awvalid,
output  										awcobuf,
output  										awapcmd,
output  										awallstrb,
output  										awqos,
input 											awready,

output [5:0] 									arid,
output  [AXI_ADDR_WIDTH-1:0] 					araddr,
output  [8-1:0] 					arlen,
output  [2:0] 									arsize,
output  [1:0] 									arburst,
output  										arlock,
output  										arvalid,
output  										arapcmd,
output 											arqos,
input 											arready,
output  [3:0] 									arcache,
output [2:0]                    arprot,
output  [AXI_DATA_WIDTH-1:0] 					wdata,  
output	[31:0]									test_wdata,
output	[31:0]									test_rdata,
output  [AXI_STRB_WIDTH-1:0] 					wstrb,
output  										wlast,
output  										wvalid,
input 											wready,

input [5:0] 									rid,
input [AXI_DATA_WIDTH-1:0] 						rdata,
input 											rlast,
input 											rvalid,
output  										rready,
input [1:0] 									rresp,
output[31:0]									wr_fifo_rd_data_test,
input [5:0] 									bid,
input 											bvalid,
output  										bready,

output [7:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;

//=============================================================
//reg define 
//=============================================================   


//=============================================================
//wire define 
//============================================================= 



wire		                        wr_sw_ack           ;
wire		                        wr_sw 		          ;
wire		                        rd_sw			          ;
wire		                        rd_sw_ack           ;
wire		[AXI_ADDR_WIDTH-1:0]		wr_start_addr       ;
wire		[AXI_ADDR_WIDTH-1:0]    rd_start_addr       ; 

//=============================================================
//冻结回放：读 bank 基址强制通道
//   bank 间距必须与 bank_switch 内部的 FRAME_LEN 完全一致，所以用同一表达式重算：
//   bank_switch 拿到的 MAX_VID_WIDTH/MAX_VID_HIGHT/I_VID_WIDTH 就是本模块透传下去的参数。
//   （当前参数下 = 960*1080*32/8 + 0x200 = 4,147,712 = 0x3F4A00）
//   只替换送进 ddr_rd_buffer 的 start_addr，bank_switch 的 wr_sw/rd_sw 握手完全不动。
//   ddr_rd_buffer 仅在每帧 start 上升沿锁存该地址，因此这里组合切换不会撕裂正在显示的那一帧。
//=============================================================
localparam [31:0] BANK_FRAME_LEN = MAX_VID_WIDTH*MAX_VID_HIGHT*I_VID_WIDTH/8 + 32'h200;
localparam [31:0] LIVE_BASE_ADDR = START_ADDR;
localparam [31:0] HIST_BASE_ADDR = START_ADDR + 3*BANK_FRAME_LEN;

// FB_NUM>3 是 3 个实时槽 + 30 个历史槽的环形缓存；
// FB_NUM<=3 保持原来的三 bank 行为，便于回退和对比。
wire [31:0] replay_slot_off = {{27{1'b0}}, rd_replay_bank} * BANK_FRAME_LEN;
wire [31:0] rd_bank_base = (FB_NUM > 3) ? (HIST_BASE_ADDR + replay_slot_off)
                                        : (LIVE_BASE_ADDR + replay_slot_off);

wire [AXI_ADDR_WIDTH-1:0] rd_start_addr_sel = rd_replay_en ? rd_bank_base[AXI_ADDR_WIDTH-1:0]
                                                           : rd_start_addr;

//=============================================================  
//RTL                                                     
//=============================================================  



ddr_wr_buffer # (
    .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .WR_FIFO_DEPTH(WR_FIFO_DEPTH),
    .BURST_LEN (BURST_LEN        )
  )

  u_ddr_wr_buffer (//_inst
    .axi_clk(axi_clk),
    .rst_n(axi_clk_rst_n),//(rst_n),
    .wr_start(wr_start),
    .start_addr(wr_start_addr),//(0),//
    .total_burst_len(wr_busrt_len),
/*i*/.bank_sw_ack	(wr_sw_ack   	),
/*o*/.bank_sw 		  (wr_sw  		 	),
    .test_cnt(test_cnt),
    .wr_fifo_rst_p(wr_fifo_rst_p),
    .wr_fifo_wrclk(wr_fifo_wrclk),
    .wr_fifo_wren(wr_fifo_wren),
    .wr_fifo_wrfull(wr_fifo_wrfull),
    .wr_fifo_wrdata(wr_fifo_wrdata),
    .awid(awid),
    .awaddr(awaddr),
    .awlen(awlen),
    .awsize(awsize),
    .awburst(awburst),
    .awcache(awcache),
    .awlock(awlock),
    .awvalid(awvalid),
    .awcobuf(awcobuf),
    .awapcmd(awapcmd),
    .awallstrb(awallstrb),
    .awprot (awprot ),
    .awqos(awqos),
    .awready(awready),
    .wdata(wdata),
    .wstrb(wstrb),
    .wlast(wlast),
    .wvalid(wvalid),
    .wready(wready),
	  .bid	( bid			),
    .bvalid	( bvalid		),
    .bready	( bready		)
  );


assign test_wdata = wdata[32:0];
assign test_rdata = rdata[32:0];
//=============================================================================================
// FIFO RD_PROCESSING
//=============================================================================================
ddr_rd_buffer # (
    .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .RD_FIFO_DEPTH(RD_FIFO_DEPTH),
    .BURST_LEN (BURST_LEN        )
  )
  ddr_rd_buffer_inst (
    .axi_clk(axi_clk),
    .axi_clk_rst_n(axi_clk_rst_n),
    .start(rd_start),
    .start_addr(rd_start_addr_sel),//(rd_start_addr),// 冻结回放时由 rd_replay_bank 强制指定
    .burst_len(rd_burst_len),
    .rd_fifo_rdclk(rd_fifo_rdclk),
    .rd_fifo_rst_p (rd_fifo_rst_p),
    .rd_fifo_rdvalid(rd_fifo_rdvalid),
    .rd_fifo_rddata(rd_fifo_rddata),
    .rd_fifo_rdempty(rd_fifo_rdempty),
    .rd_fifo_rden(rd_fifo_rden),
/*i*/.bank_sw_ack	(rd_sw_ack   	),
/*o*/.bank_sw 		  (rd_sw  		 	),
    .arid(arid),
    .araddr(araddr),
    .arlen(arlen),
    .arsize(arsize),
    .arburst(arburst),
    .arlock(arlock),
    .arvalid(arvalid),
    .arapcmd(arapcmd),
    .arqos(arqos),
    .arready(arready),
    .arprot (arprot ),
    .arcache(arcache),
    .rid(rid),
    .rdata(rdata),
    .rlast(rlast),
    .rvalid(rvalid),
    .rready(rready),
    .rresp(rresp),
    .wr_fifo_rd_data_test(wr_fifo_rd_data_test)
  );
//===================================================================================== 
//
//===================================================================================== 
  


generate
if (FB_NUM > 3) begin : g_hist_ring
  frame_ring_ctrl #(
    .START_ADDR   (START_ADDR    ),
    .FRAME_LEN    (BANK_FRAME_LEN),
    .LIVE_NUM     (3             ),
    .HIST_NUM     (30            ),
    .DECIM        (4             ),
    .AW           (AXI_ADDR_WIDTH)
  ) u_frame_ring_ctrl (
    .clk            (axi_clk      ),
    .rst_n          (axi_clk_rst_n),
    .wr_sw          (wr_sw        ),
    .rd_sw          (rd_sw        ),
    .rd_replay_en   (rd_replay_en ),
    .wr_start_addr  (wr_start_addr),
    .rd_start_addr  (rd_start_addr),
    .wr_sw_ack      (wr_sw_ack    ),
    .rd_sw_ack      (rd_sw_ack    ),
    .hist_oldest    (o_hist_oldest),
    .hist_count     (o_hist_count ),
    .ring_rd_ready  (o_ring_rd_ready)
  );
end else begin : g_legacy_bank
  bank_switch #(
    .FB_NUM         (FB_NUM         ),
    .MAX_VID_WIDTH  (MAX_VID_WIDTH  ),
    .MAX_VID_HIGHT  (MAX_VID_HIGHT  ),
    .START_ADDR     (START_ADDR     ),
    .VID_DATA_WIDTH (I_VID_WIDTH    ),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH )
  ) u_bank_sw (
    .ddr_clk       (axi_clk      ),
    .rst_n         (axi_clk_rst_n),
    .wr_sw         (wr_sw        ),
    .rd_sw         (rd_sw        ),
    .wr_bank       (             ),
    .rd_bank       (             ),
    .rd_sw_ack     (rd_sw_ack    ),
    .wr_sw_ack     (wr_sw_ack    ),
    .rd_start_addr (rd_start_addr),
    .wr_start_addr (wr_start_addr)
  );
  assign o_hist_oldest  = 5'd0;
  assign o_hist_count   = 6'd0;
  assign o_ring_rd_ready = 1'b1;
end
endgenerate



/*----------------------------------------------------------------------------------*\
                                 The function code
\*----------------------------------------------------------------------------------*/
function integer clogb2;
input [31:0] value;
begin
value = value - 1;
for (clogb2 = 0; value > 0; clogb2 = clogb2 + 1)
value = value >> 1;
end
endfunction

endmodule


//=============================================================================
// 3 个实时槽 + 30 个历史槽的混合环形缓存控制器
//
// 每 4 帧中的 1 帧写入历史槽，另外 3 帧写入实时槽。每个完成帧的地址
// 压入一个小队列，读侧按队列顺序取地址，因此实时显示仍是 60 fps，
// 而 30 个历史槽正好覆盖 15 fps * 2 s。
//=============================================================================
module frame_ring_ctrl #(
  parameter START_ADDR = 32'h00000000,
  parameter FRAME_LEN  = 32'd4147712,
  parameter LIVE_NUM   = 3,
  parameter HIST_NUM   = 30,
  parameter DECIM      = 4,
  parameter AW         = 32
)(
  input  wire                 clk,
  input  wire                 rst_n,
  input  wire                 wr_sw,
  input  wire                 rd_sw,
  input  wire                 rd_replay_en,
  output reg  [AW-1:0]        wr_start_addr,
  output reg  [AW-1:0]        rd_start_addr,
  output reg                  wr_sw_ack,
  output reg                  rd_sw_ack,
  output wire [4:0]           hist_oldest,
  output wire [5:0]           hist_count,
  output wire                 ring_rd_ready
);

  localparam [31:0] LIVE_BASE = START_ADDR;
  localparam [31:0] HIST_BASE = START_ADDR + LIVE_NUM*FRAME_LEN;

  reg [AW-1:0] map_fifo [0:7];
  reg [2:0]    map_wp;
  reg [2:0]    map_rp;
  reg [3:0]    map_count;
  reg          map_seen;

  reg [1:0]    phase;
  reg [1:0]    live_idx;
  reg [4:0]    hist_idx;
  reg [5:0]    hist_cnt;

  reg          wr_sw_d;
  reg          rd_sw_d;
  reg          rd_replay_en_d;
  wire         wr_end = wr_sw & ~wr_sw_d;
  wire         rd_end = rd_sw & ~rd_sw_d;
  wire         replay_fall = rd_replay_en_d & ~rd_replay_en;

  wire [1:0] phase_n = (phase == (DECIM-1)) ? 2'd0 : phase + 2'd1;
  wire [1:0] live_n  = (phase == 2'd0) ? live_idx :
                       ((live_idx == (LIVE_NUM-1)) ? 2'd0 : live_idx + 2'd1);
  wire [4:0] hist_n  = (phase == 2'd0) ?
                       ((hist_idx == (HIST_NUM-1)) ? 5'd0 : hist_idx + 5'd1) : hist_idx;
  wire [5:0] hist_cnt_n = (phase == 2'd0 && hist_cnt != HIST_NUM) ? hist_cnt + 6'd1 : hist_cnt;

  wire push = wr_end;
  wire pop  = rd_end & ~rd_replay_en & (map_count != 0);
  // 读侧最多允许落后 2 个已完成帧：3 个实时槽每 4 帧复用一次，
  // 一旦滞后到 4/8 帧，读地址就会正好撞上正在写的槽，出现撕裂。
  wire drop = push & ~pop & (map_count >= 4'd2);

  assign ring_rd_ready  = map_seen;
  assign hist_count     = hist_cnt;
  assign hist_oldest    = (hist_cnt == HIST_NUM) ? hist_idx : 5'd0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      map_wp <= 3'd0;
      map_rp <= 3'd0;
      map_count <= 4'd0;
      map_seen <= 1'b0;
      rd_start_addr <= LIVE_BASE;
      rd_replay_en_d <= 1'b0;
    end else if (replay_fall) begin
      // 解冻后队列里全是冻结前的旧地址，清空并指向最近一个已写完的实时槽，
      // 避免恢复瞬间读到正在写的槽，也避免读地址悬空。
      map_wp <= 3'd0;
      map_rp <= 3'd0;
      map_count <= 4'd0;
      rd_start_addr <= LIVE_BASE +
                       ((live_idx == 2'd0) ? 2'd2 : (live_idx - 2'd1)) * FRAME_LEN;
      rd_replay_en_d <= rd_replay_en;
    end else begin
      rd_replay_en_d <= rd_replay_en;
      if (push) begin
        map_fifo[map_wp] <= wr_start_addr;
        map_wp <= map_wp + 3'd1;
        map_seen <= 1'b1;
      end
      if (pop) begin
        rd_start_addr <= map_fifo[map_rp];
        map_rp <= map_rp + 3'd1;
      end else if (drop) begin
        map_rp <= map_rp + 3'd1;
      end
      // 队列空时保持上一个读地址：冻结期间没有新帧，读侧继续重复最后一帧，
      // 不再用 ready 掐断 rd_start（否则 DDR->FIFO 断流，画面会黑/花）。
      map_count <= map_count + {3'd0, push} - {3'd0, pop} - {3'd0, drop};
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_sw_d <= 1'b0;
      rd_sw_d <= 1'b0;
      wr_sw_ack <= 1'b0;
      rd_sw_ack <= 1'b0;
    end else begin
      wr_sw_d <= wr_sw;
      rd_sw_d <= rd_sw;
      wr_sw_ack <= wr_end;
      rd_sw_ack <= rd_end;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase    <= 2'd0;
      live_idx <= 2'd0;
      hist_idx <= 5'd0;
      hist_cnt <= 6'd0;
      wr_start_addr <= HIST_BASE;
    end else if (wr_end) begin
      phase    <= phase_n;
      live_idx <= live_n;
      hist_idx <= hist_n;
      hist_cnt <= hist_cnt_n;
      if (phase_n == 2'd0)
        wr_start_addr <= HIST_BASE + hist_idx * FRAME_LEN;
      else
        wr_start_addr <= LIVE_BASE + live_n * FRAME_LEN;
    end
  end

endmodule
