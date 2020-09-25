`timescale 1 ns / 1 ps

/*
 This is the core module for attaching TLAST to the stream of DMA
 beats from the GEM.  We monitor the addresses from the AXI AW channel,
 and assume that a new packet has started on the first beat to the base
 address.

 We also have a dma_complete line which the PS code will cause to be
 asserted whenever the GEM DMA engine has interrupted the PS to inform
 that a DMA is complete.

 We unconditionally increment a pkt_start_count whenever we see the addr
 wrap around to the base address.

 We unconditionally increment a pkt_done_count whenever we see the DMA
 complete.

 We ASSUME that i_dma_complete will NOT be asserted at the same time as
 any beat (where i_addr_valid == 1).  This should be safe, since we plan
 to get the PS to signal this through the SAME AXI port as the data.

 Here's the magic:

 ON the beat when the address wraps, IF (start-done)>0, then we know
 that we have only wrapped one ore more packets, and this one has NOT yet been
 completed via the DMA-Complete pathway, so we can release the previous
 beat as LAST and be sure that whenever the DMA-Complete comes for it,
 it will be ignored because by that point, (start-done)==2;

 ON the tick when i_dma_complete arrives, IF (start-done)==1, then
 we know that we have only one packet outstanding waiting to be tied off,
 and we can release the previous beat as LAST and be sure that whenever
 the next beat wraps around, it will be ignored because by that point, (start-done)==0.

 Any beat that arrives which was NOT a wraparound, we release the previous
 beat as !LAST because we know that this beat is part of the SAME packet,
 and just about to follow it.

 Scenarios (where outstanding = start - done):

 Single Packet:
 ADDR == BASE while outstanding == 0.  !LAST, !VALID (brand new packet)
 ADDR != BASE while outstanding == 1.  !LAST, VALID (interior beats)
 ...
 DMA_COMPLETE while outstanding == 1.  LAST, VALID (tie off)

 Back-To-Back 2 Packets:
 ADDR == BASE while outstanding == 0.  !LAST, !VALID (brand new packet)
 ADDR != BASE while outstanding == 1.  !LAST, VALID (interior beats)
 ADDR == BASE while outstanding == 1.  LAST, VALID (new packet following old)
 ADDR != BASE while outstanding == 2.  !LAST, VALID (interior beats)
 ...
 DMA_COMPLETE while outstanding == 2.  !LAST, !VALID (too-late)
 ADDR != BASE while outstanding == 1.  !LAST, VALID (interior beats)
 ...
 DMA_COMPLETE while outstanding == 1.  LAST, VALID (tie off)

 */
module last_beat_calc #(
                        parameter integer ADDR_WIDTH = 12,
                        parameter integer BUS_WIDTH = 32,
                        parameter [ADDR_WIDTH-1:0] BASE_ADDR = 0
                        )
    (
     input logic                  clk,
     input logic                  reset,

     // address of the beat being received
     input logic [ADDR_WIDTH-1:0] i_addr_data,
     input logic                  i_addr_valid,
     output logic                   i_addr_ready,

     // interrupt from the PS that an entire packet DMA is complete
     input logic                  i_dma_complete,
     // TODO: do we need backpressure? would be very annoying to
     // implement, and this should only really have any effect
     // at all AFTER a busy period has finished.

     output logic                   o_prev_beat_last,
     output logic                   o_prev_beat_last_valid
     // TODO: do we need backpressure?  upstream SHOULD have already
     // been backpressured by the beat data itself, meaning the
     // TLAST fifo of the skid_join always has the same room...
     );

    localparam PACKET_COUNTER_WIDTH = 2;
    localparam MAX_OUTSTANDING_PACKETS = 1 << PACKET_COUNTER_WIDTH;
    localparam BEAT_BYTES = BUS_WIDTH / 8;


    logic [PACKET_COUNTER_WIDTH:0] pkt_start_count;
    logic [PACKET_COUNTER_WIDTH:0] pkt_done_count;
    logic [PACKET_COUNTER_WIDTH:0] pkt_outstanding_count;

    logic                          beat;

    logic                            addr_wrapped;

    initial begin
        pkt_start_count = 0;
        pkt_done_count = 0;
    end

    always_comb
      pkt_outstanding_count = pkt_start_count - pkt_done_count;

    always_comb
      i_addr_ready = !(pkt_outstanding_count == MAX_OUTSTANDING_PACKETS);

    always_comb
      addr_wrapped = (i_addr_valid && i_addr_data == BASE_ADDR);

    always_comb
      beat = i_addr_valid && i_addr_ready;

    always_ff @(posedge clk) begin
        pkt_start_count <= pkt_start_count;
        if (beat && addr_wrapped)
          pkt_start_count <= pkt_start_count + 1;
        if (reset)
          pkt_start_count <= 0;
    end

    always_ff @(posedge clk) begin
        if (i_dma_complete)
          pkt_done_count <= pkt_done_count + 1;
        if (reset)
          pkt_done_count <= 0;
    end

    always_ff @(posedge clk) begin
        o_prev_beat_last_valid <= 1'b0;
        o_prev_beat_last <= 1'b0;

        // tie-off
        if (i_dma_complete && (pkt_outstanding_count == 1)) begin
            o_prev_beat_last <= 1'b1;
            o_prev_beat_last_valid <= 1'b1;
        end
        // addr beat
        else if (beat) begin
            // if pkt_outstanding_count == 0, then the previous packet
            // didn't exist or was tied off, therefore nothing to assert.
            if (pkt_outstanding_count > 0) begin
                // we definitely have a previous beat to release, whether it was the
                // last beat or not is whether the address wrapped or not!
                o_prev_beat_last_valid <= 1'b1;
                o_prev_beat_last <= addr_wrapped;
            end
        end
        if (reset) begin
            o_prev_beat_last <= 1'b0;
            o_prev_beat_last_valid <= 1'b0;
        end
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

    // assume low first clock
    always @(*)
      if (!f_past_valid) begin
          assume(i_addr_valid == 0);
          assume(i_dma_complete == 0);
      end

    // keep around debugging traces
    always @(posedge clk) begin
        assert(f_addr_wrap_count >= 0);
        assert(f_addr_beat_count >= 0);
        assert(f_addr_pause_count >= 0);
        assert(f_addr_stall_count >= 0);
    end

    // assume no spurious dma_complete
    // TODO: should we explicitly ignore these?
    always @(posedge clk)
      if (pkt_outstanding_count == 0)
        assume(!i_dma_complete);

    // assume inputs are reset properly
    always @(posedge clk) begin
        if (f_past_valid && $past(reset)) begin
 `ifdef LASTBEATCALC_FORMAL
            assume(!i_addr_valid);
            assume(!i_dma_complete);
 `else
            assert(!i_addr_valid);
            assert(!i_dma_complete);
 `endif
        end
    end

    // assume inputs are stable if stalled
    always @(posedge clk) begin
        if (f_past_valid && !$past(reset) &&
            $past(i_addr_valid) && !$past(i_addr_ready)) begin
 `ifdef LASTBEATCALC_FORMAL
            assume($stable(i_addr_data));
            assume(i_addr_valid);
 `else
            assert($stable(i_addr_data));
            assert(i_addr_valid);
 `endif
        end
    end

    always @(posedge clk)
      assert(pkt_outstanding_count <= MAX_OUTSTANDING_PACKETS);

    // TODO write tests for all the scenarios.  going to be tricky.
    // MOST IMPORTANT is that there is only one last beat for every address
    // beat.
    // maybe need to write a state machine with an arbitrary (allconst?
    // allseq?) beat count and an arbitrary delay after which to write dma
    // complete?

    initial begin
        pkt_start_count = 0;
        pkt_done_count = 0;
    end

    logic [31:0] f_addr_beat_count;
    initial f_addr_beat_count = 0;

    logic [31:0] f_addr_wrap_count;
    initial f_addr_wrap_count = 0;

    logic [31:0] f_addr_stall_count;
    initial f_addr_stall_count = 0;

    logic [31:0] f_addr_pause_count;
    initial f_addr_pause_count = 0;

    // tick the address beat counter
    always @(posedge clk)
        if (f_past_valid && !$past(reset))
            if (i_addr_valid && i_addr_ready) begin
                f_addr_beat_count <= f_addr_beat_count + 1;
                if (i_addr_data == BASE_ADDR)
                  f_addr_wrap_count <= f_addr_wrap_count + 1;
            end

    logic [31:0] f_dma_complete_count;
    initial f_dma_complete_count = 0;

    // tick dma complete counter
    always @(posedge clk)
      if (f_past_valid && !$past(reset))
        if (i_dma_complete)
          f_dma_complete_count <= f_dma_complete_count + 1;


 `ifdef LASTBEATCALC_FORMAL
    // the state machine for the driver
    typedef enum bit [1:0] { DMA_IDLE=2'b00, DMA_DATA=2'b01 } f_dma_state_t;
    f_dma_state_t f_dma_state;
    initial f_dma_state = DMA_IDLE;

    (* anyconst *) integer f_pkt_len_bytes;
    integer                f_pkt_sent_bytes;
    initial f_pkt_sent_bytes = 0;

    always @(*) begin
        assume(f_pkt_len_bytes > 0);
        assume(f_pkt_len_bytes <= 1024);
        assume(f_pkt_len_bytes % 4 == 0);
    end

    logic [31:0] f_interrupts_needed;
    initial f_interrupts_needed = 0;
    logic   f_interrupt_now;
    initial f_interrupt_now = 0;

    always @(posedge clk) begin
        f_interrupt_now <= 0;
        if (reset) begin
            f_dma_state <= DMA_IDLE;
        end else
          case (f_dma_state)
            DMA_IDLE:
              begin
                  f_pkt_sent_bytes <= 0;
                  if (i_addr_valid && i_addr_ready) begin
                      assume(i_addr_data == BASE_ADDR);
                      if (BEAT_BYTES < f_pkt_len_bytes) begin
                          f_dma_state <= DMA_DATA;
                      end else begin
                          f_dma_state = DMA_IDLE;
                          f_interrupts_needed <= f_interrupts_needed + 1;
                          f_interrupt_now <= 1;
                      end
                      f_pkt_sent_bytes <= BEAT_BYTES;
                  end else begin
                  assume($stable(i_addr_data));
                  end
              end
            DMA_DATA:
              if (i_addr_valid && i_addr_ready) begin
                  assume(i_addr_data == $past(i_addr_data) + BEAT_BYTES);
                  f_pkt_sent_bytes <= f_pkt_sent_bytes + BEAT_BYTES;
                  if ((f_pkt_sent_bytes + BEAT_BYTES) >= f_pkt_len_bytes) begin
                      f_interrupts_needed <= f_interrupts_needed + 1;
                      f_interrupt_now <= 1;
                      f_dma_state <= DMA_IDLE;
                  end
              end else if (i_addr_valid && !i_addr_ready) begin
                  f_addr_stall_count <= f_addr_stall_count + 1;
                  assume($stable(i_addr_data));
              end else if (!i_addr_valid) begin
                  f_addr_pause_count <= f_addr_pause_count + 1;
                  assume($stable(i_addr_data));
              end else
                  assume($stable(i_addr_data));
          endcase
    end // always @ (posedge clk)


    // keep around debugging traces
    always @(posedge clk) begin
        assert(f_interrupts_needed >= 0);
    end

    // BEGIN SHIFTREG IMPL
    localparam MAX_INTERRUPT_DELAY = 512;
    (* anyconst *) integer f_interrupt_delay;

    always @(*) begin
        // if the interrupts start arriving before we can saturate our MAX_OUTSTANDING_PACKETS limits
        // we will never be able to backpressure the input address channel
        assume(f_interrupt_delay > 0);
        assume(f_interrupt_delay < MAX_INTERRUPT_DELAY);
    end

    logic [MAX_INTERRUPT_DELAY:0] f_past_intr_needed_sr;
    initial                       f_past_intr_needed_sr = 0;

    always @(posedge clk) begin
        if (f_past_valid_sr[1])
          f_past_intr_needed_sr[MAX_INTERRUPT_DELAY:0] <= {f_past_intr_needed_sr[MAX_INTERRUPT_DELAY-1:0], f_interrupt_now};
    end

    always @(posedge clk) begin
        if (f_past_intr_needed_sr[f_interrupt_delay]) begin
            assume(i_dma_complete);
        end else begin
            assume(!i_dma_complete);
        end
    end
    // END SHIFTREG IMPL

    logic f_dma_completed;
    initial f_dma_completed = 0;

    always @(posedge clk)
      if (i_dma_complete)
        f_dma_completed <= 1;

    // cover
    logic f_input_stalled;
    initial f_input_stalled = 0;

    always @(posedge clk)
      if (f_past_valid && i_addr_valid && !i_addr_ready)
        f_input_stalled <= 1;

    logic f_input_invalid;
    initial f_input_invalid = 0;

    always @(posedge clk)
      if (f_past_valid && $past(i_addr_valid) && !i_addr_valid)
        f_input_invalid <= 1;

    logic f_simultaneous_addr_and_dma;
    initial f_simultaneous_addr_and_dma = 0;

    always @(posedge clk)
      if (f_past_valid && i_addr_valid && i_addr_ready && i_dma_complete)
        f_simultaneous_addr_and_dma <= 1;

    logic f_got_full;
    initial f_got_full = 0;

    always @(posedge clk)
      if (pkt_outstanding_count == MAX_OUTSTANDING_PACKETS)
        f_got_full <= 1;

    logic f_got_empty;
    initial f_got_empty = 0;

    always @(posedge clk)
      if (f_got_full && pkt_outstanding_count == 0)
        f_got_empty <= 1;

    logic f_got_reset;
    initial f_got_reset = 0;

    always @(*)
      if (reset)
        f_got_reset <= 1;


    // test realistic single packet
    always @(posedge clk)
      cover(!f_got_reset && f_pkt_len_bytes == 64 && o_prev_beat_last && o_prev_beat_last_valid && pkt_start_count == 1);

    // test stall ending on double-event
    always @(posedge clk)
      cover(!f_got_reset && f_pkt_len_bytes == 16 && f_dma_completed && f_input_stalled && i_dma_complete && i_addr_valid);

    // test stall ending in no data
    always @(posedge clk)
      cover(!f_got_reset && f_pkt_len_bytes == 16 && f_got_full && f_input_stalled && !f_input_invalid);

    // test full cycle full and empty with a double-event at some point
    always @(posedge clk)
      cover(!f_got_reset && f_pkt_len_bytes == 12 && f_interrupt_delay == 9 && f_got_full && f_got_empty && i_addr_valid);

    always @(posedge clk)
      cover(!f_got_reset && f_got_full && f_got_empty && f_addr_pause_count > 1 && f_addr_stall_count > 1);


 `endif

`endif
endmodule
