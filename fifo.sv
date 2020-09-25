`timescale 1 ns / 1 ps
`default_nettype none
module fifo #(
              parameter integer FIFO_WIDTH = 32,
              parameter integer FIFO_ADDR_SZ = 1 // infers the depth of 2^sz!
              )
    (
     input logic                     clk,
     input logic                     reset,

     input logic                     i_wr,
     input logic [FIFO_WIDTH-1 : 0]  i_data,
     output logic                    o_full,

     input logic                     i_rd,
     output logic [FIFO_WIDTH-1 : 0] o_data,
     output logic                    o_empty,

     output logic [FIFO_ADDR_SZ:0]   o_count

     );
    parameter                       FIFO_DEPTH = 1 << FIFO_ADDR_SZ;

    logic [FIFO_WIDTH-1:0]           fifo_mem[0:FIFO_DEPTH-1];
    logic                            w_wr;
    logic                            w_rd;
    // addresses have an extra bit to distinguish full & empty!
    logic [FIFO_ADDR_SZ:0]           wr_addr;
    logic [FIFO_ADDR_SZ:0]           rd_addr;

    assign w_wr = i_wr && !o_full;
    assign w_rd = i_rd && !o_empty;

    initial wr_addr = 0;
    initial rd_addr = 0;

    always_ff @(posedge clk) begin
        if (w_wr) begin
            wr_addr <= wr_addr + 1;
        end
        if (reset) begin
            wr_addr <= 0;
        end
    end

    always_ff @(posedge clk)
      if (w_wr)
        fifo_mem[wr_addr[FIFO_ADDR_SZ-1:0]] <= i_data;

    always_ff @(posedge clk) begin
        if (w_rd) begin
            rd_addr <= rd_addr + 1;
        end
        if (reset) begin
            rd_addr <= 0;
        end
    end

    always_comb
      // TODO WHY IS THIS LIKE THIS?
      // DO WE WANT DISTRIBUTED RAM?
      o_data = fifo_mem[rd_addr[FIFO_ADDR_SZ-1:0]];

    always_comb
      o_count = wr_addr - rd_addr;

    always_comb
      o_empty = (o_count == 0);

    always_comb
      o_full = (o_count == FIFO_DEPTH);

    always @(*)
      assert(FIFO_DEPTH == { 1'b1, {(FIFO_ADDR_SZ){1'b0}} });

    // FORMAL PROPERTIES
    always @(*)
      assert(o_count <= FIFO_DEPTH);

    always @(*)
      assert(o_empty == (o_count == 0));

    always @(*)
      assert(o_full == (o_count == FIFO_DEPTH));

`ifdef FORMAL

    logic	f_past_valid;

    initial begin
        f_past_valid = 0;
    end

    always @(posedge clk)
      f_past_valid <= 1;

    logic [FIFO_ADDR_SZ:0]           f_count, f_next, f_empty;
    assign	f_count = wr_addr - rd_addr;
    assign	f_empty = (wr_addr == rd_addr);
    assign	f_next = rd_addr + 1'b1;

    always @(*)
      begin
	  assert(f_count <= FIFO_DEPTH);
	  assert(o_count == f_count);

	  assert(o_full  == (f_count == FIFO_DEPTH));
	  assert(o_empty == (f_count == 0));
      end

    always @(*)
      assert(fifo_mem[rd_addr] == o_data);

    // reset assertions
    always @(posedge clk) begin
        if (f_past_valid && $past(reset)) begin
            assert(wr_addr == 0);
            assert(rd_addr == 0);
        end
    end

 `ifdef FIFO_FORMAL
    (* anyconst *) logic [FIFO_ADDR_SZ:0] f_first_addr;
    logic [FIFO_ADDR_SZ:0] f_second_addr;

    always @(*)
      f_second_addr = f_first_addr + 1;

    (* anyconst *) logic [FIFO_WIDTH-1:0] f_first_data;
    (* anyconst *) logic [FIFO_WIDTH-1:0] f_second_data;

    typedef enum           bit [1:0] { IDLE=2'b00, ONE=2'b01, TWO=2'b10, THREE=2'b11 } f_state_t;
    f_state_t f_state;
    initial f_state = IDLE;

    always @(posedge clk) begin
        if (reset) begin
            f_state <= IDLE;
        end else begin
            case (f_state)
              IDLE:
                if (w_wr && (wr_addr == f_first_addr) && (i_data == f_first_data))
                  f_state <= ONE;
              ONE:
                if (w_rd && rd_addr == f_first_addr)
                  f_state <= IDLE;
                else if (w_wr)
                  f_state <= (i_data == f_second_data) ? TWO : IDLE;
              TWO:
                if (i_rd && rd_addr == f_first_addr)
                  f_state <= THREE;
              THREE:
                if (i_rd) f_state <= IDLE;
            endcase // case (f_state)
        end
    end

    logic [FIFO_ADDR_SZ:0] f_distance_to_first;
    logic                  f_first_addr_in_fifo;

    always @(*)
      begin
          f_distance_to_first = (f_first_addr - rd_addr);
          //f_first_addr_in_fifo = 0;
          if (!o_empty && (f_distance_to_first < o_count))
            f_first_addr_in_fifo = 1;
          else
            f_first_addr_in_fifo = 0;
      end

    logic [FIFO_ADDR_SZ:0]            f_distance_to_second;
    logic                             f_second_addr_in_fifo;

    always @(*)
      begin
          f_distance_to_second = (f_second_addr - rd_addr);
          if (!o_empty && (f_distance_to_second < o_count))
            f_second_addr_in_fifo = 1;
          else
            f_second_addr_in_fifo = 0;
      end

    // ONE state assertions
    always @(*)
      if (f_state == ONE)
        begin
            assert(f_first_addr_in_fifo);
            assert(fifo_mem[f_first_addr] == f_first_data);
            assert(wr_addr == f_second_addr);
        end

    always @(*)
      if (f_state == TWO)
        begin
            assert(f_first_addr_in_fifo);
            assert(fifo_mem[f_first_addr] == f_first_data);
            assert(f_second_addr_in_fifo);
            assert(fifo_mem[f_second_addr] == f_second_data);

            if (rd_addr == f_first_addr)
              assert(o_data == f_first_data);
        end

    always @(*)
      if (f_state == THREE)
        begin
            assert(f_second_addr_in_fifo);
            assert(fifo_mem[f_second_addr] == f_second_data);
            assert(o_data == f_second_data);
        end

    // TODO cover properties!
    logic f_was_full;
    initial f_was_full = 0;
    always_ff @(posedge clk)
      if (o_full)
        f_was_full <= 1;

    always @(posedge clk)
      cover(f_was_full && f_empty);

    always @(posedge clk)
      cover($past(o_full, 2) && (!$past(o_full)) && (o_full));
 `endif


`endif //  `ifdef FORMAL



endmodule
