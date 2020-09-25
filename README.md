# gemmm2s

Verilog module for converting from AXI4 MM of Zynq GEM Ethernet DMA to AXI-Stream with packet boundaries.

## Problem

When using a Xilinx Zynq board, the Ethernet port(s) are most often connected to the
processing system (PS) directly, in order to use the Gigabit Ethernet Module (GEM)
hard-silicon MAC.  This works great for getting Ethernet data in Linux running on the
ARM cores, but is not helpful if one wants to play around with doing Ethernet packet
processing on the Programmable Logic (PL).

Xilinx has put out a few tech notes about how to get Ethernet data into the PL:

https://www.linuxsecrets.com/xilinx/Zynq-7000+AP+SoC+-+Performance+-+Ethernet+Packet+Inspection+-+Bare+Metal+-+Redirecting++Packets+to+PL+Tech+Tip.html

https://www.linuxsecrets.com/xilinx/Zynq-7000+AP+SoC+-+Performance+-+Ethernet+Packet+Inspection+-+Bare+Metal+-+Redirecting+Headers+to+PL+and+Cache+Tech+Tip.html

https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18841762/Zynq-7000+AP+SoC+-+Performance+-+Ethernet+Packet+Inspection+-+Linux+-+Redirecting+Packets+to+PL+and+Cache+Tech+Tip

However, for the most part, these redirect the packets into Block RAM.  This is not
typically how one would interact with Ethernet packet data if one were processing
Ethernet packets straight from a PHY add-on board, after having implemented a MAC in PL.
Typically, one would be observing these packets in a streaming fashion as an AXI-Stream
of some width (related to the line speed and SERDES).

## Solution

The solution is to use a total hack-job mess of software and hardware to shuttle packets
from the GEM DMA controller into PL and convert them into an AXI-Stream.  The trick is, the
GEM DMA controller sends full AXI4 bursts of varying lengths, sporadically into scatter-gather
buffers you supply in a buffer descriptor list, and we want a steady stream of AXIS beats
with the final one in the packet having TLAST set.

## Details

This repo contains the hardware component that presents an AXI4 Slave interface with two
pages, one which the software running bare-metal on one of the ARM cores can use to
pass into the GEM DMA Buffer Descriptors as the "memory" into which to write the packet
data, and the other containing a control register which the same software can write a word
in whenever the PS gets a DMA Complete interrupt from the GEM.

Whenever the addresses written into the data as AXI bursts wrap back around to 0x0000, the
logic can safely snip off the previous beat as TLAST since we have started a new packet.
Similarly, whenever, after a packet has been written, we get an DMA Complete write to the
control register, we can also snip off the last packet.  The only trick is to make sure
that no matter how the wrapping and interrupts are interleaved, we only ever set TLAST
once per packet.

To aid with this, many of the sub-modules have been formally verified using SymbiYosys.
However, at the time of writing (09/24/2020) I haven't yet done the formal proof for
the aggregate module, `gemmm2s_v2`.  For that, there is simply some verilator simulation
tests of the overall behavior.  This is not the same, but it's what I have for now.

## Integration

As time permits, I'll be reorganizing this to include the software one has to run on the
ARM core, based heavily on the original (bugged) `xemacps` example by Xilinx.  I might
even include an example involving an HLS module built using the C++ templates provided
by the Xilinx HLS Packet Processing library, specifically the version which does not
require boost in a PR by @orangeturtle739: https://github.com/Xilinx/HLS_packet_processing/pull/3

However, to start with, I'm only uploading the SystemVerilog and Verilog wrapper (for block
diagram integration) of the core component which converts AXI4 as generated by the GEM DMA
engine into a convenient AXI-Stream controller.

Thanks for reading!
