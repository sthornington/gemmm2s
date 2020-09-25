#include <stdlib.h>
#include <memory>
#include <iostream>
#include <assert.h>
#include "tb.h"
#include "Vgemmm2s_v2.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

class GEMMM2SSim : public Sim<Vgemmm2s_v2>{
    int t_beat_count {};
    int tlast_count {};
public:
    GEMMM2SSim(const char* trace_name, unsigned int time_limit)  :
        Sim(trace_name, time_limit)
    {
        mod->reset = 1;
        mod->clk = 0;
        mod->s_axi_awvalid = 0;
        mod->s_axi_wvalid = 0;
        mod->s_axi_bready = 0;
    }

    void reset() {
        mod->reset = 1;
        mod->s_axi_awvalid = 0;
        mod->s_axi_wvalid = 0;
        mod->s_axi_bready = 0;
        for (int i=0; i<2; i++) {
            tick();
        }
        mod->reset = 0;
        tick();
    }

    void reset_t_beat_count() {
        t_beat_count = 0;
    }

    void reset_tlast_count() {
        tlast_count = 0;
    }

    void check_tdata() {
        if (mod->m_axis_tvalid && mod->m_axis_tready) {
            unsigned int tdata = mod->m_axis_tdata;
            bool tlast = mod->m_axis_tlast;
            t_beat_count++;
            if (tlast) {
                tlast_count++;
            }
            printf("Time: %d Beat: %d TDATA: 0x%08x %s\n",
                   sim_time, t_beat_count, tdata, tlast ? "TLAST" : "");
        }
    }

    int get_t_beat_count() const {
        return t_beat_count;
    }

    int get_tlast_count() const {
        return tlast_count;
    }

    void tick() {
        tickt(
            [&]() {
                mod->clk = 1;
                check_tdata();
            },
            [&]() {
                mod->clk = 0;
            });
    }
};

GEMMM2SSim* g_sim {};

double sc_time_stamp() {
    if (g_sim) {
        return g_sim->time();
    }
    return 0;
}


void do_write(GEMMM2SSim* sim,
              unsigned short base,
              int n_beats,
              int id,
              bool tready_stall,
              int tready_stall_at,
              int tready_stall_for,
              bool bready_stall)
{
    // prepare the T side, always ready
    sim->mod->m_axis_tready = 0x1;

    // start the AW
    sim->mod->s_axi_awid = id;
    sim->mod->s_axi_awaddr = base;
    sim->mod->s_axi_awlen = n_beats - 1;
    sim->mod->s_axi_awsize = 0x2; // 2^2 = 4 bytes
    sim->mod->s_axi_awburst = 0x1; // INCR
    sim->mod->s_axi_awvalid = 0x1;
    std::cout << "Time: " << sim->time() << " data burst AWVALID " << std::endl;

    while (!sim->mod->s_axi_awready) { sim->tick(); }
    // tick over the transaction
    sim->tick();
    // AW accepted, kill AW
    sim->mod->s_axi_awvalid = 0x0;

    // start the W
    int stall_count = 0;
    bool trans_accepted = true;
    int beat = 0;
    for (int i=0; i<100; i++) {
        if (trans_accepted) {
            if (sim->mod->s_axi_wlast) {
                std::cout << "Time: " << sim->time() << " data burst WLAST accepted\n";
                break;
            }
            beat++;
            sim->mod->s_axi_wdata = beat;
            sim->mod->s_axi_wlast = beat == n_beats;
            sim->mod->s_axi_wvalid = 0x1;
        }
        if (tready_stall && (i >= tready_stall_at && (stall_count++ < tready_stall_for))) {
            // this might change WREADY so we need to eval
            sim->mod->m_axis_tready = 0x0;
        } else {
            sim->mod->m_axis_tready = 0x1;
        }
        sim->mod->eval();
        trans_accepted = sim->mod->s_axi_wvalid && sim->mod->s_axi_wready;
        sim->tick();
    }

    assert(beat == n_beats);

    // W accepted, kill W
    sim->mod->s_axi_wvalid = 0x0;
    // tidy up the rest
    sim->mod->s_axi_wdata = 0x00000000;
    sim->mod->s_axi_wlast = 0x0;

    // await the B
    if (bready_stall) {
        // delay our BREADY for a bit
        sim->tick();
        sim->tick();
        sim->tick();
        sim->tick();
        sim->tick();
    }
    sim->mod->s_axi_bready = 0x1;
    while (!sim->mod->s_axi_bvalid) { sim->tick(); }
    // tick over the transaction();
    assert(sim->mod->s_axi_bid == sim->mod->s_axi_awid);
    sim->tick();
    // B accepted, kill B
    sim->mod->s_axi_bready = 0x0;
}

void do_ticks(GEMMM2SSim* sim, int n_ticks) {
    // tick N times to consume all the T beats we can
    for (int i=0; i<n_ticks; i++) {
        sim->tick();
    }
}

void do_drain_t(GEMMM2SSim* sim, int n_beats)
{
    // prepare the T side, always ready
    sim->mod->m_axis_tready = 0x1;

    // tick N times to consume all the T beats we can
    for (int i=0; i<n_beats && sim->mod->m_axis_tvalid; i++) {
        sim->tick();
    }
}

