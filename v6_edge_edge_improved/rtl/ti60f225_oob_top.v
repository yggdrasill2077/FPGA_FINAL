
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//Ti60f225_sc431hai2hdmi_v6：
//使用了最新版本的framebuffer_v3;
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
// `include "define.v"

module ti60f225_oob_top #(

	parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
	parameter                       RANKS              = `RANKS,
	parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
	parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
	parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
	parameter                       DATA_WIDTH         = `DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
	parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(

  (* syn_peri_port = 0 *) input jtag_inst1_CAPTURE,
  (* syn_peri_port = 0 *) input jtag_inst1_DRCK,
  (* syn_peri_port = 0 *) input jtag_inst1_RESET,
  (* syn_peri_port = 0 *) input jtag_inst1_RUNTEST,
  (* syn_peri_port = 0 *) input jtag_inst1_SEL,
  (* syn_peri_port = 0 *) input jtag_inst1_SHIFT,
  (* syn_peri_port = 0 *) input jtag_inst1_TCK,
  (* syn_peri_port = 0 *) input jtag_inst1_TDI,
  (* syn_peri_port = 0 *) input jtag_inst1_TMS,
  (* syn_peri_port = 0 *) input jtag_inst1_UPDATE,
  (* syn_peri_port = 0 *) output jtag_inst1_TDO,

   //Clocks 
	input	wire	i_arstn,
    // 按键（低有效）。4 个键全部已占用，调整检测框补偿只能复用"仅冻结时有效"的键：
    //   KEY0 @GPIOL_07 : 边缘阈值 +64（长按连发） / KEY0+KEY3 同按 0.8s = 冻结开关
    //   KEY3 @GPIOL_03 : 边缘阈值 -64（长按连发） / 同上
    //   KEY2 @GPIOR_21 : 冻结时 = 回放帧步进；非冻结时 = osd_xoff_r += 2（本次新增）
    //   KEY1 @GPIOR_22 : 冻结时 = 自动回放开关；非冻结时 = osd_yoff_r += 1（本次新增）
    //   KEY1+KEY2 同按（非冻结）：两个补偿量恢复默认 22 / 3（本次新增）
    input	wire	i_key0_n,   // KEY0 @GPIOL_07 : 阈值 +64
    input	wire	i_key1_n,   // KEY3 @GPIOL_03 : 阈值 -64
    input	wire	i_key2_n,   // KEY2 @GPIOR_21 : 冻结回放步进 / 非冻结 xoff+2
    input	wire	i_auto_n,   // KEY1 @GPIOR_22 : 自动回放开关 / 非冻结 yoff+1
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire    pll_inst4_RSTN,
	input   wire    pll_inst4_LOCKED,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,
    
    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,
    
    input	wire	[7:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,  
   
    input 	wire	[7:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,

	
	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // CORE CLK @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags  
	output [2:0]                       pll_shift,  
	output [4:0]                       pll_shift_sel,
	output                             pll_shift_ena,  
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [CKE_WIDTH-1:0]             ddr_cke,     
	output [ROW_WIDTH-1:0]             ddr_addr,
	output [BANK_WIDTH-1:0]            ddr_ba,
	output                             ddr_cas_n,
 
	output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,
	
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
	
	output [DQS_WIDTH-1:0]             ddr_dqs_oe,
	output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
	output [DQ_WIDTH-1:0]              ddr_dq_oe,  
	output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
	output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
	output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
	output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
	output [DM_WIDTH-1:0]              ddr_dm_hi,
	output [DM_WIDTH-1:0]              ddr_dm_lo,
	output [ODT_WIDTH-1:0]             ddr_odt,

       //LED（GPIOR_21 已改作 KEY2、GPIOR_22 已改作 KEY1 自动回放，led 只剩 led[3:2]）
       output [3:2] led,

       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,
       output	wire	                     mipi_dp_clk_LP_P_OUT		,
       output	wire	                     mipi_dp_clk_LP_N_OUT		,
       output	wire	[7:0] 	              mipi_dp_clk_HS_OUT		,
       output	wire	                     mipi_dp_clk_HS_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OUT	,
       output	wire	                     mipi_dp_data2_LP_P_OUT	,
       output	wire	                     mipi_dp_data1_LP_P_OUT	,
       output	wire	                     mipi_dp_data0_LP_P_OUT	,
       output	wire	                     mipi_dp_data3_LP_N_OUT	,
       output	wire	                     mipi_dp_data2_LP_N_OUT	,
       output	wire	                     mipi_dp_data1_LP_N_OUT	,
       output	wire	                     mipi_dp_data0_LP_N_OUT	,
       output	wire	[7:0] 	              mipi_dp_data0_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data1_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data2_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data3_HS_OUT	       ,
       output	wire	                     mipi_dp_data3_HS_OE		,
       output	wire	                     mipi_dp_data2_HS_OE		,
       output	wire	                     mipi_dp_data1_HS_OE		,
       output	wire	                     mipi_dp_data0_HS_OE		,

       output	wire	                     mipi_dp_clk_RST		,
       output	wire	                     mipi_dp_data0_RST		,
       output	wire	                     mipi_dp_data1_RST		,
       output	wire	                     mipi_dp_data2_RST		,
       output	wire	                     mipi_dp_data3_RST		,
       output	wire	                     mipi_dp_clk_LP_P_OE		,
       output	wire	                     mipi_dp_clk_LP_N_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OE	,
       output	wire	                     mipi_dp_data3_LP_N_OE	,
       output	wire	                     mipi_dp_data2_LP_P_OE	,
       output	wire	                     mipi_dp_data2_LP_N_OE	,
       output	wire	                     mipi_dp_data1_LP_P_OE	,
       output	wire	                     mipi_dp_data1_LP_N_OE	,
       output	wire	                     mipi_dp_data0_LP_P_OE	,
       output	wire	                     mipi_dp_data0_LP_N_OE	,

       input  wire	                     mipi_dp_data0_LP_P_IN	,
       input  wire	                     mipi_dp_data0_LP_N_IN	,
       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,

       // hdmi interface

    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST


);

function integer log2;
	input	integer	val;
	integer	i;
	begin
		log2 = 0;
		for (i=0; 2**i<val; i=i+1)
			log2 = i+1;
	end
endfunction


//===============================================================================
//localparam
//===============================================================================
localparam WR_FIFO_DEPTH  = 1024;
localparam RD_FIFO_DEPTH  = 1024;

// localparam	MAX_HRES		= 12'd1920;
// localparam	MAX_VRES		= 12'd1080;
// localparam	HSP			= 8'd2;
// localparam	HBP			= 8'd88;
// localparam	HFP			= 8'd120;
// localparam	VSP			= 8'd2;
// localparam	VBP			= 8'd20;
// localparam	VFP			= 8'd20;

localparam MAX_HRES = 1920;
localparam HFP      = 88;
localparam HSP      = 44;
localparam HBP      = 148;

localparam MAX_VRES = 1080;
localparam VFP      = 4;
localparam VSP      = 5;
localparam VBP      = 36;

//================ Sobel 边缘检测参数 ================
//  EDGE_THRESHOLD 默认档：440（原 56）
//  依据：BSDS300 300 张，按当前 RTL 整数口径做行为级复现后的 FOM/Connectivity 联合扫描
//        —— 默认 56 时边缘过密（检出量 ≈ 5×GT），FOM 只有 0.187 / Conn 0.279；
//        提到 440 后 FOM 0.261（该通路最优）且加上 1px 桥接后 Conn 0.395，
//        “FOM + Connectivity + 密度”三项同时优于 56 档（详见 sim/opt_conn_result.md、
//        sim/fom_bsds_report.md、sim/conn_bsds_report.md）。
//        档位仍可用按键按 32 步进调（56+32k 都可达，440 正好在档位上）。
localparam [11:0] EDGE_THRESHOLD      = 12'd56;    // F29 基线：细节优先
localparam [11:0] EDGE_THRESHOLD_STEP = 12'd32;    // 步进 32（原 64 太粗）
localparam [11:0] EDGE_THRESHOLD_MIN  = 12'd16;   // 下限同步上调，避免整屏全白
localparam [11:0] EDGE_THRESHOLD_MAX  = 12'd4032;  // 上限不变
// display_mode=1 → edge_pipeline 输出「全帧二值边缘」，供分屏合成器使用
// （=0 时输出左半原图/右半边缘，合成器无法同时拿到全帧原图与全帧边缘）
localparam        EDGE_DISPLAY_MODE   = 1'b1;
//===============================================================================
//signal
//===============================================================================
   
wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
wire                              cal_done;

// Slave Interface Write Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
wire [7:0]                        s_axi_awlen;
wire [2:0]                        s_axi_awsize;
wire [1:0]                        s_axi_awburst;
wire [0:0]                        s_axi_awlock;
wire [3:0]                        s_axi_awcache;
wire [2:0]                        s_axi_awprot;
wire                              s_axi_awvalid;
wire                              s_axi_awready;
// Slave Interface Write Data Ports
wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb;
wire                              s_axi_wlast;
wire                              s_axi_wvalid;
wire                              s_axi_wready;
// Slave Interface Write Response Ports
wire                              s_axi_bready;
wire [AXI_ID_WIDTH-1:0]           s_axi_bid;
wire [1:0]                        s_axi_bresp;
wire                              s_axi_bvalid;
// Slave Interface Read Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr;
wire [7:0]                        s_axi_arlen;
wire [2:0]                        s_axi_arsize;
wire [1:0]                        s_axi_arburst;
wire [0:0]                        s_axi_arlock;
wire [3:0]                        s_axi_arcache;
wire [2:0]                        s_axi_arprot;
wire                              s_axi_arvalid;
wire                              s_axi_arready;
// Slave Interface Read Data Ports
wire                              s_axi_rready;
wire [AXI_ID_WIDTH-1:0]           s_axi_rid;
wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata;
wire [1:0]                        s_axi_rresp;
wire                              s_axi_rlast;
wire                              s_axi_rvalid;




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
// wire	w_sysclk_mcu_arstn;
// wire	w_sysclk_mcu_arst;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;

wire		       w_mipi_rx_vs;
wire		       w_mipi_rx_hs;
wire	       w_mipi_rx_de;
wire	[63:0]			w_mipi_rx_data	;

wire					io_systemReset;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign mipi_dsi_tx_pll_RSTN 	= i_arstn;
assign DDR3_PLL_RSTN 		= i_arstn;
reset_ctrl
#(
	.NUM_RST		(2),
	.CYCLE			(1),
	.IN_RST_ACTIVE	(4'b00),
	.OUT_RST_ACTIVE	(4'b10)
)
inst_reset_ctrl
(
	.i_arst		({2{w_arstn}}),//({{4{i_pll_locked}},                  {2{i_arstn}}}),
	.i_clk			({2{i_mipi_rx_pclk}}),
	.o_srst		({w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn})
);



reg [25:0] cnt = 'd0;
always @( posedge core_clk)
begin 
       cnt <= cnt + 1'b1;
end
assign led[2]  = cal_done ? cnt[24] : 1'b0;  // 心跳（原 led[0]→led[1]→led[2]；GPIOR_21/22 已改作按键输入）
assign led[3]  = 1'b0;                       // 阈值档位光柱已取消（用户反馈观感不佳）

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;

		assign	cam_d0_RST		= 1'b0;
		assign	cam_d1_RST		= 1'b0;
		assign  cam_d2_RST = 1'b0;
    assign  cam_d3_RST = 1'b0;
	
wire [15:0] mipi_debug_out;
		

		csi_rx_controller inst_efx_csi2_rx
		(
              .reset_n			(i_arstn),
              .clk				(i_mipi_clk),
              .reset_byte_HS_n	(i_arstn),
              .clk_byte_HS		  (i_cam_ck_CLKOUT),
              .reset_pixel_n		(w_mipi_rx_pclk_arstn),
              .clk_pixel			  (i_mipi_rx_pclk),
              
              .Rx_LP_CLK_P		  (i_cam_ck_LP_P_IN),
              .Rx_LP_CLK_N		  (i_cam_ck_LP_N_IN),
              .Rx_HS_enable_C		(o_cam_ck_HS_ENA),
              .LVDS_termen_C		(o_cam_ck_HS_TERM),
              
              .Rx_LP_D_P			({cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN}),//(r_mipi_rx_data_LP_P_IN_2P),
              .Rx_LP_D_N			({cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN}),//(r_mipi_rx_data_LP_N_IN_2P),
              .Rx_HS_D_0			(cam_d0_HS_IN),//(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
              .Rx_HS_D_1			(cam_d1_HS_IN),//(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
              .Rx_HS_D_2			(cam_d2_HS_IN),
              .Rx_HS_D_3			(cam_d3_HS_IN),
              .Rx_HS_D_4			(),
              .Rx_HS_D_5			(),
              .Rx_HS_D_6			(),
              .Rx_HS_D_7			(),
              .Rx_HS_enable_D		({cam_d3_HS_ENA    ,cam_d2_HS_ENA    ,cam_d1_HS_ENA    ,cam_d0_HS_ENA    }),//( w_cam_d_HS_ENA),
              .LVDS_termen_D		({cam_d3_HS_TERM   ,cam_d2_HS_TERM   ,cam_d1_HS_TERM   ,cam_d0_HS_TERM   }),
              .fifo_rd_enable		({cam_d3_FIFO_RD   ,cam_d2_FIFO_RD   ,cam_d1_FIFO_RD   ,cam_d0_FIFO_RD   }),
              .fifo_rd_empty		({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
              .DLY_enable_D		       (),
              .DLY_inc_D			(),
              .u_dly_enable_D		(),
              .u_dly_inc_D		       (),
              
              .axi_clk			(1'b0),
              .axi_reset_n		       (1'b0),
              .axi_awaddr			(6'b0),
              .axi_awvalid		       (1'b0),
              .axi_awready		       (),
              .axi_wdata			(32'b0),
              .axi_wvalid			(1'b0),
              .axi_wready			(),
              
              .axi_bvalid			(),
              .axi_bready			(1'b0),
              .axi_araddr			(6'b0),
              .axi_arvalid		       (1'b0),
              .axi_arready		       (),
              .axi_rdata			(),
              .axi_rvalid			(),
              .axi_rready			(1'b1),
              
              .hsync_vc0			(w_mipi_rx_hs),
              .hsync_vc1			(),
              .hsync_vc2			(),
              .hsync_vc3			(),
              .vsync_vc0			(w_mipi_rx_vs),
              .vsync_vc1			(),
              .vsync_vc2			(),
              .vsync_vc3			(),
              .vc				(),
              .word_count			(),
              .shortpkt_data_field        (),
              .datatype			(),
              .pixel_per_clk		(),
              .pixel_data			(w_mipi_rx_data),
              .pixel_data_valid	       (w_mipi_rx_de),
              .irq				(),
              .mipi_debug_out(mipi_debug_out)
		);

//     wire		       w1_mipi_rx_vs;
// wire		       w1_mipi_rx_hs;
// wire	       w1_mipi_rx_de;
// wire	[39:0]			w1_mipi_rx_data	;
// sensor_clipper  sensor_clipper_inst (
//     .clk(i_mipi_rx_pclk),
//     .i_vs(w_mipi_rx_vs),
//     .i_hs(w_mipi_rx_hs),
//     .i_de(w_mipi_rx_de),
//     .i_dat(w_mipi_rx_data[39:0]),

//     .o_hs(w1_mipi_rx_hs),
//     .o_vs(w1_mipi_rx_vs),
//     .o_de(w1_mipi_rx_de),
//     .o_dat(w1_mipi_rx_data)
   
//   );


wire mdebug_pixel_fifo_full     = mipi_debug_out[0] ;
wire mdebug_pixel_fifo_empty    = mipi_debug_out[1] ;
wire mdebug_crc_error           = mipi_debug_out[2] ;
wire mdebug_ecc_1bit_error      = mipi_debug_out[3] ;
wire mdebug_ecc_2bit_error      = mipi_debug_out[4] ;
wire mdebug_undersize_pkt_error = mipi_debug_out[5] ;
wire mdebug_line_vc0_error      = mipi_debug_out[6] ;
wire mdebug_frame_vc0_error    = mipi_debug_out[10];   
wire mdebug_receive_error      = mipi_debug_out[14];


//========================================================================================================
//
//========================================================================================================
		

//*************** imx219 config********************/
// mipi_config_imx219_top u_config_imx219(
// 										.i_sys_clk(CLK_5M)    	,    /////48M 
// 										.sys_rstn(vid_rst_n )    ,
// 										.o_sen_rst_n(o_cam_rstn)  	,
										
										// .o_iic_sda_OE(io_cam_sda_OE) ,
										// .i_iic_sda(io_cam_sda_IN)   	,
										// .o_iic_sda(io_cam_sda_OUT)   	,
										// .o_iic_scl(io_cam_scl)    	
										// ); 	

wire scl_padoen_o;
wire sda_padoen_o;


reg [12:0] i2c_rst_cnt = '0;

always @( posedge CLK_5M or negedge w_arstn )
begin
    if( !w_arstn )
       i2c_rst_cnt <= 'd0;
    else 
       i2c_rst_cnt <= i2c_rst_cnt[12] ? i2c_rst_cnt : i2c_rst_cnt + 1'b1;
end
wire i2c_rst_n = i2c_rst_cnt[12];

i2c_master_ctrl_top u2_i2c_master_ctrl_top(
  /*i*/.clk			(CLK_5M		),
  /*i*/.rst_n			(i2c_rst_n		),
  /*i*/.scl_pad_i     (io_cam_scl_IN),//(1'b1),
  /*o*/.scl_pad_o     (io_cam_scl_OUT),
  /*o*/.scl_padoen_o  (scl_padoen_o),
  /*i*/.sda_pad_i     (io_cam_sda_IN),
  /*o*/.sda_pad_o     (io_cam_sda_OUT),
  /*o*/.sda_padoen_o  (sda_padoen_o)
  
  );
assign o_cam_rst_p = ~w_arstn;
assign io_cam_scl_OE = ~scl_padoen_o;
assign io_cam_sda_OE = ~sda_padoen_o;

//=====================================================================================
//frame buffer
//=====================================================================================
wire [7:0] 	ch0_r;
wire [7:0]    ch0_g;
wire [7:0]    ch0_b;
wire ch0_vs;
wire ch0_hs;
wire ch0_de;
// IMX219
// ---- 帧冻结：freeze_on 同步到 CSI 时钟域，只在 vs 变化时更新 frz_de ----
//      保留 vs（不打断 frame_info_det 时间基准），只掐数据
//      注意：freeze_on / rp_en_s2 / rp_idx_s2 的赋值逻辑在下方按键区，
//      这里先声明，避免 iverilog "declaration after use" 报错（Efinity 不受影响）
reg  freeze_on;
reg  rp_en_s1, rp_en_s2;
reg  [1:0] rp_idx_s1, rp_idx_s2;
reg  fz_s1, fz_s2, fz_s3;
always @( posedge i_mipi_rx_pclk or negedge w_arstn ) begin
  if( !w_arstn ) begin fz_s1 <= 1'b0; fz_s2 <= 1'b0; fz_s3 <= 1'b0; end
  else begin fz_s1 <= freeze_on; fz_s2 <= fz_s1; fz_s3 <= fz_s2; end
end

reg vs_csi_d;
reg frz_de;
always @( posedge i_mipi_rx_pclk or negedge w_arstn ) begin
  if( !w_arstn ) begin vs_csi_d <= 1'b0; frz_de <= 1'b0; end
  else begin
    vs_csi_d <= w_mipi_rx_vs;
    if( w_mipi_rx_vs != vs_csi_d ) frz_de <= fz_s3;
  end
end
  frame_buffer #(
.I_VID_WIDTH         (32),
.O_VID_WIDTH         (16),
.START_ADDR          (32'h00000        ),
.AXI_DATA_WIDTH      ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	      ( 1024		),    
.RD_FIFO_DEPTH 	      ( 1024 	),
.BURST_LEN  	       (127),
.FB_NUM	            (3),
.MAX_VID_WIDTH	    (960) ,
.MAX_VID_HIGHT	    (1080) 


)checker0(
       .axi_clk		(core_clk 	        ),
       .rst_n			(vid_rst_n   ),

/*i*/.rd_replay_en	(rp_en_s2	),	// 冻结回放：强制读 bank
/*i*/.rd_replay_bank	(rp_idx_s2	),	// 冻结回放：bank 序号 0..2

/*i*/.i_clk			(i_mipi_rx_pclk      ),
/*i*/.i_vs			(w_mipi_rx_vs	),
/*i*/.i_de			(w_mipi_rx_de & w_mipi_rx_hs & ~frz_de),   // 帧冻结：只掐数据，保留 vs
/*i*/.vin 			({w_mipi_rx_data[19:12],w_mipi_rx_data[9:2],w_mipi_rx_data[39:32],w_mipi_rx_data[29:22]}	),	// CSI 组序修复: RAW10 四个像素 P1..P4 按 {P2,P1,P4,P3} 拼(每段取[9:2]高8bit)
                     
/*i*/.o_clk			(vid_clk_dvi2),//(i_mipi_rx_pclk	),
/*i*/.o_hs    		(ch0_hs		),			
/*i*/.o_vs    		(ch0_vs		),			
/*i*/.o_de    		(ch0_de		),			
/*i*/.vout    		({ch0_g,ch0_b}	),//ch0_r,

/*i*/.H_FRONT_PORCH (HFP/2  		),//
/*i*/.H_SYNC 	 	    (HSP/2	 	),///2
/*i*/.H_VALID 	 	  (MAX_HRES/2     ),//		
/*i*/.H_BACK_PORCH	(HBP/2		),//		
/*i*/.V_FRONT_PORCH (VFP  		),//		
/*i*/.V_SYNC 	 	    (VSP 	 	),//		
/*i*/.V_VALID 	 	  (MAX_VRES     ),//		
/*i*/.V_BACK_PORCH	(VBP		),//		

       .awid			(s_axi_awid	),      
       .awaddr		(s_axi_awaddr	),
       .awlen			(s_axi_awlen	),
       .awsize		(s_axi_awsize	),
       .awburst		(s_axi_awburst),
       .awprot    (s_axi_awprot ),
       .awcache   (s_axi_awcache),
       .awlock		(s_axi_awlock	),
       .awvalid		(s_axi_awvalid),
       .awready		(s_axi_awready),

       .arid			(s_axi_arid	  ),
       .araddr		(s_axi_araddr	),
       .arlen			(s_axi_arlen	),
       .arsize		(s_axi_arsize	),
       .arburst 	(s_axi_arburst),

       .arprot    (s_axi_arprot ),
       .arcache   (s_axi_arcache),
       .arlock 		(s_axi_arlock	),
       .arvalid		(s_axi_arvalid),
       .arready		(s_axi_arready),

       .wdata			(s_axi_wdata	),
       .wstrb			(s_axi_wstrb	),
       .wlast			(s_axi_wlast	),
       .wvalid		(s_axi_wvalid	),
       .wready		(s_axi_wready	),


       .rid			  (s_axi_rid	),
       .rdata			(s_axi_rdata	),
       .rlast			(s_axi_rlast	),
       .rvalid 		(s_axi_rvalid	),
       .rready		(s_axi_rready	),
       .rresp			(s_axi_rresp	),

       .bid			  (s_axi_bid	),
       .bvalid		(s_axi_bvalid	),
       .bready	  (s_axi_bready	)
);


ddr3_top                 u_ddr3_top
(

.axi_clk                (core_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),  
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (w_arstn             ),      
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),       
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),    
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),     
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (s_axi_awsize      ),
.s_axi_awburst                  (s_axi_awburst     ),
.s_axi_awlock                   (s_axi_awlock      ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (4'h0              ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (s_axi_arlock      ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (4'h0              ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG       
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          ) 
);

//***************************************************************************
// debayer
//***************************************************************************


wire        rgb_vs;
wire        rgb_hs;
wire        rgb_de;
wire        rgb_valid;
wire [47:0] rgb_datax2;
wire [15:0] r_gain;
wire [15:0] g_gain;
wire [15:0] b_gain;

debayer_top_2to1 debayer_top
(
	.in_pclk		  (vid_clk_dvi2),//(i_mipi_rx_pclk ),
	.in_rstn		  (vid_rst_n	),
	
	.raw_vs_i		  (ch0_vs		      ),
	.raw_hs_i		  (ch0_hs		      ),
	.raw_de_i		  (ch0_de		      ),
	.raw_valid_i	(ch0_de	        ),
	.raw_datax4_i	({ch0_b,ch0_g}	),
	.r_gain       (|r_gain? r_gain:255 ),
  .g_gain       (|g_gain? g_gain:255 ),
  .b_gain       (|b_gain? b_gain:255 ),
	.rgb_vs_o		  (rgb_vs         ),
	.rgb_hs_o		  (rgb_hs         ),
	.rgb_de_o		  (rgb_de         ),
	.rgb_valid_o	(rgb_valid      ),
	.rgb_datax2_o (rgb_datax2     )//b,g,r,b,g,r
);

//==============================================================================
// Sobel 边缘检测（取自厂家 20_Ti60F225_Sobel_Edge_Demo 的 rtl/edge/）
//   输入：debayer 输出 rgb_vs/rgb_hs/rgb_de/rgb_valid/rgb_datax2（2 像素/时钟）
//   输出：edge_* 同格式，接到 HDMI(DVI) 发送通路
//   阈值：i_key0_n(GPIOL_07) +64 / i_key1_n(GPIOL_03) -64，低有效，带 20ms 消抖
//   分屏：SPLIT_PAIR = MAX_HRES/4 → 左右各半(单位:像素对, 480对=960像素)（左半原图 / 右半边缘），便于对比
//==============================================================================
wire        edge_threshold_add;
wire        edge_threshold_sub;
reg  [11:0] edge_threshold_next;
reg  [11:0] edge_threshold_r;

key_autorepeat #(
  .CLK_HZ      (100_000_000),
  .DEBOUNCE_MS (20),
  .HOLD_MS     (400),
  .REPEAT_MS   (80)
)
edge_threshold_add_ar (
  .i_clk   (core_clk),
  .i_rst_n (w_arstn),
  .i_key_n (i_key0_n),
  .o_press (edge_threshold_add)
);

key_autorepeat #(
  .CLK_HZ      (100_000_000),
  .DEBOUNCE_MS (20),
  .HOLD_MS     (400),
  .REPEAT_MS   (80)
)
edge_threshold_sub_ar (
  .i_clk   (core_clk),
  .i_rst_n (w_arstn),
  .i_key_n (i_key1_n),
  .o_press (edge_threshold_sub)
);

always @(*) begin
  edge_threshold_next = edge_threshold_r;
  if (edge_threshold_add && !edge_threshold_sub) begin
    if (edge_threshold_r > (EDGE_THRESHOLD_MAX - EDGE_THRESHOLD_STEP))
      edge_threshold_next = EDGE_THRESHOLD_MAX;
    else
      edge_threshold_next = edge_threshold_r + EDGE_THRESHOLD_STEP;
  end else if (edge_threshold_sub && !edge_threshold_add) begin
    if (edge_threshold_r < (EDGE_THRESHOLD_MIN + EDGE_THRESHOLD_STEP))
      edge_threshold_next = EDGE_THRESHOLD_MIN;      // 下限 32，不再降到 0
    else
      edge_threshold_next = edge_threshold_r - EDGE_THRESHOLD_STEP;
  end
end

always @( posedge core_clk or negedge w_arstn ) begin
  if( !w_arstn )
    edge_threshold_r <= EDGE_THRESHOLD;
  else
    edge_threshold_r <= edge_threshold_next;
end

wire        edge_vs;
wire        edge_hs;
wire        edge_de;
wire        edge_valid;
wire [47:0] edge_datax2;

//==============================================================================
// 3x3 八邻域拉普拉斯锐化（插在 Sobel 之前）
//   rgb_datax2 = {b,g,r,b,g,r} → 两个灰度 → 3x3 锐化 → 灰度复制三通道打包
//   窗口滞后 2 个像素对，de/hs/vs/valid 同步延迟 2 拍与数据对齐
//==============================================================================
localparam integer SHARP_K = 0;      // 0=不锐化 4=+50% 8=+100%  ← 临时二分测试

// 灰度计算：必须用显式 16 位中间量！
// 若直接写成 wire [7:0] g = (77*r + 150*g + 29*b) >> 8; 表达式上下文会被压到 8 位，
// 乘积溢出回绕、右移 8 位后恒为 0（曾导致 {g,g,g} 送入 edge 模块后完全没有边缘）
wire [15:0] shp_sum0 = 8'd77*rgb_datax2[7:0]   + 8'd150*rgb_datax2[15:8]  + 8'd29*rgb_datax2[23:16];
wire [15:0] shp_sum1 = 8'd77*rgb_datax2[31:24] + 8'd150*rgb_datax2[39:32] + 8'd29*rgb_datax2[47:40];
wire [7:0]  shp_g0   = shp_sum0[15:8];
wire [7:0]  shp_g1   = shp_sum1[15:8];

reg  [9:0] shp_x;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )
    shp_x <= 10'd0;
  else if( !rgb_de )
    shp_x <= 10'd0;
  else if( shp_x == 10'd959 )
    shp_x <= 10'd0;
  else
    shp_x <= shp_x + 10'd1;
end

// 行号计数器：3x3 窗口的行缓存 bank 轮换依赖它（bank = row % 3）
// 之前接常数 0 会导致只写 bank0、而读 bank1/bank2（从未写过=0），
// 上面两行恒为 0 → Lap8 正向饱和成纯白 → Sobel 无梯度 → 边缘全无
reg  [11:0] shp_row;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )
    shp_row <= 12'd0;
  else if( rgb_vs )                       // vsync 高有效 → 帧起始清零
    shp_row <= 12'd0;
  else if( rgb_de && (shp_x == 10'd959) )
    shp_row <= shp_row + 12'd1;
end

wire        shp_de;
wire [9:0]  shp_x_o;
wire [11:0] shp_row_o;
wire [15:0] shp_gray;
wire [47:0] shp_rgb;

laplacian_sharpen_2px #(
  .H_PAIRS (MAX_HRES/2),
  .ADDR_W  (10),
  .SHARP_K (SHARP_K)
) u_sharpen3x3 (
  .clk    (vid_clk_dvi2),
  .rst_n  (vid_rst_n),
  .i_de   (rgb_de),
  .i_x    (shp_x),
  .i_row  (shp_row),
  .i_gray ({shp_g1, shp_g0}),
  .i_rgb  (rgb_datax2),
  .o_de   (shp_de),
  .o_x    (shp_x_o),
  .o_row  (shp_row_o),
  .o_gray (shp_gray),
  .o_rgb  (shp_rgb)
);

// 时序信号延迟 2 拍（与 3x3 窗口的数据滞后对齐）
reg shp_de1, shp_de2, shp_hs1, shp_hs2, shp_vs1, shp_vs2, shp_va1, shp_va2;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin
    shp_de1 <= 1'b0; shp_de2 <= 1'b0;
    shp_hs1 <= 1'b0; shp_hs2 <= 1'b0;
    shp_vs1 <= 1'b0; shp_vs2 <= 1'b0;
    shp_va1 <= 1'b0; shp_va2 <= 1'b0;
  end else begin
    shp_de1 <= rgb_de;    shp_de2 <= shp_de1;
    shp_hs1 <= rgb_hs;    shp_hs2 <= shp_hs1;
    shp_vs1 <= rgb_vs;    shp_vs2 <= shp_vs1;
    shp_va1 <= rgb_valid; shp_va2 <= shp_va1;
  end
end

// 灰度复制到三通道；打包顺序与 rgb_datax2 一致（高 24 位 = 第二个像素）
wire [47:0] shp_rgbx2 = { shp_gray[15:8], shp_gray[15:8], shp_gray[15:8],
                          shp_gray[7:0],  shp_gray[7:0],  shp_gray[7:0] };

// ---------------------------------------------------------------------------
// 锐化旁路开关（二分定位用）
//   1 = 完全不经过锐化，edge 模块直接吃 debayer 原始数据（= 加锐化之前的状态）
//   0 = 走锐化
// ---------------------------------------------------------------------------
localparam SHARP_BYPASS = 1'b1;

// T1 单点实验：绕开锐化，直接把原始灰度复制到三通道喂给 edge 模块
//   目的：验证 {g,g,g} 这条路本身是否通
//   若边缘出现 → 问题在锐化模块；若仍无 → 问题在灰度/打包路径
localparam GRAY_ONLY = 1'b1;

// ---------------------------------------------------------------------------
// 3x3 中值滤波（灰度域，Sobel 之前；赛题高阶第 1 项：抑制椒盐噪声）
//   MEDIAN_ON = 1 启用；= 0 完全旁路（回到当前状态）
//   模块内部已完成 de/hs/vs/valid 的 2 拍延迟对齐，直接使用其输出时序
// ---------------------------------------------------------------------------
localparam MEDIAN_ON = 1'b1;

wire        med_de, med_hs, med_vs, med_va;
wire [7:0]  med_g0, med_g1;

median3x3_2px u_median3x3 (
  .clk    (vid_clk_dvi2),
  .rst_n  (vid_rst_n),
  .i_de   (rgb_de),
  .i_hs   (rgb_hs),
  .i_vs   (rgb_vs),
  .i_valid(rgb_valid),
  .i_g0   (shp_g0),
  .i_g1   (shp_g1),
  .o_de   (med_de),
  .o_hs   (med_hs),
  .o_vs   (med_vs),
  .o_valid(med_va),
  .o_g0   (med_g0),
  .o_g1   (med_g1)
);

//==============================================================================
// 形状识别（赛题高阶第 6 项）· 阶段二最小可演示版：圆 / 矩 / 未知
//   数据源：中值滤波输出 med_*（与边缘检测链路并列旁路，不改 Canny 任何环节）
//   统计在 vid 域逐帧完成，类别经 2FF 同步到 hdmi 域后用几何符号显示
//   已知限制：不做 CCL → 画面多目标时统计成并集，多半判「未知」；形状须为实心
//==============================================================================
wire [2:0] shp_cls_vid;
wire       shp_cls_upd;
wire [10:0] shp_bx0, shp_bx1, shp_by0, shp_by1;
wire        shp_box_en;
wire [3:0]  shp_best_idx;
wire [13:0] shp_best_cnt;

shape_recog #(
  .H_PAIRS  (MAX_HRES/2),      // 960 像素对/行 = 1920 像素
  .V_LINES  (MAX_VRES),        // 1080 行
  .TY       (8'd170),          // 白底阈值：Y < TY 判为目标（T1 上移到参数表）
  .THAM     (256),             // 模板汉明距离门限
  .TMPL_MIN (32),              // 模板 bbox 最小边
  .CELL_W   (480),             // 4×4 网格格宽（T1 参数化）
  .CELL_H   (270),             // 4×4 网格格高
  .A_MIN    (10),              // 面积下限（采样数）；真正的尺寸下限是 CELL_MIN=150（圆/方≈50~55px，三角/十字≳80px）
  .A_MAX    (60000),
  .BOX_ON_ANY (0),             // 0 = 只有识别成立才画框（演示语义）
  .WIN_EN   (0)                // 关闭网格窗口（会裁掉 >960x540 的目标）
) u_shape_recog (
  .clk   (vid_clk_dvi2),
  .rst_n (vid_rst_n),
  .i_de  (med_de),
  .i_vs  (med_vs),
  .i_g0  (med_g0),
  .i_g1  (med_g1),
  .o_cls (shp_cls_vid),
  .o_upd (shp_cls_upd),
  .o_bx0 (shp_bx0),
  .o_bx1 (shp_bx1),
  .o_by0 (shp_by0),
  .o_by1 (shp_by1),
  .o_box_en (shp_box_en),
  .o_best_idx (shp_best_idx),
  .o_best_cnt (shp_best_cnt)
);

wire low_zone_t = (edge_threshold_r <= 12'd16);

//==============================================================================
// rgb_vs 是"5 行电平"，不是单拍脉冲 —— 所有"每帧一次"的逻辑必须用它的上升沿
//   rgb_vs 由 frame_buffer/data_tx 的 o_vs <= (v_state == S_V_SYNC) 产生，
//   VSP = 5 → 高电平持续 5 行（约 5500 拍）。把它直接当 enable 会有三个后果：
//     hold_frm  在 vs 高电平期间每拍 +1 → 48 拍（0.65us）就翻转，"长按 0.8s" 完全失效
//     auto_step 在 vs 期间每 6 拍来一次   → replay_idx 一帧内自增几百次，"10fps" 乱转
//     rp_arm    2 拍就到 2               → 写侧还没写完当前帧就切了读 bank
//==============================================================================
reg rgb_vs_d;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) rgb_vs_d <= 1'b0;
  else             rgb_vs_d <= rgb_vs;
end
wire rgb_vs_rise = rgb_vs & ~rgb_vs_d;

// ---- 帧冻结：双键同按持续 48 帧（≈800ms）才翻转，避免抖动反复触发 ----
wire both_key = ~i_key0_n & ~i_key1_n;
reg  bk_d;
reg  [7:0] hold_frm;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin bk_d <= 1'b0; hold_frm <= 8'd0; end
  else begin
    bk_d <= both_key;
    if( !both_key )                               hold_frm <= 8'd0;
    else if( rgb_vs_rise && hold_frm != 8'd255 )  hold_frm <= hold_frm + 8'd1;
  end
end
// 判 47 而不是 48：触发这一拍 hold_frm 还是 47（本拍才 +1），
// 即"第 48 个帧沿"翻转 → 48 × 16.674ms ≈ 0.80s
wire frz_tog = (hold_frm == 8'd47) && rgb_vs_rise;

always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )      freeze_on <= 1'b0;
  else if( frz_tog )    freeze_on <= ~freeze_on;
end

// ---- DDR 帧回放：KEY2(GPIOR_21) 步进，只在冻结时有效，0..2 循环 ----
//   KEY2 直接在 vid 域消抖（key_debounce 内部含 2FF 同步 + 20ms 稳定判据），
//   输出单拍脉冲，与 freeze_on 同域，无需再做跨时钟处理
wire key2_press;
key_debounce #(
  .CLK_HZ      (74_250_000),
  .DEBOUNCE_MS (20)
) u_key2_debounce (
  .i_clk   (vid_clk_dvi2),
  .i_rst_n (vid_rst_n),
  .i_key_n (i_key2_n),
  .o_press (key2_press)
);

reg [1:0] replay_idx;

// ---- DDR 帧回放：KEY1(GPIOR_22) 自动回放开关（只在冻结时有效） ----
//   KEY1 消抖后做 T 触发器：按一下开、再按一下停在当前帧；解冻自动清零
wire auto_press;
key_debounce #(
  .CLK_HZ      (74_250_000),
  .DEBOUNCE_MS (20)
) u_auto_debounce (
  .i_clk   (vid_clk_dvi2),
  .i_rst_n (vid_rst_n),
  .i_key_n (i_auto_n),
  .o_press (auto_press)
);

reg auto_play;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )       auto_play <= 1'b0;
  else if( !freeze_on )  auto_play <= 1'b0;                 // 非冻结 → 自动回放关闭
  else if( auto_press )  auto_play <= ~auto_play;
end

// 自动回放分频：每 PLAY_DIV 个输出帧（rgb_vs_rise）推进一帧
//   rgb_vs ≈ 60Hz → PLAY_DIV=6 约 10fps；想要约 5fps 可改 12
localparam [7:0] PLAY_DIV = 8'd6;
reg  [7:0] play_cnt;
wire       play_vs   = rgb_vs_rise;    // 每帧只放行一次（原为 vs 电平 → 每帧几百次）
wire       play_tick = (play_cnt == (PLAY_DIV - 8'd1));
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )                    play_cnt <= 8'd0;
  else if( !freeze_on || !auto_play ) play_cnt <= 8'd0;     // 退出自动回放 → 分频相位复位
  else if( play_vs )                  play_cnt <= play_tick ? 8'd0 : play_cnt + 8'd1;
end
wire auto_step = auto_play && freeze_on && play_vs && play_tick;

always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )       replay_idx <= 2'd0;
  else if( !freeze_on )  replay_idx <= 2'd0;                            // 非冻结 → 索引归零
  else if( key2_press || auto_step )                                    // 手动步进 / 自动步进并存
                         replay_idx <= (replay_idx == 2'd2) ? 2'd0 : replay_idx + 2'd1;
end

//==============================================================================
// 检测框位置补偿的按键实时微调（2026-10 新增）
//
//   板上 4 个键全部已占用，没有真正空闲的键：
//     KEY0/KEY3 = 边缘阈值 ±64（长按连发），且两键同按 0.8s 是冻结开关；
//     KEY1/KEY2 = 冻结态的自动回放开关 / 回放帧步进。
//   因此只能复用"只在冻结态才有效"的 KEY1/KEY2，用 freeze_on 做功能分时：
//     非冻结态（实时画面，正是调框的时候）：
//       KEY2 短按 → osd_xoff_r += 2（62 → 0 回绕，0..63 偶数序列）
//       KEY1 短按 → osd_yoff_r += 1（31 → 0 回绕）
//       KEY1 + KEY2 同按 → 恢复默认 22 / 3
//     冻结态：KEY1/KEY2 保持原语义（自动回放 / 回放步进），补偿量不变
//   三个 press 都由 key_debounce 产生（2FF 同步 + 20ms 稳定判据，单拍脉冲）。
//==============================================================================
// "两键同按"的合成键：两个输入都是低有效，
//   任一键释放 → 1；只有两键都按下 → 0。
//   所以是"相或"，不能写成相与（相与会在单键按下时就出 both 脉冲 → 每次单按都复位）
wire adj_both_key_n = i_key2_n | i_auto_n;
wire adj_both_press;    // KEY1+KEY2 同按（低有效相或，当作第 3 个虚拟键）
key_debounce #(
  .CLK_HZ      (74_250_000),
  .DEBOUNCE_MS (20)
) u_adj_both_debounce (
  .i_clk   (vid_clk_dvi2),
  .i_rst_n (vid_rst_n),
  .i_key_n (adj_both_key_n),
  .o_press (adj_both_press)
);

reg [5:0] osd_xoff_r;   // 0..63，默认 0（实测对齐值）
reg [4:0] osd_yoff_r;   // 0..31，默认 0（实测对齐值）

always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin
    osd_xoff_r <= 6'd0;
    osd_yoff_r <= 5'd0;
  end else if( !freeze_on ) begin
    // 同按优先：两键同按时"后按下的那个"的 press 与 both 同拍，
    // 让 both 分支优先，保证最终值一定是默认值（不会残留 +2/+1）
    if( adj_both_press ) begin
      osd_xoff_r <= 6'd0;
      osd_yoff_r <= 5'd0;
    end else if( key2_press ) begin
      osd_xoff_r <= 6'd0;   // 调节功能已移除
    end else if( auto_press ) begin
      osd_yoff_r <= 5'd0;   // 调节功能已移除
    end
  end
end

// ---- DDR 帧回放：读侧 bank 强制通道 ----
//   冻结瞬间写侧仍要把"当前帧"写完（frz_de 只在 vs 沿更新），所以等 2 个 rgb_vs 之后
//   三个 bank 才都是完整帧，这时才允许切读 bank，避免读到一个正在写的 bank。
reg [1:0] rp_arm;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n )                            rp_arm <= 2'd0;
  else if( !freeze_on )                       rp_arm <= 2'd0;
  else if( rgb_vs_rise && (rp_arm != 2'd2) )  rp_arm <= rp_arm + 2'd1;
end
wire replay_en = freeze_on && (rp_arm == 2'd2);

// 同步到 core_clk（= axi_clk，DDR 读侧）域：两个信号都是按键级慢变量，2FF 足够
//   （rp_en_s1/rp_en_s2/rp_idx_s1/rp_idx_s2 已在 frame_buffer 之前声明）
always @( posedge core_clk or negedge w_arstn ) begin
  if( !w_arstn ) begin
    rp_en_s1  <= 1'b0; rp_en_s2  <= 1'b0;
    rp_idx_s1 <= 2'd0; rp_idx_s2 <= 2'd0;
  end else begin
    rp_en_s1  <= replay_en;   rp_en_s2  <= rp_en_s1;
    rp_idx_s1 <= replay_idx;  rp_idx_s2 <= rp_idx_s1;
  end
end
// 原始灰度（中值前）打 2 拍，与中值输出对齐，供辅路使用
reg [15:0] graw_d1, graw_d2;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin graw_d1 <= 16'd0; graw_d2 <= 16'd0; end
  else begin graw_d1 <= {shp_g1, shp_g0}; graw_d2 <= graw_d1; end
end
wire [7:0] f_g0 = low_zone_t ? graw_d2[7:0] : (MEDIAN_ON ? med_g0 : shp_g0);   // 细节模式旁路中值(用对齐2拍后的原始灰度)
wire [7:0] f_g1 = low_zone_t ? graw_d2[15:8] : (MEDIAN_ON ? med_g1 : shp_g1);
wire       f_vs = MEDIAN_ON ? med_vs : rgb_vs;
wire       f_hs = MEDIAN_ON ? med_hs : rgb_hs;
wire       f_de = MEDIAN_ON ? med_de : rgb_de;
wire       f_va = MEDIAN_ON ? med_va : rgb_valid;

wire [47:0] gray_rgbx2 = { f_g1, f_g1, f_g1,
                           f_g0, f_g0, f_g0 };

wire [47:0] edge_in_rgbx2 = GRAY_ONLY    ? gray_rgbx2 :
                            SHARP_BYPASS ? rgb_datax2  : shp_rgbx2;
wire        edge_in_vs    = GRAY_ONLY    ? f_vs        :
                            SHARP_BYPASS ? rgb_vs      : shp_vs2;
wire        edge_in_hs    = GRAY_ONLY    ? f_hs        :
                            SHARP_BYPASS ? rgb_hs      : shp_hs2;
wire        edge_in_de    = GRAY_ONLY    ? f_de        :
                            SHARP_BYPASS ? rgb_de      : shp_de2;
wire        edge_in_va    = GRAY_ONLY    ? f_va        :
                            SHARP_BYPASS ? rgb_valid   : shp_va2;


/* 厂家 edge_pipeline_2px 例化已停用（回退时取消注释即可，模块文件保留）
edge_pipeline_2px #(
  .H_ACTIVE       (MAX_HRES),
  .SPLIT_PAIR     (MAX_HRES/4),
  .EDGE_THRESHOLD (EDGE_THRESHOLD)
)
edge_pipeline_inst (
  .i_clk          (vid_clk_dvi2),
  .i_rst_n        (vid_rst_n),
  .i_vs           (edge_in_vs),
  .i_hs           (edge_in_hs),
  .i_de           (edge_in_de),
  .i_valid        (edge_in_va),
  .i_rgbx2        (edge_in_rgbx2),
  .i_threshold    (edge_threshold_r),
  .i_display_mode (EDGE_DISPLAY_MODE),
  .o_vs           (edge_vs),
  .o_hs           (edge_hs),
  .o_de           (edge_de),
  .o_valid        (edge_valid),
  .o_rgbx2        (edge_datax2)
);
*/

//==============================================================================
// 边缘二值图 3x3 邻域计数去孤立点（MIN_NEI=2 → 邻居数 0/1 均清除）
//   输入：edge 模块输出，取两个像素 r 通道的 LSB（edge_datax2[24] / [0]）
//   输出：清理后的边缘复制到三通道，替换原 edge_datax2
//==============================================================================
//==============================================================================
// 拉普拉斯零交叉边缘（二阶算子，作为 Sobel 的补充/替代观察）
//   LAPLACE_MODE = 1 → 右侧边缘改用拉普拉斯零交叉结果；= 0 → 仍用 Sobel
//   输入用与 edge 模块相同的灰度（f_g0/f_g1）与时序（edge_in_*）
//==============================================================================
localparam LAPLACE_MODE = 1'b1;

//==============================================================================
// 3x3 高斯带限滤波（仅作用于拉普拉斯支路，Sobel 通路不变）
//   核 [1 2 1; 2 4 2; 1 2 1] / 16，纯移位加法
//==============================================================================
wire        gau_de, gau_hs, gau_vs;
wire [7:0]  gau_g0, gau_g1;

gauss3x3_2px #(
  .H_PAIRS (MAX_HRES/2),
  .ADDR_W  (10)
) u_gauss3x3 (
  .clk   (vid_clk_dvi2),
  .rst_n (vid_rst_n),
  .i_de  (f_de),
  .i_hs  (f_hs),
  .i_vs  (f_vs),
  .i_g0  (f_g0),
  .i_g1  (f_g1),
  .o_de  (gau_de),
  .o_hs  (gau_hs),
  .o_vs  (gau_vs),
  .o_g0  (gau_g0),
  .o_g1  (gau_g1)
);

wire        lap_de, lap_hs, lap_vs;
wire        lap_e0, lap_e1;

laplace_edge_2px #(
  .H_PAIRS (MAX_HRES/2),
  .ADDR_W  (10)
) u_laplace_edge (
  .clk        (vid_clk_dvi2),
  .rst_n      (vid_rst_n),
  .i_de       (gau_de),
  .i_hs       (gau_hs),
  .i_vs       (gau_vs),
  .i_g0       (gau_g0),
  .i_g1       (gau_g1),
  .i_threshold(edge_threshold_r),
  .o_de       (lap_de),
  .o_hs       (lap_hs),
  .o_vs       (lap_vs),
  .o_e0       (lap_e0),
  .o_e1       (lap_e1)
);

wire [47:0] lap_rgbx2 = { {8{lap_e1}}, {8{lap_e1}}, {8{lap_e1}},
                          {8{lap_e0}}, {8{lap_e0}}, {8{lap_e0}} };

//==============================================================================
// 自研边缘检测引擎 E1：Gauss + Sobel + Laplacian + 一致性门控
//   EDGE_ENGINE = 2 自研引擎 / 1 拉普拉斯零交叉 / 0 厂家（需恢复上面的例化）
//==============================================================================
localparam EDGE_ENGINE = 2;
localparam integer T2_SHIFT = 2;      // T2 = T1 >> T2_SHIFT

reg  [47:0] rgb_in_d1, rgb_in_d2;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin rgb_in_d1 <= 48'd0; rgb_in_d2 <= 48'd0; end
  else begin rgb_in_d1 <= rgb_datax2; rgb_in_d2 <= rgb_in_d1; end
end
wire [47:0] rgb_in_al = rgb_in_d2;

wire       cny_de, cny_hs, cny_vs;
wire [15:0] osd_eng;
wire [15:0] bg_eng;
wire [47:0] rgb_eng;
wire [1:0] cny_e;
wire [1:0] cny_eso;      // 通路A：直连 Sobel + 阈值（与 cny_e 同拍）
//------------------------------------------------------------------------------
// 亚像素抗锯齿（AA）：edge 模块输出每像素 2 bit 等级 {pix1,pix0}
//   2 = 全强度（原红边）/ 1 = 半强度 / 0 = 不画
//   EDGE_AA_ON = 1 → 右半红边按等级着色（0xFF / 0x80 / 0x00）
//   EDGE_AA_ON = 0 → 回退成原来的二值红边（0xFF / 0x00），其它逻辑不变
//------------------------------------------------------------------------------
localparam EDGE_AA_ON = 1'b1;
wire [3:0]  cny_aa;
wire [15:0] cny_mag;

//==============================================================================
// 双通路边缘架构（B3 基础项 + A4 高档项）
//   通路A：中值灰度 → 直连 Sobel → |Gx|+|Gy| → 阈值          → cny_eso（朴素、厚边）
//   通路B：中值灰度 → 2 级高斯 → Scharr → C1 → NMS → 滞后 → AA → cny_e（细化、抗锯齿）
//   两条通路在 edge_canny_2px 内部已经严格同拍（差值 0 拍），
//   顶层只做二选一，不需要额外补延迟，o_de/o_hs/o_vs 两路共用。
//
//   EDGE_PATH = 1 → 通路B（Scharr+Canny，A4 高档项，默认）
//   EDGE_PATH = 0 → 通路A（直连 Sobel 阈值，B3 基础项）
//   ★ 运行期切换：把 localparam 改成 reg（例如接按键 debounce 出来的
//     edge_path_r），并把下面 path_e / edint0 / edint1 的 `EDGE_PATH == 0`
//     换成该 reg 即可；代价是两套门控同时存在（A 路约 +1 个 Sobel 的面积）。
//   EDGE_GRAD_SEL = 通路B 的梯度算子：1 = Scharr（默认，A4），0 = Sobel（回退）
//==============================================================================
localparam integer EDGE_PATH     = 1;
localparam integer EDGE_GRAD_SEL = 1;
// 逐帧直方图自动阈值（2026-10-27）：1 = 用 auto_thr_2px 统计的上一帧阈值；
// 0 = 只用按键阈值 edge_threshold_r（EDGE_THRESHOLD=56 仍是手动/保底值）。
localparam integer EDGE_AUTO_THR = 1;

edge_canny_2px #(
  .H_PAIRS  (MAX_HRES/2),
  .ADDR_W   (10),
  .T2_SHIFT (T2_SHIFT),
  .HYST_SHIFT (4),         // 滞后：T_lo = T_hi >> 4（F29 基线）
  .AA_ON    (EDGE_AA_ON),
  .GRAD_SEL (EDGE_GRAD_SEL),   // 通路B：0 = Sobel / 1 = Scharr
  .GAUSS_BYPASS (0),           // 1 = 通路B 也跳过高斯（对比实验用，默认 0）
  .LOCAL_T_ON (1'b0),          // 0 = 用全局自动阈值直接判决（配合 AUTO_THR=1，匹配仿真口径）
  .AUTO_THR (EDGE_AUTO_THR)    // 1 = 逐帧直方图自动阈值（上一帧统计）
) u_edge_canny (
  .clk        (vid_clk_dvi2),
  .rst_n      (vid_rst_n),
  .i_de       (f_de),
  .i_hs       (f_hs),
  .i_vs       (f_vs),
  .i_g0       (f_g0),
  .i_g1       (f_g1),
  .i_threshold(edge_threshold_r),
  .o_de       (cny_de),
  .o_hs       (cny_hs),
  .o_vs       (cny_vs),
  .o_e        (cny_e),
  .o_e_sobel  (cny_eso),
  .o_aa       (cny_aa),
  .o_osd      (osd_eng),
  .o_bg       (bg_eng),
  .o_rgb      (rgb_eng),
  .i_rgb      (rgb_in_al)
);

// ---- 亚像素 OSD：延迟 2 拍对齐 despeckle 输出，再按 vid_cnt 拆像素 ----
//   vid_cnt 的赋值逻辑在本段之后，这里先声明（满足 iverilog 的"先声明后使用"）
reg vid_cnt = 'd0;
reg [15:0] osd_d1, osd_d2;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin osd_d1 <= 16'd0; osd_d2 <= 16'd0; end
  else begin osd_d1 <= osd_eng; osd_d2 <= osd_d1; end
end
wire [7:0] osd_px = vid_cnt ? osd_d2[7:0] : osd_d2[15:8];
wire [47:0] cny_rgbx2 = { {8{cny_e[1]}}, {8{cny_e[1]}}, {8{cny_e[1]}},
                          {8{cny_e[0]}}, {8{cny_e[0]}}, {8{cny_e[0]}} };
wire        sel_de   = (EDGE_ENGINE == 1) ? lap_de   : cny_de;
wire        sel_hs   = (EDGE_ENGINE == 1) ? lap_hs   : cny_hs;
wire        sel_vs   = (EDGE_ENGINE == 1) ? lap_vs   : cny_vs;
wire [47:0] sel_rgbx2 = (EDGE_ENGINE == 1) ? lap_rgbx2 : cny_rgbx2;

// ---- 双通路二选一：送进 despeckle 的二值边缘 ----
//   EDGE_PATH=0 → 通路A（直连 Sobel 阈值，纯二值，不含 NMS/滞后/亚像素）
//   EDGE_PATH=1 → 通路B（Scharr+Canny，现有链路）
//   两条通路同拍（edge_canny_2px 内部已对齐，差 0 拍），所以 de/hs/vs 两路共用。
//   注：通路A 仍经过顶层这个共享的 1 像素去斑（MIN_NEI=1，只清彻底孤立的单点，
//       不会把厚边削薄）——它是显示级清理，不属于边缘算法本身。
wire [1:0] path_e = (EDGE_PATH == 0) ? cny_eso : {sel_rgbx2[24], sel_rgbx2[0]};

localparam integer DESPECKLE_MIN = 1;   // 邻居数 ≥1 即保留，只清彻底孤立的单点（原 2）
// 1px 缺口桥接：BSDS300 实测 Connectivity +107%（T=300）/ +213%（T=56），FOM +2.8%，
//   纯组合逻辑 +~20 LUT、0 RAM、0 拍（相位不变，o_de/o_aa 与原设计同拍）。
//   因果窗限制见 despeckle_2px.v 文件头；BRIDGE_ON=0 可逐位回退。
localparam integer EDGE_BRIDGE_ON = 1;

wire        dsp_de, dsp_hs, dsp_vs;
wire [1:0]  dsp_e;

despeckle_2px #(
  .H_PAIRS (MAX_HRES/2),
  .ADDR_W  (10),
  .MIN_NEI (DESPECKLE_MIN),
  .BRIDGE_ON (EDGE_BRIDGE_ON)
) u_despeckle (
  .clk   (vid_clk_dvi2),
  .rst_n (vid_rst_n),
  .i_de  (sel_de),
  .i_hs  (sel_hs),
  .i_vs  (sel_vs),
  .i_e   (path_e),
  .o_de  (dsp_de),
  .o_hs  (dsp_hs),
  .o_vs  (dsp_vs),
  .o_e   (dsp_e)
);

wire [47:0] dsp_rgbx2 = { {8{dsp_e[1]}}, {8{dsp_e[1]}}, {8{dsp_e[1]}},
                          {8{dsp_e[0]}}, {8{dsp_e[0]}}, {8{dsp_e[0]}} };

//==============================================================================
// AA 等级 → 红色强度（只作用于右半点阵缓存 comp_edge_mem）
//   拍数：edge 的 o_aa 比 o_e 晚 1 拍；despeckle 输出比 cny_e 晚 2 拍
//         ⇒ o_aa 再打 1 拍就与 dsp_e 同相（同一像素）
//   等级 2 必须通过 despeckle（孤立单点仍被清掉），半强度等级直接保留
//   强度：2 → 0xFF（原红边）/ 1 → 0x80（半强度，视觉上台阶变柔和）/ 0 → 0x00
//   存储仍是 comp_edge_mem 的 8 bit（0/0x80/0xFF），不新增 RAM
//==============================================================================
reg [3:0] aa_d1;
always @( posedge vid_clk_dvi2 or negedge vid_rst_n ) begin
  if( !vid_rst_n ) aa_d1 <= 4'd0;
  else             aa_d1 <= cny_aa;
end

wire [1:0] aa_lv0 = (aa_d1[1:0] == 2'd2) ? (dsp_e[0] ? 2'd2 : 2'd0) : aa_d1[1:0];
wire [1:0] aa_lv1 = (aa_d1[3:2] == 2'd2) ? (dsp_e[1] ? 2'd2 : 2'd0) : aa_d1[3:2];
wire [7:0] mag0 = cny_mag[15:8];   // 像素0 幅值
wire [7:0] mag1 = cny_mag[7:0];    // 像素1 幅值
wire [7:0] aa_int0 = (aa_lv0 == 2'd2) ? ((mag0 < 8'd160) ? 8'd160 : mag0)
                                     : ((aa_lv0 == 2'd1) ? ((mag0 < 8'd160) ? 8'd80 : (mag0 >> 1)) : 8'h00);
wire [7:0] aa_int1 = (aa_lv1 == 2'd2) ? ((mag1 < 8'd160) ? 8'd160 : mag1)
                                     : ((aa_lv1 == 2'd1) ? ((mag1 < 8'd160) ? 8'd80 : (mag1 >> 1)) : 8'h00);
// 回退：EDGE_AA_ON=0（或 EDGE_ENGINE≠2 没有等级可用）→ 原二值红边
// 通路A（EDGE_PATH=0）没有亚像素等级，直接按 dsp_e 二值着色（0xFF/0x00）
wire [7:0] edge_int0 = ((EDGE_PATH == 0) || !((EDGE_ENGINE == 2) && EDGE_AA_ON))
                       ? {8{dsp_e[0]}} : aa_int0;
wire [7:0] edge_int1 = ((EDGE_PATH == 0) || !((EDGE_ENGINE == 2) && EDGE_AA_ON))
                       ? {8{dsp_e[1]}} : aa_int1;

// 与 hdmi_tx_rdata 同拍（同一条 always 的同一个采样沿），只供合成器右半使用，
// 不改动上面 hdmi_tx_rdata/gdata/bdata 那条（gamma/直显）通路
reg [7:0] comp_edge_int_r;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) comp_edge_int_r <= 8'd0;
  else             comp_edge_int_r <= vid_cnt ? edge_int0 : edge_int1;
end

reg rgb_vs_r = 'd0;
always @( posedge hdmi_tx_slow_clk )
begin
  rgb_vs_r <= dsp_vs;
end
assign pos_vs = {rgb_vs_r,dsp_vs} == 2'b01;
reg [7:0] hdmi_tx_rdata ;
reg [7:0] hdmi_tx_gdata ;
reg [7:0] hdmi_tx_bdata ;
reg hdmi_tx_vs;
reg hdmi_tx_hs;
reg hdmi_tx_de;
always @( posedge hdmi_tx_slow_clk )
begin
    if( pos_vs )
      vid_cnt <= 1'b1;
    else if( dsp_de )
      vid_cnt <= ~vid_cnt ;

    if( vid_cnt )
      {hdmi_tx_bdata,hdmi_tx_gdata,hdmi_tx_rdata} <= {dsp_rgbx2[23:8], dsp_rgbx2[7:0]};
    else 
      {hdmi_tx_bdata,hdmi_tx_gdata,hdmi_tx_rdata} <= {dsp_rgbx2[47:32], dsp_rgbx2[31:24]};

  hdmi_tx_vs <= dsp_vs;
  hdmi_tx_hs <= dsp_hs;
  hdmi_tx_de <= dsp_de;
end
//==============================================================================
// 分屏合成器（赛题要求）：左半 = 原始灰度全图(横向 2:1)，右半 = 边缘全图(横向 2:1)
//   行缓存 4 个 bank（灰度 2 + 边缘 2）乒乓，合成成 BRAM（约 8 个 RAM10）
//   写：hdmi_tx_de 期间按行内像素坐标 0..1919 写入「当前行」的 bank
//   读：同一 de 期间读「另一个 bank 的上一行」，x<960 取 gray[2x]，
//       x>=960 取 edge[2*(x-960)]
//   bank 在行结束（de 下降沿）翻转，保证整行写入同一 bank
//   BRAM 同步读有 1 拍延迟 → 输出 de/hs/vs 同延 1 拍与数据对齐
//==============================================================================
// 行缓存：单数组 + bank 位做高位地址（深度 4096 = 2 bank × 2048），同步读
// 原写法是 4 个 1919 深数组 + 两级数组选择，综合器把它拆进了 LUT/FF；
// 改成"单数组 + 2 的幂深度 + 同步读"才能推断成 BRAM
reg  [7:0] comp_gray_mem [0:4095];
reg  [7:0] comp_edge_mem [0:4095];
reg [23:0] comp_rgb_mem  [0:4095];

reg        comp_line_par = 1'b0;      // 行奇偶 → 当前写入 bank
reg        comp_de_prev  = 1'b0;
reg [10:0] comp_x        = 11'd0;     // 行内像素坐标 0..1919

// 原始像素：沿用 vid_cnt 的 2→1 选择方式；rgb_datax2 = {b,g,r,b,g,r}
reg [7:0] comp_orig_r = 8'd0;
reg [7:0] comp_orig_g = 8'd0;
reg [7:0] comp_orig_b = 8'd0;
always @( posedge hdmi_tx_slow_clk )
begin
  if( vid_cnt )
    {comp_orig_b,comp_orig_g,comp_orig_r} <= rgb_datax2[23:0];
  else
    {comp_orig_b,comp_orig_g,comp_orig_r} <= rgb_datax2[47:24];
end

reg  [7:0]  comp_gray_pix_r;
reg [23:0]  comp_rgb_pix;
wire [7:0]  comp_gray_pix = comp_gray_pix_r;   // 与边缘同相的对齐灰度
wire [7:0]  comp_edge_pix = comp_edge_int_r;        // AA 等级强度（0/0x80/0xFF），与 comp_gray_pix 同拍

//------------------------------------------------------------------------------
// 白平衡（WBT，仅作用于显示通路）
//   现象：整个屏幕偏蓝 —— 摄像头白平衡偏冷，实测白纸 RGB=(206,226,250)
//   增益：R×1.23 / G×1.12 / B×1.00（Q8）。检测用的灰度 f_g0/f_g1 在此路之外，不受影响
//   WB_ON=0 可一键关闭
//------------------------------------------------------------------------------
localparam integer WB_ON = 1;
localparam integer WB_RG = 315;   // Q8: 1.230
localparam integer WB_GG = 287;   // Q8: 1.121
localparam integer WB_BG = 256;   // Q8: 1.000
// SWAP_RB：源端 R/B 是否与 debayer 打包约定相反（CFA 相位接反时置 1）
//   1 → 认为 rgb_eng 的 [23:16] 才是 R、[7:0] 是 B
localparam integer SWAP_RB = 1;

wire [7:0]  rb_r = SWAP_RB ? rgb_eng[23:16] : rgb_eng[7:0];
wire [7:0]  rb_b = SWAP_RB ? rgb_eng[7:0]   : rgb_eng[23:16];
wire [7:0]  rb_r1= SWAP_RB ? rgb_eng[47:40] : rgb_eng[31:24];
wire [7:0]  rb_b1= SWAP_RB ? rgb_eng[31:24] : rgb_eng[47:40];

wire [15:0] wb_r0 = WB_ON ? ((({8'd0, rb_r } * WB_RG) >> 8)) : {8'd0, rb_r };
wire [15:0] wb_g0 = WB_ON ? ((({8'd0, rgb_eng[15:8]} * WB_GG) >> 8)) : {8'd0, rgb_eng[15:8]};
wire [15:0] wb_b0 = WB_ON ? ((({8'd0, rb_b } * WB_BG) >> 8)) : {8'd0, rb_b };
wire [15:0] wb_r1 = WB_ON ? ((({8'd0, rb_r1} * WB_RG) >> 8)) : {8'd0, rb_r1};
wire [15:0] wb_g1 = WB_ON ? ((({8'd0, rgb_eng[39:32]}* WB_GG) >> 8)) : {8'd0, rgb_eng[39:32]};
wire [15:0] wb_b1 = WB_ON ? ((({8'd0, rb_b1} * WB_BG) >> 8)) : {8'd0, rb_b1};

// ---- 白平衡后的有效像素锁存（原在 vid_cnt/hdmi_tx_* 的 always 里，挪到此处
//      只是因为 iverilog 要求先声明后使用；逻辑与拍数完全不变）----
always @( posedge hdmi_tx_slow_clk ) begin
  if( vid_cnt ) comp_gray_pix_r <= bg_eng[7:0];
  else          comp_gray_pix_r <= bg_eng[15:8];
  if( vid_cnt ) comp_rgb_pix <= { (wb_b0 > 16'd255) ? 8'd255 : wb_b0[7:0],
                                  (wb_g0 > 16'd255) ? 8'd255 : wb_g0[7:0],
                                  (wb_r0 > 16'd255) ? 8'd255 : wb_r0[7:0] };
  else          comp_rgb_pix <= { (wb_b1 > 16'd255) ? 8'd255 : wb_b1[7:0],
                                  (wb_g1 > 16'd255) ? 8'd255 : wb_g1[7:0],
                                  (wb_r1 > 16'd255) ? 8'd255 : wb_r1[7:0] };
end

always @( posedge hdmi_tx_slow_clk )
begin
  comp_de_prev <= hdmi_tx_de;
  if( !hdmi_tx_de )
    comp_x <= 11'd0;
  else
    comp_x <= comp_x + 11'd1;
  if( comp_de_prev && !hdmi_tx_de )                 // 行结束 → 乒乓切换
    comp_line_par <= ~comp_line_par;
end

// 写当前行：地址 = {bank, comp_x}，bank 位做高位
always @( posedge hdmi_tx_slow_clk )
begin
  if( hdmi_tx_de ) begin
    comp_gray_mem[{comp_line_par, comp_x}] <= comp_gray_pix;
    comp_edge_mem[{comp_line_par, comp_x}] <= comp_edge_pix;
    comp_rgb_mem [{comp_line_par, comp_x}] <= comp_rgb_pix;
  end
end

// 读地址：左半 2x（灰度），右半 2*(x-960)（边缘）
wire [10:0] comp_x_r = comp_x - 11'd960;
reg  [10:0] comp_rd_addr;
reg         comp_rd_edge;
reg         comp_rd_edge_d;   // 与 comp_data 对齐的"右半区(边缘)"标志
always @(*) begin
  // 1:1 中心裁剪（消除 2:1 横向拉伸）：两半都显示相机 x∈[480,1440)
  if( comp_x < 11'd960 ) begin
    comp_rd_addr = comp_x + 11'd480;
    comp_rd_edge = 1'b0;
  end else begin
    comp_rd_addr = comp_x - 11'd480;
    comp_rd_edge = 1'b1;
  end
end

// 同步读上一行（读 bank 与写 bank 相反）；两路各自读一次，保证每个数组都是
// "单写口 + 单读口 + 同步读"的 BRAM 结构，避免数组级选择把存储器拆成寄存器
reg [7:0] comp_gray_q;
reg [7:0] comp_edge_q;
reg [23:0] comp_rgb_q;
reg       comp_de_o;
reg       comp_hs_o;
reg       comp_vs_o;
always @( posedge hdmi_tx_slow_clk )
begin
  comp_de_o <= hdmi_tx_de;
  comp_hs_o <= hdmi_tx_hs;
  comp_vs_o <= hdmi_tx_vs;
  comp_rd_edge_d <= comp_rd_edge;
  comp_gray_q <= comp_gray_mem[{~comp_line_par, comp_rd_addr[10:0]}];
  comp_edge_q <= comp_edge_mem[{~comp_line_par, comp_rd_addr[10:0]}];
  comp_rgb_q  <= comp_rgb_mem [{~comp_line_par, comp_rd_addr[10:0]}];
end

// 同步读 1 拍之后再组合选择，总延迟与原逻辑相同（1 拍）
wire [7:0] comp_data = comp_rd_edge_d ? comp_edge_q : comp_gray_q;

// 输出着色：左半(灰度) 三通道相同 → 灰度；右半(边缘) 只亮红通道 → 红/黑
// ---------------------------------------------------------------------------
// 红色边缘叠加（赛题高阶第 5 项）
//   OVERLAY_ON = 1：右半 = 原始灰度 + 纯红边缘（有边缘 {FF,00,00}，无边缘 {gray,gray,gray}）
//   OVERLAY_ON = 0：右半 = 纯边缘（红/黑），即原显示方式
//   灰度直接复用行缓存里已有的 comp_gray_q，不新增存储
// ---------------------------------------------------------------------------
localparam OVERLAY_ON = 1'b1;

// P1-1 修复：comp_rgb_q 是 {b,g,r} 字节序（debayer_top_2to1.v:142
//   rgb_datax2_o = {b[15:8], g[15:8], r[15:8], b[7:0], g[7:0], r[7:0]}），
//   所以 [23:16]=b、[15:8]=g、[7:0]=r。原代码 ov_r 取 [23:16] 拿到蓝、
//   ov_b 取 [7:0] 拿到红，红/蓝通道互换。
// AA：comp_edge_q 现在是「红通道强度」而不是 1 bit 标志
//   （0xFF=全强度边缘 / 0x80=半强度过渡 / 0x00=无边缘→显示灰度底色）
//   EDGE_AA_ON=0 时取值只有 0x00/0xFF，与改前逐位一致
wire [7:0] ov_r = (comp_edge_q != 8'd0) ? comp_edge_q : comp_rgb_q[7:0];
wire [7:0] ov_g = (comp_edge_q != 8'd0) ? 8'h00 : comp_rgb_q[15:8];
wire [7:0] ov_b = (comp_edge_q != 8'd0) ? 8'h00 : comp_rgb_q[23:16];

// ---- 帧冻结 OSD 方块：左半 x 24..31 / y 8..15，冻结 0xFF / 实时 0xC0 ----
//   注意：原来的 fr_row 是"帧内像素计数"（只在 vs 清零，de 期间每个像素 +1），
//   它与逐行清零的 comp_x 在第 0 行完全同步，于是 (fr_row>=8&&<16) 与
//   (comp_x>=24&&<32) 永远不可能同时成立 → 方块实际从未显示。
//   这里换成真正的行号计数器 fr_y（de 下降沿 +1），y 条件才成立。
reg [11:0] fr_y;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n )                       fr_y <= 12'd0;
  else if( hdmi_tx_vs )                  fr_y <= 12'd0;
  else if( comp_de_prev && !hdmi_tx_de ) fr_y <= fr_y + 12'd1;   // 行结束 → 行号 +1
end
wire fr_ind = (fr_y >= 12'd8) && (fr_y < 12'd16) &&
              (comp_x >= 11'd24) && (comp_x < 11'd32);
wire [7:0] freeze_px = fr_ind ? (freeze_on ? 8'hFF : 8'hC0) : 8'd0;
// ---- 冻结帧计数 OSD：x 40..47 / y 8..15，亮度 = 计数低4位 <<4（0x00~0xF0）----
//   hdmi_tx_vs 同样是 5 行电平（dsp_vs 延迟），必须用上升沿计数，
//   否则 4bit 计数器在 5 行(≈9600 拍)里绕几百圈，方块亮度是一团噪声
reg hdmi_vs_d;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) hdmi_vs_d <= 1'b0;
  else             hdmi_vs_d <= hdmi_tx_vs;
end
wire hdmi_vs_rise = hdmi_tx_vs & ~hdmi_vs_d;
reg [3:0] frz_cnt;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n )         frz_cnt <= 4'd0;
  else if( !freeze_on )    frz_cnt <= 4'd0;
  else if( hdmi_vs_rise )  frz_cnt <= frz_cnt + 4'd1;
end
wire fc_ind = (fr_y >= 12'd8) && (fr_y < 12'd16) &&
              (comp_x >= 11'd40) && (comp_x < 11'd48);
wire [7:0] frz_px = fc_ind ? {frz_cnt, 4'b0000} : 8'd0;
// ---- 回放帧序号 OSD：x 56..63 / y 8..15 ----
//   注意：x 40..47 已被上面的冻结帧计数方块占用，故回放指示顺延到 56..63（与 24/40 等间距 16）
//   亮度 0x40 / 0x80 / 0xFF 分别表示当前回放 bank0 / bank1 / bank2，非冻结时全灭
reg [1:0] rp_idx_osd;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) rp_idx_osd <= 2'd0;
  else             rp_idx_osd <= replay_idx;     // 慢变信号，打一拍进 hdmi 域
end
wire rp_ind = (fr_y >= 12'd8) && (fr_y < 12'd16) &&
              (comp_x >= 11'd56) && (comp_x < 11'd64);
wire [7:0] rp_lvl = (rp_idx_osd == 2'd0) ? 8'h40 :
                    (rp_idx_osd == 2'd1) ? 8'h80 : 8'hFF;
wire [7:0] rp_px = (rp_ind && freeze_on) ? rp_lvl : 8'd0;
// ---- 自动回放 OSD：x 72..79 / y 8..15，自动回放中 0xFF，否则灭 ----
reg au_osd;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) au_osd <= 1'b0;
  else             au_osd <= auto_play;          // 慢变信号，打一拍进 hdmi 域
end
wire au_ind = (fr_y >= 12'd8) && (fr_y < 12'd16) &&
              (comp_x >= 11'd72) && (comp_x < 11'd80);
wire [7:0] au_px = au_ind ? (au_osd ? 8'hFF : 8'd0) : 8'd0;
// ---- 形状识别结果 OSD：左半 x 96..143 / y 8..55（48×48 几何符号）----
//   左上角 x 8..71 / y 18..61 同时显示补偿量读数（shape_adjust_osd），两者不重叠
//   类别跨域：vid 域 o_cls → 2FF 同步 → hdmi 域（shape_osd 内部在 vs 处锁存整帧）
reg [2:0] shp_s1, shp_s2;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin shp_s1 <= 3'd0; shp_s2 <= 3'd0; end
  else             begin shp_s1 <= shp_cls_vid; shp_s2 <= shp_s1; end
end
wire [2:0] shp_cls_sync = shp_s2;
wire [7:0] shape_px;

// bbox 跨域：{bx0,bx1,by0,by1} 打包 2FF 同步（帧锁存值，慢变）
wire [43:0] shp_box_v = {shp_bx0, shp_bx1, shp_by0, shp_by1};
reg  [43:0] box_s1, box_s2;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin box_s1 <= 44'd0; box_s2 <= 44'd0; end
  else             begin box_s1 <= shp_box_v; box_s2 <= box_s1; end
end
wire [10:0] bxo0 = box_s2[43:33];
wire [10:0] bxo1 = box_s2[32:22];
wire [10:0] byo0 = box_s2[21:11];
wire [10:0] byo1 = box_s2[10:0];
wire [7:0]  box_px;

// box_en 跨域（2FF）
reg boxen_s1, boxen_s2;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin boxen_s1 <= 1'b0; boxen_s2 <= 1'b0; end
  else             begin boxen_s1 <= shp_box_en; boxen_s2 <= boxen_s1; end
end
wire box_en_sync = boxen_s2;

// 最佳格跨域（2FF，18 bit 打包）
wire [17:0] shp_grid_v = {shp_best_idx, shp_best_cnt};
reg  [17:0] grid_s1, grid_s2;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin grid_s1 <= 18'd0; grid_s2 <= 18'd0; end
  else             begin grid_s1 <= shp_grid_v; grid_s2 <= grid_s1; end
end
wire [3:0]  best_idx_sync = grid_s2[17:14];
wire [13:0] best_cnt_sync = grid_s2[13:0];
wire [7:0]  grid_px;

// ---- 补偿量跨域：{xoff[5:0], yoff[4:0]} 打包 2FF（只在按键时跳变，慢变信号）----
//   vid 域按键 → osd_xoff_r / osd_yoff_r → 这里同步进 hdmi 域，同时给
//   shape_osd（画框用）和 shape_adjust_osd（左上角数值显示用）
wire [10:0] adj_osd_v = {osd_xoff_r, osd_yoff_r};
reg  [10:0] adj_s1, adj_s2;
always @( posedge hdmi_tx_slow_clk or negedge vid_rst_n ) begin
  if( !vid_rst_n ) begin adj_s1 <= {6'd22, 5'd3}; adj_s2 <= {6'd22, 5'd3}; end
  else             begin adj_s1 <= adj_osd_v;      adj_s2 <= adj_s1;      end
end
wire [5:0] xoff_sync = adj_s2[10:5];
wire [4:0] yoff_sync = adj_s2[4:0];
wire [7:0] adj_px;
wire       adj_on;

// ---- 左上角数值读数 "X=22" / "Y= 3"（3×5 点阵，4× 放大，x 8..71 / y 18..61）----
//   起点从 y=8 下移到 y=18：y 8..15 已被 4 个状态方块（x 24..79）占用，不能压住
  // (shape_adjust_osd 已移除：X/Y 调节与文字 OSD 不再使用)

shape_osd #(
  .GRID_OSD (1'b0)             // 演示关闭网格虚线框（调试时改 1）
) u_shape_osd (
  .clk   (hdmi_tx_slow_clk),
  .rst_n (vid_rst_n),
  .i_vs  (hdmi_tx_vs),
  .i_x   (comp_x),
  .i_y   (fr_y),
  .i_cls (shp_cls_sync),
  .i_bx0 (bxo0),
  .i_bx1 (bxo1),
  .i_by0 (byo0),
  .i_by1 (byo1),
  .i_box_en (box_en_sync),
  .i_xoff (xoff_sync),
  .i_yoff (yoff_sync),
  .i_best_idx (best_idx_sync),
  .i_best_cnt (best_cnt_sync),
  .o_px  (shape_px),
  .o_box (box_px),
  .o_grid (grid_px)
);

wire [7:0] comp_o_b = comp_rd_edge_d ? (OVERLAY_ON ? ov_b : 8'd0)       : (comp_data | osd_px | freeze_px | frz_px | rp_px | au_px | shape_px | box_px | grid_px);
wire [7:0] comp_o_g = comp_rd_edge_d ? (OVERLAY_ON ? ov_g : 8'd0)       : (comp_data | osd_px | freeze_px | frz_px | rp_px | au_px | shape_px | box_px | grid_px);
wire [7:0] comp_o_r = comp_rd_edge_d ? (OVERLAY_ON ? ov_r : comp_data)  : (comp_data | osd_px | freeze_px | frz_px | rp_px | au_px | shape_px | box_px | grid_px);

//==============================================================================
// MIPI DSI
//==============================================================================
// signal 

reg		[25:0]	r_rst_cnt;

wire	[31:0]	w_axi_rdata;
wire			w_axi_awready;
wire			w_axi_wready;
wire			w_axi_arready;
wire			w_axi_rvalid;
wire			w_axi_bvalid;

wire	[6:0]	w_axi_awaddr;
wire			w_axi_awvalid;
wire	[31:0]	w_axi_wdata;
wire			w_axi_wvalid;
wire			w_axi_bready;
wire	[6:0]	w_axi_araddr;
wire			w_axi_arvalid;
wire			w_axi_rready;

wire			w_confdone;
assign w_confdone = 1'b1;

assign  LCD_POWER 			= i_arstn;
assign	LCD_RST_P	      = ~w_arstn;//~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复位
assign	mipi_dp_clk_RST		= ~i_arstn;
assign	mipi_dp_data0_RST	= ~i_arstn;
assign	mipi_dp_data1_RST	= ~i_arstn;
assign	mipi_dp_data2_RST	= ~i_arstn;
assign	mipi_dp_data3_RST	= ~i_arstn;
////////////////////////////////////////////////////////////////
always@(posedge i_mipi_clk or  negedge w_arstn )
begin
  if ( !w_arstn ) begin
    r_rst_cnt	<= 'd0;
  end else 		
    r_rst_cnt	<= r_rst_cnt[25] ? r_rst_cnt :r_rst_cnt + 1'b1;
end

wire axi_rst_n = r_rst_cnt[25];

reg [26:0] dly_cnt = 'd0;

always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else if( w_confdone )
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
  else 
    dly_cnt <= 'd0;
end 

assign vid_rst_n = dly_cnt[26];




wire hs;
wire vs;
wire de;
wire [7:0] rgb_r;
wire [7:0] rgb_g;
wire [7:0] rgb_b;
  
  // color_bar_rgb #(
  // .HS_POLORY 		(1'b1		),
  // .VS_POLORY 		(1'b1		),
  // .H_FRONT_PORCH 	(HFP		),///2
  // .H_SYNC 		(HSP		),//
  // .H_VALID 		(MAX_HRES	),//
  // .H_BACK_PORCH 	(HBP		),//
  // .V_FRONT_PORCH 	(VFP		),
  // .V_SYNC 		(VSP		),
  // .V_VALID 		(MAX_VRES	),
  // .V_BACK_PORCH 	(VBP		),
  // .TEST_MODE 		(2'd2)
  // )u_color_bar_rgb1(
  // /*i*/.clk	(vid_clk_dvi2),//(vid_clk),
  // /*i*/.rst_n	(vid_rst_n),
  // /*o*/.hs	(hs),
  // /*o*/.vs	(vs),
  // /*o*/.de	(de),
  // // /*O*/.h_cnt (h_cnt),
  // // /*O*/.v_cnt (v_cnt),
  // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分量
  // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分量
  // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分量
  
  // );

//=================================================================================
//hdmi tx ctrl 
//=================================================================================
wire                            video_hs;
wire                            video_vs;
wire                            video_de;
wire[7:0]                       video_r;
wire[7:0]                       video_g;
wire[7:0]                       video_b;

assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

// 	  color_bar color_bar_m0(
// 	.clk(hdmi_tx_slow_clk),
// 	.rst(~vid_rst_n),
// 	.hs(video_hs),
// 	.vs(video_vs),
// 	.de(video_de),
// 	.rgb_r(video_r),
// 	.rgb_g(video_g),
// 	.rgb_b(video_b)
// );

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk ;
wire [7:0] gamma_rdata ;
wire [7:0] gamma_gdata ;
wire [7:0] gamma_bdata ;
wire gamma_valid;
wire gamma_hs;
wire gamma_vs;
wire gamma_sel;

wire [7:0] con_rdata ;
wire [7:0] con_gdata ;
wire [7:0] con_bdata ;
wire con_de;
wire con_hs;
wire con_vs;
wire con_sel;

wire [7:0] BRIGHT_SIG    ;
wire CONTRAST_SIG_G;
wire CONTRAST_SIG_R;
wire [7:0] CONTRAST_G    ;
wire CONTRAST_SIG_B;
wire [7:0] BRIGHT        ;
wire [7:0] CONTRAST_R    ;


wire CONTRAST_B    ;


gamma_correction
#(
	.DATA_WIDTH		(8),
	.GAMMA_CURVE	("./rtl/gamma_conrrection/2P2.mem")
)
inst_gamma_correction
(
	.i_pclk		(hdmi_tx_slow_clk),
	.i_rstn		(vid_rst_n),
	
	.i_red		(hdmi_tx_rdata),//(con_rdata  ),//
	.i_green	(hdmi_tx_gdata),//(con_gdata  ),//
	.i_blue		(hdmi_tx_bdata),//(con_bdata  ),//
  .i_valid	(hdmi_tx_de   ),//(con_de     ),//
  .i_hs     (hdmi_tx_hs   ),//(con_hs     ),//
  .i_vs     (hdmi_tx_vs   ),//(con_vs     ),//
	.o_blue		(gamma_bdata		),
  .o_green	(gamma_gdata	  ),
	.o_red		(gamma_rdata		),
	.o_valid	(gamma_valid	  ),
  .o_hs     (gamma_hs       ),
  .o_vs     (gamma_vs       )
);

dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~vid_rst_n      ),// reset
	.i_bdata(comp_o_b),//(hdmi_tx_rdata ),//(video_b            ),//(bdata_in	),   //
	.i_gdata(comp_o_g),//(hdmi_tx_gdata ),//(video_g            ),//(gdata_in	),   //   
	.i_rdata(comp_o_r),//(hdmi_tx_bdata ),//(video_r            ),//(rdata_in	),   //   
  .i_de(comp_de_o),//(hdmi_tx_de    ),//(video_de           ),//(rx_de		  ),   //
	.i_hs(comp_hs_o),//(video_hs           ),//(rx_hsync	),   //   
	.i_vs(comp_vs_o),//(video_vs           ),//(rx_vsync	),   //  
	
  .video_format     (video_format), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (0),
	.audio_L			    (audio_L),
  .audio_R			    (audio_R),
  .audio_valid		  (audio_valid),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (148500),      //(20'h28488),//      
  .audio_sample_frequency (audio_samp_freq),    //(3'b000),// 
  .audio_word_length      ({audio_samp_word_len,audio_max_word_length}),//(4'b1011),//

	.tmds_data0    		(tmds_data0),
  .tmds_data1    		(tmds_data1),
  .tmds_data2    		(tmds_data2),
  .tmds_clk      	  (tmds_clk  )
);
assign tmds_tx_clk_TX_DATA   = ~tmds_clk;
assign tmds_tx_data0_TX_DATA = ~tmds_data0;
assign tmds_tx_data1_TX_DATA = ~tmds_data1;
assign tmds_tx_data2_TX_DATA = ~tmds_data2;

debug_edb_top debug_edb_top_inst (
    .bscan_CAPTURE      ( jtag_inst1_CAPTURE  ),
    .bscan_DRCK         ( jtag_inst1_DRCK     ),
    .bscan_RESET        ( jtag_inst1_RESET    ),
    .bscan_RUNTEST      ( jtag_inst1_RUNTEST  ),
    .bscan_SEL          ( jtag_inst1_SEL      ),
    .bscan_SHIFT        ( jtag_inst1_SHIFT    ),
    .bscan_TCK          ( jtag_inst1_TCK      ),
    .bscan_TDI          ( jtag_inst1_TDI      ),
    .bscan_TMS          ( jtag_inst1_TMS      ),
    .bscan_UPDATE       ( jtag_inst1_UPDATE   ),
    .bscan_TDO          ( jtag_inst1_TDO      ),
    .vio0_clk           ( vid_clk_dvi2        ),
    .vio0_r_gain        ( r_gain              ),
    .vio0_g_gain        ( g_gain              ),
    .vio0_b_gain        ( b_gain              ),

    .vio0_gamma_sel     (gamma_sel),
    .la0_clk            ( vid_clk_dvi2        ),
    .la0_ch0_g          ( ch0_g               ),
    .la0_ch0_b          ( ch0_b               ),
    .la0_ch0_de         ( ch0_de              ),
    .la0_cal_done       ( cal_done            )
);

endmodule
