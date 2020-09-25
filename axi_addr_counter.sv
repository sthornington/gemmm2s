`timescale 1 ns / 1 ps
`default_nettype none

/*

 This takes an AXI4 burst transaction on the AW channel and spits out a
 backpressurable sequence of the individual addresses of each beat, which can
 be separately correlated with the data beats.

 This DOESN'T initially support any burst mode other than INCR, nor beat size other than
 DATA_WIDTH.

 Basically, snap the awaddr and awlen, keep adding clog2(DATA_WIDTH) aka awsize
 to it outputting the numbers.

  */
module axi_addr_counter #(
   localparam ADDR_WIDTH = 12, // DO NOT CHANGE
   localparam DATA_WIDTH = 32, // DO NOT CHANGE
   localparam SIZE_WIDTH = 3
   )
   (
    input logic                   clk,
    input logic                   reset,

    // AXI AW Lines
    input logic [ADDR_WIDTH-1:0]  i_awaddr,
    input logic [7:0]             i_awlen,
    input logic [2:0]             i_awsize,
    input logic [1:0]             i_awburst,
    input logic                   i_awvalid,
    output logic                  i_awready,

    output logic [ADDR_WIDTH-1:0] o_next_addr_data,
    output logic                  o_next_addr_valid,
    input logic                   o_next_addr_ready
    );
    // we cut some corners and assume that all bus transactions will be
    // for the max width of the bus
    localparam ADDR_INCR = ADDR_WIDTH'(DATA_WIDTH / 8);
    localparam AWSIZE_EXPECTED = SIZE_WIDTH'($clog2(DATA_WIDTH / 8));

    // registered state
    logic [8:0]                 burst_length;
    logic [8:0]                 burst_count;

    initial begin
        burst_length = 0;
        burst_count = 0;
    end

    logic in_burst;
    initial in_burst = 1'b0;

    always_comb
      in_burst = burst_count < burst_length;

    // we are ready for a transaction whenever this counter is done
    // and we have room downstream
    always_comb
      i_awready = o_next_addr_ready && !in_burst;

    // we have an address to deliver
    always_comb
      o_next_addr_valid = in_burst;

    always_ff @(posedge clk) begin
        if (i_awvalid && i_awready) begin
            // new incoming transaction
            // reset counters, load first address
            // NOTE: o_next_addr_valid will be set on the NEXT
            // clock once the burst counters have flopped,
            // With some more logic we could save a clock in between
            // bursts if we cared to.
            burst_count <= 0;
            burst_length <= {1'b0,i_awlen} + 1;
            o_next_addr_data <= i_awaddr;
        end else if (o_next_addr_valid && o_next_addr_ready) begin
            // prep following address
            burst_count <= burst_count + 1;
            burst_length <= burst_length; // is this necessary
            o_next_addr_data <= o_next_addr_data + ADDR_INCR;
        end

        if (reset) begin
            burst_count <= 0;
            burst_length <= 0;
            o_next_addr_data <= 0;
        end
    end

    always @(*)
        assert(burst_length <= 256);

    always @(*)
        assert(burst_count <= 256);

    always @(*)
      if (o_next_addr_valid)
        assert(o_next_addr_data % ADDR_INCR == 0);

    logic [ADDR_WIDTH-1:0] implied_burst_span;

    // assume the other axi fields are consistent with what we expect
    always @(*) begin
        if (i_awvalid) begin
            implied_burst_span = (ADDR_WIDTH'(i_awlen) + 1) * ADDR_INCR;
`ifdef AXIADDRCOUNTER_FORMAL
            // must be INCR burst
            assume(i_awburst == 2'b01);
            // must be full width
            assume(i_awsize == AWSIZE_EXPECTED);
            // must be aligned addresses
            assume(i_awaddr % ADDR_INCR == 0);
            // burst cannot wrap 4096 page boundary
            assume(implied_burst_span < ({ADDR_WIDTH{1'b1}} - i_awaddr));
`else
            assert(i_awburst == 2'b01);
            assert(i_awsize == AWSIZE_EXPECTED);
            assert(i_awaddr % ADDR_INCR == 0);
            assert(implied_burst_span < ({ADDR_WIDTH{1'b1}} - i_awaddr));
`endif
        end
    end

`ifdef FORMAL
    logic	f_past_valid;

    initial begin
        f_past_valid = 0;
    end

    always @(posedge clk)
      f_past_valid <= 1;

    // assume inputs reset properly
    always @(posedge clk) begin
      if (f_past_valid && $past(reset))
`ifdef AXIADDRCOUNTER_FORMAL
        assume(!i_awvalid);
`else
        assert(!i_awvalid);
`endif
    end

    // assume inputs are stable if stalled
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(i_awvalid) && !$past(i_awready)) begin
 `ifdef AXIADDRCOUNTER_FORMAL
          assume($stable(i_awaddr));
          assume($stable(i_awlen));
          assume($stable(i_awsize));
          assume($stable(i_awburst));
          assume(i_awvalid);
 `else
          assert($stable(i_awaddr));
          assert($stable(i_awlen));
          assert($stable(i_awsize));
          assert($stable(i_awburst));
          assert(i_awvalid);
 `endif
      end

    // assert outputs are stable if stalled
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(o_next_addr_valid) && !$past(o_next_addr_ready)) begin
          assert($stable(o_next_addr_data));
          assert(o_next_addr_valid);
      end

    // assume short bursts to speed up the proofs
 `ifdef AXIADDRCOUNTER_FORMAL
    always @(*)
      assume(i_awlen < 16);
 `endif


    // assert output is reset
    always @(posedge clk)
      if (f_past_valid && $past(reset)) begin
          assert(!o_next_addr_valid);
      end

    // assume low first clock
    always @(*)
      if (!f_past_valid)
        assume(i_awvalid == 0);

    // assert that burst count never overflows
    always @(posedge clk)
      assert(burst_count <= burst_length);

    logic [31:0] f_addr_count;
    initial f_addr_count = 0;

    always @(posedge clk) begin
      if (f_past_valid && !$past(reset) && !reset)
          if (o_next_addr_valid && o_next_addr_ready)
            f_addr_count <= f_addr_count + 1;
        if (reset)
          f_addr_count <= 0;
    end

    logic [31:0] f_awlen_count;
    initial f_awlen_count = 0;

    always @(posedge clk) begin
      if (f_past_valid && !$past(reset) && !reset)
        if (i_awvalid && i_awready)
            f_awlen_count <= f_awlen_count + (i_awlen + 1);
        if (reset)
          f_awlen_count <= 0;
    end

    // TODO write covers

 `ifdef AXIADDRCOUNTER_FORMAL
    always @(posedge clk)
      cover(!reset && i_awvalid && i_awready && i_awlen > 0);

    logic f_was_in_burst;
    initial f_was_in_burst = 0;

    always @(posedge clk)
      if (in_burst)
        f_was_in_burst <= 1;

    always @(posedge clk)
      if (f_past_valid && !$past(reset) && !reset)
        cover(burst_count > 8 && burst_count == burst_length && f_addr_count == burst_length);

    integer f_iaw_count;
    initial f_iaw_count = 0;

    always @(posedge clk)
      if (f_past_valid && !$past(reset) && !reset)
          if (i_awvalid && i_awready)
            f_iaw_count <= f_iaw_count + 1;

    // try to catch two bursts of 16 based on i_awlen assumption < 16
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && !reset)
        cover(f_addr_count == 32 && f_iaw_count == 2);

    integer f_stalled_beats;
    initial f_stalled_beats = 0;

    always @(posedge clk)
      if (o_next_addr_valid && !o_next_addr_ready)
        f_stalled_beats <= f_stalled_beats + 1;

    // try to catch two bursts of 16 based on i_awlen assumption < 16 with some stalls
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && !reset)
        cover(f_addr_count == 32 && f_iaw_count == 2 && f_stalled_beats > 8);




 `endif


`endif

endmodule