void do_write_dma_complete(GEMMM2SSim* sim) {
    // start the AW
    sim->mod->s_axi_awid = 0x1;
    sim->mod->s_axi_awaddr = 0x1000;
    sim->mod->s_axi_awlen = 0x00;
    sim->mod->s_axi_awsize = 0x2; // 2^2 = 4 bytes
    sim->mod->s_axi_awburst = 0x1; // INCR
    sim->mod->s_axi_awvalid = 0x1;

    std::cout << "Time: " << sim->time() << " DMA Complete AWVALID\n";

    while (!sim->mod->s_axi_awready) { sim->tick(); }
    // tick over the transaction
    sim->tick();
    // AW accepted, kill AW
    sim->mod->s_axi_awvalid = 0x0;

    // start the W
    sim->mod->s_axi_wdata = 0x0000001;
    sim->mod->s_axi_wlast = 0x1;
    sim->mod->s_axi_wvalid = 0x1;

    while (!sim->mod->s_axi_wready) { sim->tick(); }
    // tick over the transaction
    sim->tick();
    std::cout << "Time: " << sim->time() << " DMA Complete accepted\n";

    // W accepted, kill W
    sim->mod->s_axi_wvalid = 0x0;
    // tidy up the rest
    sim->mod->s_axi_wdata = 0x00000000;
    sim->mod->s_axi_wlast = 0x0;

    // await B
    sim->mod->s_axi_bready = 0x1;
    while (!sim->mod->s_axi_bvalid) { sim->tick(); }
    // tick over the transaction();
    assert(sim->mod->s_axi_bid == sim->mod->s_axi_awid);
    sim->tick();
    // B accepted, kill B
    sim->mod->s_axi_bready = 0x0;
}

void run_unit_tests() {
    std::unique_ptr<GEMMM2SSim> unit_sim = std::make_unique<GEMMM2SSim>("unit_tests", 10000);

    g_sim = unit_sim.get();

    unit_sim->reset();

    unit_sim->reset_t_beat_count();
    do_write(unit_sim.get(), 0x0000, 4, 0, false, 0, 0, false);
    // do not DMA Complete here, let it wrap to 0x0000 to TLAST
    do_drain_t(unit_sim.get(), 2);
    assert(unit_sim->get_t_beat_count() == 3);
    assert(unit_sim->get_tlast_count() == 0);

    do_write(unit_sim.get(), 0x0000, 32, 0, true, 2, 32, false);
    // flush for a while to flush the FIFOs that filled up
    // during our stall
    do_drain_t(unit_sim.get(), 8);

    // previous burst plus all of this burst but one
    assert(unit_sim->get_t_beat_count() == 4 + 31);
    assert(unit_sim->get_tlast_count() == 1);
    do_write_dma_complete(unit_sim.get());
    do_write_dma_complete(unit_sim.get());
    // do some ticks to let the DMA Complete interrupts percolate through
    do_ticks(unit_sim.get(), 8);
    // grab the last T
    do_drain_t(unit_sim.get(), 1);
    assert(unit_sim->get_t_beat_count() == 4 + 32);
    assert(unit_sim->get_tlast_count() == 2);

    // now attempt a two burst packet with some stalls
    unit_sim->reset_t_beat_count();
    unit_sim->reset_tlast_count();

    // tready AND bready stall, tready stall in the middle of the burst
    do_write(unit_sim.get(), 0x0000, 16, 0, true, 6, 16, true);
    // don't bother pausing between bursts even though the real
    // hardware does this.
    // tready AND bready stall, tready stall at the start of the burst
    do_write(unit_sim.get(), 0x0020, 16, 0, true, 0, 16, true);
    do_write_dma_complete(unit_sim.get());
    do_write_dma_complete(unit_sim.get());
    do_drain_t(unit_sim.get(), 32);
    assert(unit_sim->get_t_beat_count() == 32);
    assert(unit_sim->get_tlast_count() == 1);
}

void do_gem_burst(GEMMM2SSim* sim, unsigned short& base, const int burst_length)
{
    do_write(sim, base, burst_length, 0, false, 0, 0, false);
    base += burst_length * 4;
    do_ticks(sim, 4);

}

void run_gem_sim() {
    std::unique_ptr<GEMMM2SSim> gem_sim = std::make_unique<GEMMM2SSim>("gem", 10000);

    g_sim = gem_sim.get();

    gem_sim->reset();

    // now do a realistic-ish simulation of the GEM hardware:
    // 2 bursts of 3 beats (MAC addrs)
    // N bursts of 4 beats (data)
    // 0-3 bursts of 1 beat (data remainder)
    // DMA complete interrupt some time later

    unsigned short base = 0x0000;

    do_gem_burst(gem_sim.get(), base, 3);
    do_gem_burst(gem_sim.get(), base, 3);

    do_gem_burst(gem_sim.get(), base, 4);
    do_gem_burst(gem_sim.get(), base, 4);
    do_gem_burst(gem_sim.get(), base, 4);
    do_gem_burst(gem_sim.get(), base, 4);

    do_gem_burst(gem_sim.get(), base, 1);
    do_gem_burst(gem_sim.get(), base, 1);
    do_gem_burst(gem_sim.get(), base, 1);

    // wait for all the code on the PS core to handle the interrupt,
    // reset all the BDs and do a write to the control page of our
    // module
    do_ticks(gem_sim.get(), 24);
    do_write_dma_complete(gem_sim.get());
    // wait for the DMA complete message to percolate through and flush out the last beat
    do_ticks(gem_sim.get(), 8);

    assert(gem_sim->get_t_beat_count() == 25);
    assert(gem_sim->get_tlast_count() == 1);
}


int main(int argc, char **argv) {
    // Initialize Verilators variables
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    run_unit_tests();
    run_gem_sim();

}
