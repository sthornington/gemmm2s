`timescale 1 ns / 1 ps
`default_nettype none

/*
 This wraps the module gemmmm2s_v2 in pure verilog for easy integration into the Vivado
 block diagram editor.  Signals have been capitalized to conform to Xilinx standards,
 the reset is converted to active-low per AXI specs, the inputs and outputs have been
 skid-buffered again to conform to AXI specs.  Some of these might be "over-registered"
 since the internal gemmm2s core registers some of them already, but that's a problem
 for another day.
 */

module gemmm2s_v2 #(
   parameter integer C_AXI_ID_WIDTH = 1,
   localparam C_AXI_DATA_WIDTH = 32, // DO NOT CHANGE
   localparam C_AXI_ADDR_WIDTH = 13 // DO NOT CHANGE
   )
   (
    input logic                           ACLK,
    input logic                           ARESETN,

    // Ports of Axi Slave Bus Interface S_AXI
    input logic [C_AXI_ID_WIDTH-1 : 0]    S_AXI_AWID,
    input logic [C_AXI_ADDR_WIDTH-1 : 0]  S_AXI_AWADDR,
    input logic [7 : 0]                   S_AXI_AWLEN,
    input logic [2 : 0]                   S_AXI_AWSIZE,
    input logic [1 : 0]                   S_AXI_AWBURST,
    input logic                           S_AXI_AWVALID,
    output logic                          S_AXI_AWREADY,

    input logic [C_AXI_DATA_WIDTH-1 : 0]  S_AXI_WDATA,
    input logic                           S_AXI_WLAST,
    input logic                           S_AXI_WVALID,
    output logic                          S_AXI_WREADY,

    output logic [C_AXI_ID_WIDTH-1 : 0]   S_AXI_BID,
    output logic [1 : 0]                  S_AXI_BRESP,
    output logic                          S_AXI_BVALID,
    input logic                           S_AXI_BREADY,

    // Ports of Axi Stream Master Bus Interface M_AXIS
    output logic [C_AXI_DATA_WIDTH-1 : 0] M_AXIS_TDATA,
    output logic                          M_AXIS_TLAST,
    output logic                          M_AXIS_TVALID,
    input logic                           M_AXIS_TREADY
    );

    localparam C_AXI_TOTAL_AW_WIDTH = C_AXI_ID_WIDTH +
                                      C_AXI_ADDR_WIDTH +
                                      8 + // AWLEN
                                      3 + // AWSIZE
                                      2; // AWBURST
    localparam C_AXI_TOTAL_W_WIDTH = C_AXI_DATA_WIDTH +
                                     1; // WLAST
    localparam C_AXI_TOTAL_B_WIDTH = C_AXI_ID_WIDTH +
                                     2; // BRESP
    localparam C_AXI_TOTAL_T_WIDTH = C_AXI_DATA_WIDTH +
                                     1; // TLAST

    logic                                 clk;
    logic                                 reset;

    always @(*)
      clk = ACLK;

    always @(*)
      reset = !ARESETN;

    logic [C_AXI_ID_WIDTH-1 : 0]          skid_awid;
    logic [C_AXI_ADDR_WIDTH-1 : 0]        skid_awaddr;
    logic [7 : 0]                         skid_awlen;
    logic [2 : 0]                         skid_awsize;
    logic [1 : 0]                         skid_awburst;
    logic                                 skid_awvalid;
    logic                                 skid_awready;

    // INBOUND skid of AW
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_AW_WIDTH)) awskid
      (.clk,
       .reset,
       .i_valid(S_AXI_AWVALID),
       .i_ready(S_AXI_AWREADY),
       .i_data({S_AXI_AWID, S_AXI_AWADDR, S_AXI_AWLEN, S_AXI_AWSIZE, S_AXI_AWBURST}),
       .o_valid(skid_awvalid),
       .o_ready(skid_awready),
       .o_data({skid_awid, skid_awaddr, skid_awlen, skid_awsize, skid_awburst}));

    logic [C_AXI_DATA_WIDTH-1 : 0]        skid_wdata;
    logic                                 skid_wlast;
    logic                                 skid_wvalid;
    logic                                 skid_wready;

    // INBOUND skid of W
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_W_WIDTH)) wskid
      (.clk,
       .reset,
       .i_valid(S_AXI_WVALID),
       .i_ready(S_AXI_WREADY),
       .i_data({S_AXI_WDATA, S_AXI_WLAST}),
       .o_valid(skid_wvalid),
       .o_ready(skid_wready),
       .o_data({skid_wdata, skid_wlast}));

    logic [C_AXI_ID_WIDTH-1 : 0]          skid_bid;
    logic [1 : 0]                         skid_bresp;
    logic                                 skid_bvalid;
    logic                                 skid_bready;

    // OUTBOUND skid of B
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_B_WIDTH)) bskid
      (.clk,
       .reset,
       .i_valid(skid_bvalid),
       .i_ready(skid_bready),
       .i_data({skid_bid, skid_bresp}),
       .o_valid(S_AXI_BVALID),
       .o_ready(S_AXI_BREADY),
       .o_data({S_AXI_BID, S_AXI_BRESP}));

    logic [C_AXI_DATA_WIDTH-1 : 0]        skid_tdata;
    logic                                 skid_tlast;
    logic                                 skid_tvalid;
    logic                                 skid_tready;

    // OUTBOUND skid of T
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_T_WIDTH)) tskid
      (.clk,
       .reset,
       .i_valid(skid_tvalid),
       .i_ready(skid_tready),
       .i_data({skid_tdata, skid_tlast}),
       .o_valid(M_AXIS_TVALID),
       .o_ready(M_AXIS_TREADY),
       .o_data({M_AXIS_TDATA, M_AXIS_TLAST}));

    // TODO: I guess this is when it would be nice to have interfaces and modports
    gemmm2s_v2 #(.C_AXI_ID_WIDTH) gemmm2s
      (.clk,
       .reset,
       .s_axi_awid(skid_awid),
       .s_axi_awaddr(skid_awaddr),
       .s_axi_awlen(skid_awlen),
       .s_axi_awsize(skid_awsize),
       .s_axi_awburst(skid_awburst),
       .s_axi_awvalid(skid_awvalid),
       .s_axi_awready(skid_awready),
       .s_axi_wdata(skid_wdata),
       .s_axi_wlast(skid_wlast),
       .s_axi_wvalid(skid_wvalid),
       .s_axi_wready(skid_wready),
       .s_axi_bid(skid_bid),
       .s_axi_bresp(skid_bresp),
       .s_axi_bvalid(skid_bvalid),
       .s_axi_bready(skid_bready),
       .m_axis_tdata(skid_tdata),
       .m_axis_tlast(skid_tlast),
       .m_axis_tvalid(skid_tvalid),
       .m_axis_tready(skid_tready));

endmodule
