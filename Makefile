V	:= gemmm2s_wrapper.v
TB	:= gemmm2s_tb.cc
SRCS	:= $(SV) $(TB)
OBJDIR 	:= obj_dir
VMKFILE	:= Vgemmm2s_wrapper.mk
VMKFILEABS	:= $(addprefix $(OBJDIR)/,Vgemmm2s_wrapper.mk)
VBINARY	:= $(addprefix $(OBJDIR)/,Vgemmm2s_wrapper)
VSRCS	:= $(addprefix $(OBJDIR)/,%.cpp)
VHEADERS	:= $(addprefix $(OBJDIR)/,%.h)

all:	gemmm2s_sim.vcd

# TODO: cleanup formal crap too
clean:
	rm -Rf $(OBJDIR)

formal: register skid_buffer stream_join last_beat_calc axi_addr_counter gemmm2s_v2

gemmm2s_sim.vcd:	$(VBINARY)
	$(VBINARY) || true

$(VBINARY):	$(VMKFILEABS)
	make -C $(OBJDIR) -f $(VMKFILE)

$(VMKFILEABS):	$(SRCS)
	verilator -Wall  -CFLAGS "-g -O0 -std=c++17" --trace -cc $(V) --exe $(TB)

register:	register.sv register.sby
	sby -f register.sby

skid_buffer:	skid_buffer.sv skid_buffer.sby
	sby -f skid_buffer.sby

stream_join:	stream_join.sv stream_join.sby
	sby -f stream_join.sby

last_beat_calc:	last_beat_calc.sv last_beat_calc.sby
	sby -f last_beat_calc.sby

axi_addr_counter:	axi_addr_counter.sv axi_addr_counter.sby
	sby -f axi_addr_counter.sby

gemmm2s_v2:	gemmm2s_v2.sv gemmm2s_v2.sby
	sby -f gemmm2s_v2.sby
