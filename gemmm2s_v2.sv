`timescale 1 ns / 1 ps
`default_nettype none
/*

 This module presents a write-only AXI4 slace interface with two pages, a data page (page 0) and a control page (page 1).
 The data page base address (0x0000) is expected to be given as the memory buffer pointer in the buffer descriptors
 passed to the GEM hard ethernet MAC DMA core.  The GEM will DMA packets into the data page, sequentially (at least this
 is the observed behavior on the Zynq 7020), INCR, and this will forward the data out an AXI-Stream master.

 Separately, in the control page, the PS core embedded ARM driver/code is expected to write a 0x00000001 to the first
 register in the control page (0x1000) whenever the GEM interrupts the PS core driver with a DMA complete interrupt.

 The master stream interface will set TLAST alongside the TDATA whenever one of the following is true:
 1. the GEM starts to DMA a NEW packet by initiating a DMA from the base data address (0x0000) again. -OR-
 2. a DMA complete register write closes off the final packet in a sequence of packets.

 The module is organized as follows:

 AW address writes are fed into local logic to manage control register writes OR into an AXI address counter, if it's a data page
 write.

 W data writes are fed into local logic to manage control register writes (e.g. DMA complete) OR into the left side of a
 stream data join module (which merges two elastic data streams).

 The AXI address counter feeds into the module which tracks the address wraparounds and DMA complete interrupts to produce an
 elastic stream of TLAST and !TLAST, which should correspond 1:1 with the data beats.  This TLAST stream is fed into the right
 side of the stream data join module.

 The AXI-Stream master is driven by the output of the joined streams.

 */

