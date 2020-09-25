#include "verilated.h"
#include "verilated_vcd_c.h"

template<typename UUT>
class Sim {
public:
    UUT* mod {};
protected:
    VerilatedVcdC* trace {};
    unsigned int sim_time = 0;
    unsigned int time_limit {};
public:
    Sim(std::string trace_name, unsigned int time_limit) {
        this->time_limit = time_limit;
        trace = new VerilatedVcdC();
        mod = new UUT();
        mod->trace(trace, 10 /* trace depth */);
        trace->open((trace_name + ".vcd").c_str());
    }

    ~Sim() {
        mod->final();
        trace->close();
    }

    unsigned int time() const {
        return sim_time;
    }

    template<typename F, typename G>
    void tickt(F&& posedge, G&& negedge) {
        for (int i=0; i<10; i++) {
            mod->eval();
            trace->dump(sim_time);

            sim_time++;
            if (i % 10 == 4) {
                negedge();
                mod->eval();
            } else if (i % 10 == 9) {
                posedge();
                mod->eval();
            } else {
                mod->eval();
            }
            trace->dump(sim_time);
        }

        trace->flush();

        if (sim_time > time_limit) {
            trace->flush();
            throw "hit time limit";
        }
    }
};
