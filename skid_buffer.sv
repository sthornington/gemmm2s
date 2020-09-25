`timescale 1 ns / 1 ps
`default_nettype none

module skid_buffer
  #(
    parameter WORD_WIDTH = 8
    )
    (
     input logic                   clk,
     input logic                   reset,

     input logic                   i_valid,
     output logic                  i_ready,
     input logic [WORD_WIDTH-1:0]  i_data,

     output logic                  o_valid,
     input logic                   o_ready,
     output logic [WORD_WIDTH-1:0] o_data
     );

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};
    logic                          data_buffer_wren = 1'b0; // EMPTY at start, so don't load.
    logic [WORD_WIDTH-1:0]         data_buffer_out;

    register #(.WORD_WIDTH(WORD_WIDTH), .RESET_VALUE(WORD_ZERO))
    data_buffer_reg
      (
       .clk      (clk),
       .clk_en   (data_buffer_wren),
       .reset    (reset),
       .i_data   (i_data),
       .o_data   (data_buffer_out)
       );

    logic                          data_out_wren       = 1'b1; // EMPTY at start, so accept data.
    logic                          use_buffered_data   = 1'b0;
    logic [WORD_WIDTH-1:0]         selected_data       = WORD_ZERO;

    always_comb begin
        selected_data = (use_buffered_data == 1'b1) ? data_buffer_out : i_data;
    end

    register #(.WORD_WIDTH(WORD_WIDTH), .RESET_VALUE(WORD_ZERO))
    data_out_reg
      (
       .clk    (clk),
       .clk_en (data_out_wren),
       .reset  (reset),
       .i_data (selected_data),
       .o_data (o_data)
       );

    localparam STATE_BITS = 2;

    // TODO figure out if we can use this as an enum in a register.
    localparam [STATE_BITS-1:0] EMPTY = 'd0; // Output and buffer registers empty
    localparam [STATE_BITS-1:0] BUSY  = 'd1; // Output register holds data
    localparam [STATE_BITS-1:0] FULL  = 'd2; // Both output and buffer registers hold data
    // There is no case where only the buffer register would hold data.

    // No handling of erroneous and unreachable state 3.
    // We could check and raise an error flag.

    logic [STATE_BITS-1:0] state;
    logic [STATE_BITS-1:0] state_next = EMPTY;

    register #(.WORD_WIDTH(1), .RESET_VALUE(1'b1) /* EMPTY at start, so accept data */ )
    i_ready_reg
      (
       .clk    (clk),
       .clk_en (1'b1),
       .reset  (reset),
       .i_data (state_next != FULL),
       .o_data (i_ready)
       );

    register #(.WORD_WIDTH(1), .RESET_VALUE(1'b0))
    o_valid_reg
      (
       .clk    (clk),
       .clk_en (1'b1),
       .reset  (reset),
       .i_data (state_next != EMPTY),
       .o_data (o_valid)
       );

    logic                  insert = 1'b0;
    logic                  remove = 1'b0;

    always_comb begin
        insert = (i_valid == 1'b1) && (i_ready == 1'b1);
        remove = (o_valid == 1'b1) && (o_ready == 1'b1);
    end

    logic load    = 1'b0; // Empty datapath inserts data into output register.
    logic flow    = 1'b0; // New inserted data into output register as the old data is removed.
    logic fill    = 1'b0; // New inserted data into buffer register. Data not removed from output register.
    logic flush   = 1'b0; // Move data from buffer register into output register. Remove old data. No new data inserted.
    logic unload  = 1'b0; // Remove data from output register, leaving the datapath empty.

    always @(*) begin
        load    = (state == EMPTY) && (insert == 1'b1) && (remove == 1'b0);
        flow    = (state == BUSY)  && (insert == 1'b1) && (remove == 1'b1);
        fill    = (state == BUSY)  && (insert == 1'b1) && (remove == 1'b0);
        flush   = (state == FULL)  && (insert == 1'b0) && (remove == 1'b1);
        unload  = (state == BUSY)  && (insert == 1'b0) && (remove == 1'b1);
    end

    always_comb begin
        state_next = (load   == 1'b1) ? BUSY  : state;
        state_next = (flow   == 1'b1) ? BUSY  : state_next;
        state_next = (fill   == 1'b1) ? FULL  : state_next;
        state_next = (flush  == 1'b1) ? BUSY  : state_next;
        state_next = (unload == 1'b1) ? EMPTY : state_next;
    end

    register#(.WORD_WIDTH(STATE_BITS), .RESET_VALUE(EMPTY) /* Initial state */)
    state_reg
      (
       .clk    (clk),
       .clk_en (1'b1),
       .reset  (reset),
       .i_data (state_next),
       .o_data (state)
       );

    always_comb begin
        data_out_wren     = (load  == 1'b1) || (flow == 1'b1) || (flush == 1'b1);
        data_buffer_wren  = (fill  == 1'b1);
        use_buffered_data = (flush == 1'b1);
    end


`ifdef FORMAL
    logic	f_past_valid;

    initial begin
        f_past_valid = 0;
    end

    always @(posedge clk)
      f_past_valid <= 1;

    // assume state is always valid
    always @(*) begin
        assume(state < 'd3);
        assume(state_next < 'd3);
    end

    // assert states can't skip
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset)) begin
            if ($past(state) == EMPTY) begin
                assert(state == EMPTY || state == BUSY);
            end else if ($past(state) == BUSY) begin
                assert(state == EMPTY || state == BUSY || state == FULL);
            end else if ($past(state) == FULL) begin
                assert(state == BUSY || state == FULL);
            end
        end
    end

    // assume inputs are stable if stalled
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(i_valid) && !$past(i_ready)) begin
 `ifdef SKIDBUFFER_FORMAL
          assume($stable(i_data));
          assume(i_valid);
 `else
          assert($stable(i_data));
          assert(i_valid);
 `endif
      end

    // assume inputs reset properly
    always @(posedge clk)
      if (f_past_valid && $past(reset))
 `ifdef SKIDBUFFER_FORMAL
        assume(!i_valid);
 `else
        assert(!i_valid);
 `endif

    // assert our outputs are stable if stalled
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(o_valid) && !$past(o_ready)) begin
          assert($stable(o_data));
          assert(o_valid);
      end

    // assert outputs reset properly
    always @(posedge clk)
      if (f_past_valid && $past(reset)) begin
          assert(!o_valid);
          assert(state == EMPTY);
      end

    // assert that on a beat, the output has something
    always @(posedge clk)
      if (f_past_valid && !$past(reset) &&
          $past(i_valid) && $past(i_ready))
        assert(o_valid);

    // assert on a beat with output full but stalled, incoming data gets buffered
    always @(posedge clk)
      if (f_past_valid && !$past(reset) &&
          $past(i_valid) && $past(i_ready) && // incoming beat
          $past(o_valid) && !$past(o_ready))  // outgoing valid but stalled
        begin
            // data went into buffer
            assert(data_buffer_out == $past(i_data));
            // upstream got stalled
            assert(!i_ready);
        end

    // assert when full and output unstalls, we copy the buffered data into the output
    always @(posedge clk)
      if (f_past_valid && !$past(reset) &&
          $past(i_valid,2) && $past(i_ready,2) &&  // incoming beat - 2
          $past(i_valid) && $past(i_ready) &&      // incoming beat - 1
          $past(o_valid,2) && !$past(o_ready,2) && // outgoing stalled - 2
          $past(o_valid) && $past(o_ready))        // outgoing unstalled
        begin
            // buffer will be used to fill the out after this
            assert(use_buffered_data);
            // output is now the input 2 ago
            assert(o_data == $past(i_data,2));
            // buffer is input 1 ago (redundant)
            assert(data_buffer_out == $past(i_data));
            // output WILL be the buffered data
            assert(o_data == data_buffer_out);
            // upstream will be unstalled
            assert(i_ready);
        end

    // after flushing last from output, nothing is present after
    always @(posedge clk)
      if (f_past_valid && !$past(reset) &&
          !$past(i_valid) && // nothing incoming
          $past(o_ready) &&  // outbound draining
          !$past(use_buffered_data)) // nothing buffered
        assert(!o_valid); // assert nothing left

    // if were filled up, incoming ready
    always @(posedge clk)
      if (f_past_valid && !$past(reset) &&
          $past(use_buffered_data) && // were using buffered data
          $past(o_ready)) // outbound draining
        begin
            // won't use buffered data for the next tick
            assert(!use_buffered_data);
            // upstream unstalled
            assert(i_ready);
        end

    // COVER
 `ifdef SKIDBUFFER_FORMAL
    logic	f_changed_data;
    initial	f_changed_data = 1;

    // encourage the data to increment
    always @(posedge clk)
      if (!f_past_valid) begin
          assume(i_data == 1);
      end else /* f_past_valid */ begin
          if (reset) // forces no resets
	    f_changed_data <= 0;
          else if (i_valid && $past(!i_valid || i_ready))
            begin
	        if (i_data != $past(i_data + 1))
	          f_changed_data <= 0;
            end
      end

    // track that we filled it at some point
    logic f_was_full;
    initial f_was_full = 0;

    always @(posedge clk)
      if (state == FULL)
        f_was_full <= 1;

    // track that we transitioned from something to empty
    logic f_got_emptied;
    initial f_got_emptied = 0;

    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(state) != EMPTY && state == EMPTY)
        f_got_emptied <= 1;

    // get some flow in there
    logic f_got_flowed;
    initial f_got_flowed = 0;
    always @(posedge clk)
      if (f_past_valid &&
          $past(flow,4) &&
          $past(flow,3) &&
          $past(flow,2) &&
          $past(flow,1) &&
          flow)
        f_got_flowed <= 1;


    // Cover the full cycle
    always @(posedge clk)
      cover(f_was_full && f_got_emptied && f_got_flowed && f_changed_data);
 `endif
`endif

endmodule
`default_nettype wire
