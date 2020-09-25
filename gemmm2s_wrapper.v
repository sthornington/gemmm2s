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

module gemmm2s_wrapper #(
   parameter integer C_AXI_ID_WIDTH = 1,
   localparam C_AXI_DATA_WIDTH = 32, // DO NOT CHANGE
   localparam C_AXI_ADDR_WIDTH = 13 // DO NOT CHANGE
   )
   (
    input wire                           ACLK,
    input wire                           ARESETN,

    // Ports of Axi Slave Bus Interface S_AXI
    input wire [C_AXI_ID_WIDTH-1 : 0]    S_AXI_AWID,
    input wire [C_AXI_ADDR_WIDTH-1 : 0]  S_AXI_AWADDR,
    input wire [7 : 0]                   S_AXI_AWLEN,
    input wire [2 : 0]                   S_AXI_AWSIZE,
    input wire [1 : 0]                   S_AXI_AWBURST,
    input wire                           S_AXI_AWVALID,
    output wire                          S_AXI_AWREADY,

    input wire [C_AXI_DATA_WIDTH-1 : 0]  S_AXI_WDATA,
    input wire                           S_AXI_WLAST,
    input wire                           S_AXI_WVALID,
    output wire                          S_AXI_WREADY,

    output wire [C_AXI_ID_WIDTH-1 : 0]   S_AXI_BID,
    output wire [1 : 0]                  S_AXI_BRESP,
    output wire                          S_AXI_BVALID,
    input wire                           S_AXI_BREADY,

    // Ports of Axi Stream Master Bus Interface M_AXIS
    output wire [C_AXI_DATA_WIDTH-1 : 0] M_AXIS_TDATA,
    output wire                          M_AXIS_TLAST,
    output wire                          M_AXIS_TVALID,
    input wire                           M_AXIS_TREADY
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

    reg                                 clk;
    reg                                 reset;

    always @(*)
      clk = ACLK;

    always @(*)
      reset = !ARESETN;

    wire [C_AXI_ID_WIDTH-1 : 0]          skid_awid;
    wire [C_AXI_ADDR_WIDTH-1 : 0]        skid_awaddr;
    wire [7 : 0]                         skid_awlen;
    wire [2 : 0]                         skid_awsize;
    wire [1 : 0]                         skid_awburst;
    wire                                 skid_awvalid;
    wire                                 skid_awready;

    // TODO: inbound skids could be half-skids?  (i.e. the data lines
    // probably need not be registered)

    // INBOUND skid of AW
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_AW_WIDTH)) awskid
      (.clk(clk),
       .reset(reset),
       .i_valid(S_AXI_AWVALID),
       .i_ready(S_AXI_AWREADY),
       .i_data({S_AXI_AWID, S_AXI_AWADDR, S_AXI_AWLEN, S_AXI_AWSIZE, S_AXI_AWBURST}),
       .o_valid(skid_awvalid),
       .o_ready(skid_awready),
       .o_data({skid_awid, skid_awaddr, skid_awlen, skid_awsize, skid_awburst}));

    wire [C_AXI_DATA_WIDTH-1 : 0]        skid_wdata;
    wire                                 skid_wlast;
    wire                                 skid_wvalid;
    wire                                 skid_wready;

    // INBOUND skid of W
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_W_WIDTH)) wskid
      (.clk(clk),
       .reset(reset),
       .i_valid(S_AXI_WVALID),
       .i_ready(S_AXI_WREADY),
       .i_data({S_AXI_WDATA, S_AXI_WLAST}),
       .o_valid(skid_wvalid),
       .o_ready(skid_wready),
       .o_data({skid_wdata, skid_wlast}));

    wire [C_AXI_ID_WIDTH-1 : 0]          skid_bid;
    wire [1 : 0]                         skid_bresp;
    wire                                 skid_bvalid;
    wire                                 skid_bready;

    // OUTBOUND skid of B
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_B_WIDTH)) bskid
      (.clk(clk),
       .reset(reset),
       .i_valid(skid_bvalid),
       .i_ready(skid_bready),
       .i_data({skid_bid, skid_bresp}),
       .o_valid(S_AXI_BVALID),
       .o_ready(S_AXI_BREADY),
       .o_data({S_AXI_BID, S_AXI_BRESP}));

    wire [C_AXI_DATA_WIDTH-1 : 0]        skid_tdata;
    wire                                 skid_tlast;
    wire                                 skid_tvalid;
    wire                                 skid_tready;

    // OUTBOUND skid of T
    skid_buffer #(.WORD_WIDTH(C_AXI_TOTAL_T_WIDTH)) tskid
      (.clk(clk),
       .reset(reset),
       .i_valid(skid_tvalid),
       .i_ready(skid_tready),
       .i_data({skid_tdata, skid_tlast}),
       .o_valid(M_AXIS_TVALID),
       .o_ready(M_AXIS_TREADY),
       .o_data({M_AXIS_TDATA, M_AXIS_TLAST}));

    // TODO: I guess this is when it would be nice to have interfaces and modports
    gemmm2s_v2 #(.C_AXI_ID_WIDTH(C_AXI_ID_WIDTH)) gemmm2s
      (.clk(clk),
       .reset(reset),
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
`default_nettype wire
