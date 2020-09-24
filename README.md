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
of some width related to the line speed and SERDES.  (to be continued).