module gemmm2s_v2 #(
   // Parameters of Axi Slave Bus Interface S00_AXI
   parameter integer C_AXI_ID_WIDTH = 1,
   localparam C_AXI_DATA_WIDTH = 32, // DO NOT CHANGE
   localparam C_AXI_ADDR_WIDTH = 13 // DO NOT CHANGE
   )
   (
    input wire logic                           clk,
    input wire logic                           reset,

    // Ports of Axi Slave Bus Interface S_AXI
    input wire logic [C_AXI_ID_WIDTH-1 : 0]    s_axi_awid,
    input wire logic [C_AXI_ADDR_WIDTH-1 : 0]  s_axi_awaddr,
    input wire logic [7 : 0]                   s_axi_awlen,
    input wire logic [2 : 0]                   s_axi_awsize,
    input wire logic [1 : 0]                   s_axi_awburst,
    input wire logic                           s_axi_awvalid,
    output wire logic                          s_axi_awready,

    input wire logic [C_AXI_DATA_WIDTH-1 : 0]  s_axi_wdata,
    input wire logic                           s_axi_wlast,
    input wire logic                           s_axi_wvalid,
    output wire logic                          s_axi_wready,

    output wire logic [C_AXI_ID_WIDTH-1 : 0]   s_axi_bid,
    output wire logic [1 : 0]                  s_axi_bresp,
    output wire logic                          s_axi_bvalid,
    input wire logic                           s_axi_bready,

    // Ports of Axi Stream Master Bus Interface M_AXIS
    output wire logic [C_AXI_DATA_WIDTH-1 : 0] m_axis_tdata,
    output wire logic                          m_axis_tlast,
    output wire logic                          m_axis_tvalid,
    input wire logic                           m_axis_tready
    // don't bother with tkeep for now
    );

    // TODO make this based on addr_width
    // data page is at 13'h0000
    // control page is at 13'h1000
    // we assume page size is 4096 bytes per AXI and we have two pages
    localparam ADDR_PAGE_BIT = 12;
    localparam DATA_PAGE = 1'b0;
    localparam DATA_BASE_ADDR = 12'h0000;
    localparam CONTROL_PAGE = 1'b1;
    localparam DMA_COMPLETE_REG = 12'h0000;
    localparam DMA_COMPLETE_MASK = 32'h00000001;

    parameter WADDR_INCR = C_AXI_DATA_WIDTH / 8;
    parameter AWSIZE_EXPECTED = 3'($clog2(C_AXI_DATA_WIDTH / 8));

    initial s_axi_awready = 1;

    // STATE REGISTERS, driven by transaction state machine
    logic                                 r_awready;
    logic                                 r_wready;
    logic [8:0]                           r_burst_size;
    logic [8:0]                           r_w_beat_count;
    logic [8:0]                           r_addr_count;
    logic                                 r_bvalid;

    initial begin
        r_awready = 1;
        r_wready = 0;
        r_bvalid = 0;

        r_burst_size = 0;
        r_w_beat_count = 0;
        r_addr_count = 0;

        r_id = 0;
        r_page = 0;
        r_page_addr = 0;
        r_awlen = 0;
        r_awsize = 0;
        r_awburst = 0;
    end

    // cached data from AW
    logic [C_AXI_ID_WIDTH-1:0]            r_id;
    logic                                 r_page;
    logic [C_AXI_ADDR_WIDTH-2:0]          r_page_addr;
    logic [7:0]                           r_awlen;
    logic [2:0]                           r_awsize;
    logic [1:0]                           r_awburst;

    always_ff @(posedge clk) begin
        if (s_axi_awvalid && s_axi_awready) begin
            r_id <= s_axi_awid;
            {r_page, r_page_addr} <= s_axi_awaddr;
            r_awlen <= s_axi_awlen;
            assert(s_axi_awsize == AWSIZE_EXPECTED); // must be full width
            r_awsize <= s_axi_awsize;
            assert(s_axi_awburst == 2'b01); // must be burst type INCR
            r_awburst <= s_axi_awburst;
            r_burst_size <= {1'b0,s_axi_awlen} + 1;

            // start write trans
            r_awready <= 0;
            r_wready <= 1;
            r_w_beat_count <= 0;
            r_bvalid <= 0;
        end else if (s_axi_wvalid && s_axi_wready) begin
            assert(r_awsize == AWSIZE_EXPECTED); // to use it
            assert(r_awburst == 2'b01); // to use it
            assert(r_burst_size == {1'b0,r_awlen} + 1);

            // end write trans
            r_wready <= !s_axi_wlast;
            if (s_axi_wlast) begin
                r_bvalid <= 1;
                s_axi_bid <= r_id;
                s_axi_bresp <= 2'b00; // okay
                assert(r_w_beat_count == r_burst_size - 1);
            end
            r_w_beat_count <= r_w_beat_count + 1;
            r_page_addr <= r_page_addr + WADDR_INCR[C_AXI_ADDR_WIDTH-2:0];
        end else if (!s_axi_awready) begin
            if (s_axi_bvalid && s_axi_bready) begin
                r_bvalid <= 0;
                r_awready <= 1;
            end
        end
        if (reset) begin
            // reset everything
            r_awready <= 1;
            r_wready <= 0;
            r_bvalid <= 0;

            r_burst_size  <= 0;
            r_w_beat_count <= 0;

            r_id <= 0;
            r_page <= 0;
            r_page_addr <= 0;
            r_awlen <= 0;
            r_awsize <= 0;
            r_awburst <= 0;
        end
    end

    // DMA Complete register, driven by W write to control page register
    logic                                 r_dma_complete;

    // set DMA complete on register write
    always_ff @(posedge clk) begin
        r_dma_complete <= 0;
        if (s_axi_wvalid && s_axi_wready)
          if (r_page == CONTROL_PAGE && r_page_addr == DMA_COMPLETE_REG && (|(s_axi_wdata & DMA_COMPLETE_MASK)))
            r_dma_complete <= 1;
        if (reset)
          r_dma_complete <= 0;
    end

    logic addr_counter_awready;
    logic addr_counter_awvalid;

    logic [C_AXI_ADDR_WIDTH-2:0] addr_counter_next_addr_data;
    logic                        addr_counter_next_addr_valid;
    logic                        addr_counter_next_addr_ready;

    logic                        addr_stall;
    logic                        calc_ready_for_addr;
    logic                        addr_valid_for_calc;

    // slow down the address calculator pipeline to wait for stalls on the wdata pipeline so
    // that the joiner right-side (addr-derived) buffers don't fill up if the wdata left-side
    // (wdata-derived) writer stalls
    always_comb
      addr_stall = r_burst_size > 0 && (r_addr_count < r_burst_size) && (r_addr_count >= r_w_beat_count);

    always_comb
      addr_counter_next_addr_ready = calc_ready_for_addr && !addr_stall;

    always_comb
      addr_valid_for_calc = addr_counter_next_addr_valid && !addr_stall;

    axi_addr_counter addr_counter
      (
       .clk(clk),
       .reset(reset),
       .i_awaddr(s_axi_awaddr[C_AXI_ADDR_WIDTH-2:0]),
       .i_awlen(s_axi_awlen),
       .i_awsize(s_axi_awsize),
       .i_awburst(s_axi_awburst),
       .i_awvalid(addr_counter_awvalid),
       .i_awready(addr_counter_awready),
       .o_next_addr_data(addr_counter_next_addr_data),
       .o_next_addr_valid(addr_counter_next_addr_valid),
       .o_next_addr_ready(addr_counter_next_addr_ready)
       );

    always_ff @(posedge clk)
      if (reset ||
          s_axi_awaddr[ADDR_PAGE_BIT] || // **
          (addr_counter_awvalid && addr_counter_awready))
        r_addr_count <= 0;
      else if (addr_counter_next_addr_valid && addr_counter_next_addr_ready)
        r_addr_count <= r_addr_count + 1;
      // ** we need to reset this on the same clock as r_burst_size is set
      // otherwise assertion will fail (which is why we can't use r_page,
      // which is one clock too late)

    always_comb
      // we only trigger the address counting for DATA writes
      addr_counter_awvalid = s_axi_awvalid && s_axi_awaddr[ADDR_PAGE_BIT] == DATA_PAGE;

    always_comb
      // the address ready requires the axi counter to be ready.
      s_axi_awready = r_awready && addr_counter_awready;

    logic                        tlast_calc_prev_beat_last;
    logic                        tlast_calc_prev_beat_last_valid;

    last_beat_calc #(C_AXI_ADDR_WIDTH-1, C_AXI_DATA_WIDTH, DATA_BASE_ADDR) tlast_calc
      (
       .clk(clk),
       .reset(reset),
       .i_addr_data(addr_counter_next_addr_data),
       .i_addr_valid(addr_valid_for_calc),
       .i_addr_ready(calc_ready_for_addr),
       .i_dma_complete(r_dma_complete),
       .o_prev_beat_last(tlast_calc_prev_beat_last),
       .o_prev_beat_last_valid(tlast_calc_prev_beat_last_valid)
       );

    // make sure both sides of addr <-> calc see the same beats
    always @(posedge clk)
      assert( (addr_counter_next_addr_valid && addr_counter_next_addr_ready) ==
              (addr_valid_for_calc && calc_ready_for_addr));

    logic                        joiner_wvalid;
    logic                        joiner_wready;
    // name for the unconnected ready wire from the joiner to the last_beat_calc which doesn't need ready
    logic                        joiner_tlast_ready;

    logic [C_AXI_DATA_WIDTH-1:0]   joined_tdata;
    logic                          joined_tlast;
    logic                          joined_valid;
    logic                          joined_ready;

    stream_join #(C_AXI_DATA_WIDTH, 1, 3) joiner
      (
       .clk(clk),
       .reset(reset),
       .i_left_valid(joiner_wvalid),
       .i_left_ready(joiner_wready),
       .i_left_data(s_axi_wdata),
       .i_right_valid(tlast_calc_prev_beat_last_valid),
       .i_right_ready(joiner_tlast_ready),
       .i_right_data(tlast_calc_prev_beat_last),
       .o_valid(joined_valid),
       .o_ready(joined_ready),
       .o_data({joined_tdata, joined_tlast})
       );

    // the right side of the joiner should always be ready
    always @(posedge clk)
      assert(joiner_tlast_ready);

    // connect the joined output to the master AXIS wires
    always_comb begin
        m_axis_tdata = joined_tdata;
        m_axis_tlast = joined_tlast;
        m_axis_tvalid = joined_valid;
        joined_ready = m_axis_tready;
    end

    always_comb
      // the data valid is demuxed to the joiner IFF the W is valid AND it's data page data
      joiner_wvalid = s_axi_wvalid && r_wready && (r_page == DATA_PAGE);

    always_comb
      // the data ready is muxed from either us handling it as a control page, or the joiner
      // being ready for a data page beat
      s_axi_wready = r_wready && (r_page == CONTROL_PAGE || joiner_wready);

    always_comb
      s_axi_bvalid = r_bvalid;

    logic [C_AXI_ADDR_WIDTH-2:0] implied_burst_span;
    logic [C_AXI_ADDR_WIDTH-2:0] available_burst_in_page;

    // assume expected AXI transaction details (always full-width, always INCR, whole addresses)
    always @(*) begin
        if (s_axi_awvalid) begin
            implied_burst_span = ((C_AXI_ADDR_WIDTH-1)'(s_axi_awlen)+1) * WADDR_INCR;
            available_burst_in_page = ({(C_AXI_ADDR_WIDTH-1){1'b1}} - s_axi_awaddr[C_AXI_ADDR_WIDTH-2:0]);

// TODO: FORMAL PROOFS OF gemmm2s_v2 ARE NOT WORKING YET
`ifdef GEMMM2SV2_FORMAL
            assume(s_axi_awsize == AWSIZE_EXPECTED);
            assume(s_axi_awburst == 2'b01); // must be burst type INCR
            assume(s_axi_awaddr % WADDR_INCR == 0);
            assume(implied_burst_span < available_burst_in_page);
`else
            assert(s_axi_awsize == AWSIZE_EXPECTED);
            assert(s_axi_awburst == 2'b01); // must be burst type INCR
            assert(s_axi_awaddr % WADDR_INCR == 0);
            assert(implied_burst_span < available_burst_in_page);
`endif
        end
    end

    // don't let the wdata and addr beat counters overflow
    always @(posedge clk) begin
`ifdef GEMMM2SV2_FORMAL
        assume(r_w_beat_count <= r_burst_size);
        assume(r_addr_count <= r_burst_size);
`else
        assert(r_w_beat_count <= r_burst_size);
        assert(r_addr_count <= r_burst_size);
`endif
    end

`ifdef FORMAL
    localparam PAST_VALID_FOR = 64;

    logic	[PAST_VALID_FOR:0] f_past_valid_sr;
    logic                          f_past_valid;

    initial f_past_valid_sr = 64'd0;

    always @(posedge clk) begin
        f_past_valid_sr[PAST_VALID_FOR:0] <= {f_past_valid_sr[PAST_VALID_FOR-1:0], 1'b1};
    end

    assign f_past_valid = f_past_valid_sr[0];

    // assume things start disabled
    initial begin
 `ifdef GEMMM2SV2_FORMAL
        assume(!s_axi_awvalid);
        assume(!s_axi_wvalid);
 `else
        assert(!s_axi_awvalid);
        assert(!s_axi_wvalid);
 `endif
        assert(!s_axi_bvalid);
        assert(!m_axis_tvalid);
    end

    // assume inputs are reset properly, assert outputs are reset properly
    always @(posedge clk) begin
        if (f_past_valid && $past(reset)) begin
 `ifdef GEMMM2SV2_FORMAL
            assume(!s_axi_awvalid);
            assume(!s_axi_wvalid);
 `else
            assert(!s_axi_awvalid);
            assert(!s_axi_wvalid);
 `endif
            assert(!s_axi_bvalid);
            assert(!m_axis_tvalid);
        end
    end

    // assume AW inputs are stable if stalled
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset) &&
            $past(s_axi_awvalid) && !$past(s_axi_awready)) begin
 `ifdef GEMMM2SV2_FORMAL
            assume($stable(s_axi_awid));
            assume($stable(s_axi_awaddr));
            assume($stable(s_axi_awlen));
            assume($stable(s_axi_awsize));
            assume($stable(s_axi_awburst));
            assume(s_axi_awvalid);
 `else
            assert($stable(s_axi_awid));
            assert($stable(s_axi_awaddr));
            assert($stable(s_axi_awlen));
            assert($stable(s_axi_awsize));
            assert($stable(s_axi_awburst));
            assert(s_axi_awvalid);
 `endif
        end
    end

    // assume W inputs are stable if stalled
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset) &&
            $past(s_axi_wvalid) && !$past(s_axi_wready)) begin
 `ifdef GEMMM2SV2_FORMAL
            assume($stable(s_axi_wdata));
            assume($stable(s_axi_wlast));
            assume(s_axi_wvalid);
 `else
            assert($stable(s_axi_wdata));
            assert($stable(s_axi_wlast));
            assert(s_axi_wvalid);
 `endif
        end
    end

    // assert B outputs are stable
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset) &&
            $past(s_axi_bvalid) && !$past(s_axi_bready))
          begin
              assert($stable(s_axi_bresp));
              assert($stable(s_axi_bid));
              assert(s_axi_bvalid);
          end
    end

    // assert T outputs are stable
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset) &&
            $past(m_axis_tvalid) && !$past(m_axis_tready))
          begin
              assert($stable(m_axis_tdata));
              assert($stable(m_axis_tlast));
              assert(m_axis_tvalid);
          end
    end

    // assert B outputs are correct
    always @(posedge clk)
      if (s_axi_bvalid) begin
	  assert(s_axi_bresp == 0);
          assert(s_axi_bid == r_id);
      end

    // assume master sets WLAST properly
    integer f_burst_size;
    integer f_w_beat_count;

    initial begin
        f_burst_size = 0;
        f_w_beat_count = 0;
    end

    always @(posedge clk) begin
        if (s_axi_awvalid && s_axi_awready) begin
            f_burst_size <= {1'b0, s_axi_awlen} + 1;
            f_w_beat_count <= 0;
        end else if (s_axi_wvalid && s_axi_wready) begin
            f_w_beat_count <= f_w_beat_count + 1;
        end
    end

    logic f_should_be_wlast;

    initial f_should_be_wlast = 0;

    always @(*)
      f_should_be_wlast = f_burst_size > 0 && f_w_beat_count == f_burst_size - 1;

    always @(posedge clk) begin
 `ifdef GEMMM2SV2_FORMAL
        assume(s_axi_wlast == f_should_be_wlast);
 `else
        assert(s_axi_wlast == f_should_be_wlast);
 `endif
    end

    // TRANSACTION DEPTH COUNTERS
    logic f_axi_awr_req, f_axi_wr_req, f_axi_wr_ack;
    initial begin
        f_axi_awr_req = 0;
        f_axi_wr_req = 0;
        f_axi_wr_ack = 0;
    end

    always_comb begin
        f_axi_awr_req = (s_axi_awvalid) && (s_axi_awready);
	f_axi_wr_req = (s_axi_wvalid) && (s_axi_wready);
	f_axi_wr_ack = (s_axi_bvalid) && (s_axi_bready);
    end

    localparam F_LGDEPTH = 4;

    logic [(F_LGDEPTH-1):0]	f_axi_awr_outstanding;
    logic [(F_LGDEPTH-1):0]     f_axi_wr_outstanding;

    initial begin
        f_axi_awr_outstanding = 0;
        f_axi_wr_outstanding = 0;
    end

    // Count outstanding AW channel requests
    always @(posedge clk) begin
	case({ (f_axi_awr_req), (f_axi_wr_ack) })
	  2'b10: f_axi_awr_outstanding <= f_axi_awr_outstanding + 1'b1;
	  2'b01: f_axi_awr_outstanding <= f_axi_awr_outstanding - 1'b1;
	  default: begin end
	endcase
      if (reset)
	f_axi_awr_outstanding <= 0;
    end

    // Count outstanding W channel requests
    always @(posedge clk) begin
	case({ (f_axi_wr_req), (f_axi_wr_ack) })
	  2'b10: f_axi_wr_outstanding <= f_axi_wr_outstanding + 1'b1;
	  2'b01: f_axi_wr_outstanding <= f_axi_wr_outstanding - 1'b1;
	  default: begin end
	endcase
      if (reset)
	f_axi_wr_outstanding <= 0;
    end

    // don't let the counters overflow
    always @(posedge clk) begin
        assert(f_axi_wr_outstanding < {(F_LGDEPTH){1'b1}});
        assert(f_axi_awr_outstanding < {(F_LGDEPTH){1'b1}});
    end

    always @(posedge clk) begin
	if (f_axi_awr_outstanding == { {(F_LGDEPTH-1){1'b1}}, 1'b0} )
	  assert(!s_axi_awready);

	if (f_axi_wr_outstanding == { {(F_LGDEPTH-1){1'b1}}, 1'b0} )
	  assert(!s_axi_wready);
    end

    // assert that acks only come after requests
    always @(posedge clk)
      if (s_axi_bvalid) begin
	  // No BVALID w/o an outstanding request
	  assert(f_axi_awr_outstanding > 0);
	  assert(f_axi_wr_outstanding  > 0);
      end

    // GEMMM2S SPECIFIC ASSERTIONS

    // assert dma_complete is ONLY and EXACTLY asserted on clocks following a successful set of LSB of the dma reg
    always @(posedge clk)
        if (f_past_valid)
          assert(r_dma_complete == (!$past(reset) &&
                                    $past(s_axi_wvalid) && $past(s_axi_wready) &&
                                    $past({r_page, r_page_addr}) == {CONTROL_PAGE, DMA_COMPLETE_REG} &&
                                    $past({s_axi_wdata & DMA_COMPLETE_MASK})));

    always @(posedge clk)
      cover(r_burst_size == 16 && r_w_beat_count == 16);

`endif

endmodule
`default_nettype wire
