`timescale 1 ns / 1 ps
`default_nettype none

/*
 This wraps the module gemmmm2s_v2 in pure verilog for easy integration into the Vivado
 block diagram editor.  Signals have been capitalized to conform to Xilinx standards,
 the reset is converted to active-low per AXI specs, etc.
 */

module gemmm2s_v2 #(
   // Parameters of Axi Slave Bus Interface S00_AXI
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
    // don't bother with tkeep for now
    );


endmodule
