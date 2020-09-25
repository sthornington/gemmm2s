`timescale 1 ns / 1 ps
`default_nettype none


// each side gets skid buffer attached to a fifo.  in the core,
// a beat is pulled from each fifo when both are valid and the output
// skid is ready too
module stream_join
  #(
    parameter LEFT_WIDTH = 8,
    parameter RIGHT_WIDTH = 8,
    parameter FIFO_ADDR_SZ = 1, // this is the power of 2 size
    parameter OUT_WIDTH = LEFT_WIDTH + RIGHT_WIDTH
    )
    (
     input logic                   clk,
     input logic                   reset,

     input logic                   i_left_valid,
     output logic                  i_left_ready,
     input logic [LEFT_WIDTH-1:0]  i_left_data,

     input logic                   i_right_valid,
     output logic                  i_right_ready,
     input logic [RIGHT_WIDTH-1:0] i_right_data,

     output logic                  o_valid,
     input logic                   o_ready,
     output logic [OUT_WIDTH-1:0]  o_data
     );

    // if fire is true, we will pull a beat from the left fifo,
    // a beat from the right fifo, and push it into the outbound
    // skid buffer
    logic                          fire;

    // translate fifo lingo to bus lingo
    // !empty -> valid
    // !full -> ready
    logic                          left_fifo_ready;
    logic                          left_fifo_valid;
    logic                          right_fifo_ready;
    logic                          right_fifo_valid;

    logic                          left_fifo_empty;
    logic                          right_fifo_empty;
    logic                          left_fifo_full;
    logic                          right_fifo_full;
    // these are a little wider than you expect because the
    // fifos can in fact be completely full
    logic [FIFO_ADDR_SZ:0]         left_fifo_count;
    logic [FIFO_ADDR_SZ:0]         right_fifo_count;

    logic [LEFT_WIDTH-1:0]         left_fifo_data;
    logic [RIGHT_WIDTH-1:0]        right_fifo_data;

    fifo #(LEFT_WIDTH, FIFO_ADDR_SZ) left_fifo
      (
       .clk,
       .reset,
       .i_wr(i_left_valid && left_fifo_ready),
       .i_data(i_left_data),
       .o_full(left_fifo_full),
       .i_rd(fire),
       .o_data(left_fifo_data),
       .o_empty(left_fifo_empty),
       .o_count(left_fifo_count)
       );

    fifo #(RIGHT_WIDTH, FIFO_ADDR_SZ) right_fifo
      (
       .clk,
       .reset,
       .i_wr(i_right_valid && right_fifo_ready),
       .i_data(i_right_data),
       .o_full(right_fifo_full),
       .i_rd(fire),
       .o_data(right_fifo_data),
       .o_empty(right_fifo_empty),
       .o_count(right_fifo_count)
       );

    parameter FIFO_DEPTH = 1 << FIFO_ADDR_SZ;

    // to use the count signals
    always @(*) begin
        assert(left_fifo_count <= FIFO_DEPTH);
        assert(right_fifo_count <= FIFO_DEPTH);
    end

    always_comb begin
        i_left_ready = !left_fifo_full;
        i_right_ready = !right_fifo_full;
    end

    always_comb begin
        o_valid = left_fifo_valid && right_fifo_valid;
        if (o_valid)
          o_data = {left_fifo_data, right_fifo_data};
        else
          o_data = 0;
    end

    always_comb begin
        left_fifo_ready = !left_fifo_full;
        right_fifo_ready = !right_fifo_full;
        left_fifo_valid = !left_fifo_empty;
        right_fifo_valid = !right_fifo_empty;
    end

    always_comb
      fire = o_ready && left_fifo_valid && right_fifo_valid;

