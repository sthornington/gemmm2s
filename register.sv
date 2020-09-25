`timescale 1 ns / 1 ps
`default_nettype none

module register
  #(
    parameter WORD_WIDTH  = 32,
    parameter RESET_VALUE = 0
    )
    (
     input wire logic                   clk,
     input wire logic                   clk_en,
     input wire logic                   reset,
     input wire logic [WORD_WIDTH-1:0]  i_data,
     output wire logic [WORD_WIDTH-1:0] o_data
     );

    initial begin
        o_data = RESET_VALUE;
    end

    always_ff @(posedge clk) begin
        if (clk_en == 1'b1) begin
            o_data <= i_data;
        end

        if (reset == 1'b1) begin
            o_data <= RESET_VALUE;
        end
    end

`ifdef FORMAL
    logic	f_past_valid;

    initial begin
        f_past_valid = 0;
    end

    always @(posedge clk)
      f_past_valid <= 1;

    // test reset works
    always @(posedge clk)
      if (f_past_valid && $past(reset))
	assert(o_data == RESET_VALUE);

    // test if !clk_en, nothing changes
    always @(posedge clk)
      if (f_past_valid && !$past(clk_en) && !$past(reset))
        assert($stable(o_data));

    // test we logicister
    always @(posedge clk)
      if (f_past_valid && !$past(reset) && $past(clk_en))
        assert(o_data == $past(i_data));

`endif

endmodule
`default_nettype wire