`ifdef FORMAL
    localparam PAST_VALID_FOR = 8;

    logic	[PAST_VALID_FOR:0] f_past_valid_sr;
    logic                          f_past_valid;

    initial f_past_valid_sr = 8'd0;

    always @(posedge clk) begin
        f_past_valid_sr[PAST_VALID_FOR:0] <= {f_past_valid_sr[PAST_VALID_FOR-1:0], 1'b1};
    end

    assign f_past_valid = f_past_valid_sr[0];

    // assume inputs are reset properly
    always @(posedge clk) begin
        if (f_past_valid && $past(reset)) begin
 `ifdef STREAMJOIN_FORMAL
            assume(!i_left_valid);
            assume(!i_right_valid);
 `else
            assert(!i_left_valid);
            assert(!i_right_valid);
 `endif
        end
    end

    // assume inputs are stable if stalled
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset) && $past(i_left_valid) && !$past(i_left_ready)) begin
 `ifdef STREAMJOIN_FORMAL
            assume($stable(i_left_data));
            assume(i_left_valid);
 `else
            assert($stable(i_left_data));
            assert(i_left_valid);
 `endif
        end

        if (f_past_valid && !$past(reset) && $past(i_right_valid) && !$past(i_right_ready)) begin
 `ifdef STREAMJOIN_FORMAL
            assume($stable(i_right_data));
            assume(i_right_valid);
 `else
            assert($stable(i_right_data));
            assert(i_right_valid);
 `endif
        end
    end

    // assert our outputs are stable if stalled
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(o_valid) && !$past(o_ready)) begin
          assert($stable(o_data));
          assert(o_valid);
      end

    // assert skids & fifos reset properly
    always @(posedge clk)
      if (f_past_valid && $past(reset)) begin
          assert(!left_fifo_valid);
          assert(!right_fifo_valid);
          assert(!fire);
          assert(!o_valid);
      end

    logic f_no_recent_resets;
    initial f_no_recent_resets = 0;

    always @(posedge clk)
      f_no_recent_resets <= f_past_valid_sr[PAST_VALID_FOR] &&
                            !reset &&
                            !$past(reset) &&
                            !$past(reset, 2) &&
                            !$past(reset, 3) &&
                            !$past(reset, 4) &&
                            !$past(reset, 5) &&
                            !$past(reset, 6);

    logic f_no_recent_stalls;
    initial f_no_recent_stalls = 0;

    always @(posedge clk)
      f_no_recent_stalls <= f_past_valid_sr[PAST_VALID_FOR] &&
                            o_ready &&
                            $past(o_ready) &&
                            $past(o_ready, 2) &&
                            $past(o_ready, 3) &&
                            $past(o_ready, 4) &&
                            $past(o_ready, 5) &&
                            $past(o_ready, 6);

    logic f_all_stalled;
    initial f_all_stalled = 0;

    always @(posedge clk)
      f_all_stalled <= f_past_valid_sr[PAST_VALID_FOR] &&
                       !o_ready &&
                       $past(!o_ready) &&
                       $past(!o_ready, 2) &&
                       $past(!o_ready, 3) &&
                       $past(!o_ready, 4) &&
                       $past(!o_ready, 5) &&
                       $past(!o_ready, 6);

    // assert that on a beat 1 clock ago (inskids, fifo, outskid) the output has something
    always @(posedge clk)
      if (f_no_recent_resets && f_no_recent_stalls &&
          $past(i_left_valid, 1) && $past(i_left_ready, 1) &&
          $past(i_right_valid, 1) && $past(i_right_ready, 1))
        begin
            assert(o_valid);
        end

    (* anyconst *) logic [LEFT_WIDTH-1:0] f_left_const;
    (* anyconst *) logic [RIGHT_WIDTH-1:0] f_right_const;
    always @(posedge clk)
      if (f_no_recent_resets && f_no_recent_stalls &&
          left_fifo_valid && right_fifo_valid &&
          left_fifo_data == f_left_const && right_fifo_data == f_right_const)
        begin
            assert(o_valid);
            assert(o_data == {f_left_const, f_right_const});
        end

    // keep this in the local formal since external users might have deeper fifos
 `ifdef STREAMJOIN_FORMAL
    always @(posedge clk)
      if (f_no_recent_resets && f_all_stalled &&
          i_left_valid && i_right_valid &&
          $past(i_left_valid, 1) && $past(i_right_valid, 1) && // need at least two for the input skids
          $past(i_left_valid, 2) && $past(i_right_valid, 2) &&
          $past(i_left_valid, 3) && $past(i_right_valid, 3) && // two to fill the fifos
          $past(i_left_valid, 4) && $past(i_right_valid, 4) &&
          $past(i_left_valid, 5) && $past(i_right_valid, 5) && // two to fill the output skid
          $past(i_left_valid, 6) && $past(i_right_valid, 6))
        begin
            assert(left_fifo_full);
            assert(right_fifo_full);
            assert(!left_fifo_ready);
            assert(!right_fifo_ready);
            assert(!i_left_ready);
            assert(!i_right_ready);
        end
 `endif

    // COVER
 `ifdef STREAMJOIN_FORMAL
    // for prettiness
    always @(posedge clk) begin
        if (f_past_valid && $past(reset)) begin
            assume(i_left_data == 0);
            assume(i_right_data == 0);
        end else begin
            if (i_left_valid && i_left_ready)
              assume(i_left_data == $past(i_left_data) + 1);
            else
              assume(i_left_data == $past(i_left_data));
            if (i_right_valid && i_right_ready)
              assume(i_right_data == $past(i_right_data) + 1);
            else
              assume(i_right_data == $past(i_right_data));
        end
    end

    // six back-to-back beats at full speed
    always @(posedge clk) begin
        cover( f_past_valid_sr[PAST_VALID_FOR] &&
               i_left_valid && i_left_ready && i_right_valid && i_right_ready && o_ready &&
               $past(i_left_valid, 1) && $past(i_left_ready, 1) && $past(i_right_valid, 1) && $past(i_right_ready, 1) && $past(o_ready, 1) &&
               $past(i_left_valid, 2) && $past(i_left_ready, 2) && $past(i_right_valid, 2) && $past(i_right_ready, 2) && $past(o_ready, 2) &&
               $past(i_left_valid, 3) && $past(i_left_ready, 3) && $past(i_right_valid, 3) && $past(i_right_ready, 3) && $past(o_ready, 3) &&
               $past(i_left_valid, 4) && $past(i_left_ready, 4) && $past(i_right_valid, 4) && $past(i_right_ready, 4) && $past(o_ready, 4) &&
               $past(i_left_valid, 5) && $past(i_left_ready, 5) && $past(i_right_valid, 5) && $past(i_right_ready, 5) && $past(o_ready, 5) &&
               $past(i_left_valid, 6) && $past(i_left_ready, 6) && $past(i_right_valid, 6) && $past(i_right_ready, 6) && $past(o_ready, 6));
    end

    // two alternately-not-ready streams on the input (left-then-right and right-then-left, then both both)
    always @(posedge clk) begin
        cover( f_past_valid_sr[PAST_VALID_FOR] &&
               i_left_valid && i_left_ready && i_right_valid && i_right_ready && o_ready &&
               $past(i_left_valid, 1) && $past(i_left_ready, 1) && $past(i_right_valid, 1) && $past(i_right_ready, 1) && $past(o_ready, 1) &&
               $past(i_left_valid, 2) && $past(i_left_ready, 2) && $past(i_right_valid, 2) && $past(i_right_ready, 2) && $past(o_ready, 2) &&
               $past(i_left_valid, 3) && $past(i_left_ready, 3) && $past(!i_right_valid, 3) && $past(i_right_ready, 3) && $past(o_ready, 3) &&
               $past(!i_left_valid, 4) && $past(i_left_ready, 4) && $past(i_right_valid, 4) && $past(i_right_ready, 4) && $past(o_ready, 4) &&
               $past(!i_left_valid, 5) && $past(i_left_ready, 5) && $past(i_right_valid, 5) && $past(i_right_ready, 5) && $past(o_ready, 5) &&
               $past(i_left_valid, 6) && $past(i_left_ready, 6) && $past(!i_right_valid, 6) && $past(i_right_ready, 6) && $past(o_ready, 6));
    end

    integer f_out_count;
    initial f_out_count = 0;

    always @(posedge clk)
        if (o_valid && o_ready)
          f_out_count <= f_out_count + 1;

    integer f_left_fifo_full_count;
    integer f_right_fifo_full_count;
    initial f_left_fifo_full_count = 0;
    initial f_right_fifo_full_count = 0;

    always @(posedge clk) begin
        if (left_fifo_full && !right_fifo_full)
          f_left_fifo_full_count <= f_left_fifo_full_count + 1;
        if (right_fifo_full && !left_fifo_full)
          f_right_fifo_full_count <= f_right_fifo_full_count + 1;
    end

    always @(posedge clk) begin
        cover(f_out_count > 16 && f_left_fifo_full_count > 1 && f_right_fifo_full_count > 1);
    end

 `endif

`endif

endmodule
`default_nettype wire
